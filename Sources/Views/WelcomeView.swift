import SwiftUI

/// Shown in the main area when no backup is open — doubles as first-run onboarding and the
/// Full Disk Access recovery screen.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    private var accessDenied: Bool {
        if case .permissionDenied = model.scanError { return true } else { return false }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 56)).foregroundStyle(.tint)
                Text("iPhone Backup Explorer").font(.largeTitle).bold()
                Text("Browse and export the photos, videos, messages, contacts and files inside your iPhone or iPad backups.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                if accessDenied {
                    fullDiskAccessCard
                } else if model.devices.isEmpty && !model.isScanning {
                    noBackupsCard
                } else {
                    Text("Choose a backup from the sidebar to begin.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button { model.openSingleBackupFolder() } label: {
                        Label("Open a Backup Folder…", systemImage: "folder")
                    }
                    Button { model.chooseBackupRoot() } label: {
                        Label("Choose Backups Location…", systemImage: "externaldrive")
                    }
                }
                .controlSize(.large)

                Text("Tip: you can also drag a backup folder onto this window.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private var fullDiskAccessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Full Disk Access needed", systemImage: "lock.shield").font(.headline).foregroundStyle(.orange)
            Text("macOS protects the folder where iPhone backups live. Give this app Full Disk Access so it can read them:")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Label("Open System Settings → Privacy & Security → Full Disk Access", systemImage: "1.circle")
                Label("Turn on iPhone Backup Explorer", systemImage: "2.circle")
                Label("Return here and press Refresh (⌘R)", systemImage: "3.circle")
            }
            .font(.callout)
            HStack {
                Button { model.openPrivacySettings() } label: { Label("Open Privacy Settings", systemImage: "gearshape") }
                    .buttonStyle(.borderedProminent)
                Button { model.scan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            Text("Or skip Full Disk Access and pick a backup folder manually with the buttons below — that grants access to just that folder.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 560)
    }

    private var noBackupsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No backups found", systemImage: "questionmark.folder").font(.headline)
            Text("Nothing was found in:").foregroundStyle(.secondary)
            Text(model.backupRoot.path).font(.callout).monospaced().textSelection(.enabled)
            Text("Make a backup in Finder (select your iPhone → Back up now, with “Encrypt local backup” if you want Health and Messages included), then press Refresh. Or pick a different location below.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 560)
    }
}
