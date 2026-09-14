import AppKit
import Foundation

/// In-app update coordinator: checks GitHub Releases for a newer build than the running one and,
/// on request, downloads + verifies + installs it via `SelfUpdater`. Mirrors AR Workspace Manager's
/// updater — public, unauthenticated GitHub API; the security boundary is `SelfUpdater.verify`.
@MainActor
final class Updater: ObservableObject {
    /// Set when a newer release than this build is published on GitHub.
    @Published var updateAvailableVersion: String?
    @Published var updateURL: URL?              // the release page (for "Release notes")
    @Published var updateDownloadAssetURL: URL? // the .dmg asset (for in-app install)
    @Published var checkingForUpdate = false
    /// Drives the Updates window/sheet visibility.
    @Published var showUpdatesUI = false
    /// Set once per launch after a silent check finds an update, so we can auto-surface it.
    @Published var autoPrompted = false
    /// Human-readable result of the last check (shown on the About page).
    @Published var updateCheckMessage: String?
    /// In-app install (download → verify → swap → relaunch) progress.
    @Published var updateInstalling = false
    @Published var updateInstallStatus: String?
    /// True when the offered version is a channel *switch* below the current version (downgrade).
    @Published var updateIsDowngrade = false

    /// Which releases the user opts into: Stable (default), RC (stable + release candidates), or
    /// Beta (everything). Switching channels re-checks — and can offer a DOWNGRADE.
    @Published var updateChannel: UpdateChannel =
        UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "updateChannel") ?? "") ?? .stable {
        didSet {
            UserDefaults.standard.set(updateChannel.rawValue, forKey: "updateChannel")
            checkForUpdates()
        }
    }

    private static let updateRepo = "dripster82/IphoneBackupExplorer"

    /// The real bundled version (CFBundleShortVersionString), e.g. "0.1.0".
    var bundleVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// The version the app reports for update comparisons and display.
    var appVersion: String { bundleVersion }

    /// Query the repo's releases and offer the best match for the chosen channel. Unauthenticated
    /// (public endpoint, 60 req/hr) — runs silently on launch and on demand from the About page.
    func checkForUpdates() {
        guard !checkingForUpdate else { return }
        checkingForUpdate = true
        updateCheckMessage = nil
        Task { @MainActor in
            defer { checkingForUpdate = false }
            guard let url = URL(string: "https://api.github.com/repos/\(Self.updateRepo)/releases?per_page=30") else { return }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { updateCheckMessage = "Update check failed."; return }
                guard http.statusCode == 200 else {
                    updateCheckMessage = http.statusCode == 404 ? "No releases published yet." : "Update check failed (\(http.statusCode))."
                    return
                }
                struct GHAsset: Decodable { let name: String; let browser_download_url: String }
                struct GHRelease: Decodable { let tag_name: String; let html_url: String; let draft: Bool; let assets: [GHAsset] }
                let releases = try JSONDecoder().decode([GHRelease].self, from: data)

                // Best release for the channel: version-tagged (skips e.g. "intel-test"), not a
                // draft, channel-eligible, highest precedence (beta < RC < stable within a version).
                let candidates: [(version: AppVersion, release: GHRelease)] = releases.compactMap { rel in
                    guard !rel.draft, let v = AppVersion(rel.tag_name),
                          self.updateChannel.includes(v.channel) else { return nil }
                    return (v, rel)
                }
                guard let best = candidates.max(by: { $0.version < $1.version }),
                      let current = AppVersion(appVersion) else {
                    clearUpdateOffer(message: "No releases found for the \(updateChannel.label) channel.")
                    return
                }

                if best.version == current {
                    clearUpdateOffer(message: "You're on the latest \(updateChannel.label.lowercased()) version (v\(appVersion)).")
                } else {
                    updateAvailableVersion = best.version.raw
                    updateURL = URL(string: best.release.html_url)
                    updateDownloadAssetURL = Self.pickDMGAsset(
                        best.release.assets.map { ($0.name, $0.browser_download_url) })
                    updateIsDowngrade = best.version < current
                    updateCheckMessage = updateIsDowngrade
                        ? "Latest \(updateChannel.label.lowercased()) is v\(best.version.raw) — below your v\(appVersion) pre-release; switching will downgrade."
                        : "Update available: v\(best.version.raw)."
                }
            } catch {
                updateCheckMessage = "Update check failed: \(error.localizedDescription)"
            }
        }
    }

    private func clearUpdateOffer(message: String) {
        updateAvailableVersion = nil
        updateURL = nil
        updateDownloadAssetURL = nil
        updateIsDowngrade = false
        updateCheckMessage = message
    }

    /// True when this Mac's HARDWARE is Apple Silicon — detected at runtime, not compile time, so an
    /// Intel build running under Rosetta still updates to the native Apple Silicon DMG instead of
    /// keeping itself on Intel forever. arm64 builds only run on Apple Silicon; an x86_64 build
    /// checks sysctl.proc_translated (1 = Rosetta ⇒ the hardware is really Apple Silicon).
    nonisolated static var hardwareIsAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 {
            return translated == 1
        }
        return false
        #endif
    }

    /// Choose the right .dmg for this Mac's hardware. Releases ship per-arch assets named with
    /// friendly labels (…-Apple-Silicon.dmg / …-Intel.dmg); older single-asset releases fall back to
    /// any .dmg.
    nonisolated static func pickDMGAsset(_ assets: [(name: String, url: String)]) -> URL? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let markers = hardwareIsAppleSilicon
            ? ["apple-silicon", "applesilicon", "arm64"]
            : ["intel", "x86_64", "x86-64"]
        let match = dmgs.first { d in markers.contains { d.name.lowercased().contains($0) } } ?? dmgs.first
        return match.flatMap { URL(string: $0.url) }
    }

    /// Download the latest release's .dmg, verify it's our genuine notarised build, swap the running
    /// bundle, and relaunch (see `SelfUpdater`). On success the app quits so the swap helper can finish.
    func installUpdate() {
        guard !updateInstalling else { return }
        guard let dmg = updateDownloadAssetURL else {
            updateInstallStatus = "This release has no .dmg attached — use Release notes to download it."
            return
        }
        updateInstalling = true
        updateInstallStatus = "Starting…"
        Task { @MainActor in
            do {
                try await SelfUpdater.installUpdate(from: dmg) { [weak self] status in
                    self?.updateInstallStatus = status
                }
                // The swap helper is now armed and waiting for us to exit. Quit to let it finish.
                NSApp.terminate(nil)
            } catch {
                updateInstalling = false
                updateInstallStatus = "Update failed: \(error.localizedDescription)"
                NSLog("SelfUpdater: \(error.localizedDescription)")
            }
        }
    }
}
