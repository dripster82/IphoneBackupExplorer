import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Software Update").font(.headline)
                    Text("iPhone Backup Explorer \(updater.appVersion)").font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Update channel").foregroundStyle(.secondary)
                Picker("", selection: $updater.updateChannel) {
                    ForEach(UpdateChannel.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                if updater.checkingForUpdate { ProgressView().controlSize(.small) }
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(updater.checkingForUpdate || updater.updateInstalling)
            }

            Divider()

            if updater.updateInstalling {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { ProgressView().controlSize(.small); Text(updater.updateInstallStatus ?? "Installing…") }
                    Text("The app will relaunch automatically when the update is installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let version = updater.updateAvailableVersion {
                VStack(alignment: .leading, spacing: 10) {
                    Label(updater.updateIsDowngrade ? "Version \(version) available (downgrade)" : "Update available: \(version)",
                          systemImage: "sparkles").font(.headline)
                    if let msg = updater.updateCheckMessage {
                        Text(msg).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button {
                            updater.installUpdate()
                        } label: { Label("Install and Relaunch", systemImage: "square.and.arrow.down") }
                            .buttonStyle(.borderedProminent)
                            .disabled(updater.updateDownloadAssetURL == nil)
                        if let url = updater.updateURL {
                            Link(destination: url) { Label("Release Notes", systemImage: "doc.text") }
                        }
                    }
                    if updater.updateDownloadAssetURL == nil {
                        Text("This release has no matching .dmg for your Mac — use Release Notes to download it.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            } else {
                Label(updater.updateCheckMessage ?? "You're up to date.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 260)
    }
}
