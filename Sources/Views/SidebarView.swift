import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.selectedDeviceID }, set: { id in
            model.select(model.devices.first { $0.id == id })
        })) {
            Section("Backups") {
                if model.isScanning {
                    HStack { ProgressView().controlSize(.small); Text("Scanning…").foregroundStyle(.secondary) }
                } else if let error = model.scanError {
                    PermissionView(error: error)
                } else if model.devices.isEmpty {
                    Text("No backups found in\n\(model.backupRoot.path)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device).tag(device.id)
                        .contextMenu {
                            Button("Copy Backup to Folder…") { model.copyBackup(device) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([device.url]) }
                        }
                }
            }

            if model.session != nil {
                Section("Explore") {
                    ExploreRow(name: "Overview", icon: "chart.bar.doc.horizontal", isSelected: model.workspace == .overview)
                        .onTapGesture { model.showOverview() }
                    ExploreRow(name: "Files", icon: "folder", isSelected: model.workspace == .files)
                        .onTapGesture { model.showFiles() }
                    if model.contactsFile != nil {
                        ExploreRow(name: "Contacts", icon: "person.crop.circle", isSelected: model.workspace == .contacts)
                            .onTapGesture { model.showContacts() }
                    }
                    if model.messagesFile != nil {
                        ExploreRow(name: "Messages", icon: "message", isSelected: model.workspace == .messages)
                            .onTapGesture { model.showMessages() }
                    }
                    if model.whatsappFile != nil {
                        ExploreRow(name: "WhatsApp", icon: "phone.bubble", isSelected: model.workspace == .whatsapp)
                            .onTapGesture { model.showWhatsApp() }
                    }
                    ForEach(model.availableDataKinds) { kind in
                        ExploreRow(name: kind.title, icon: kind.icon, isSelected: model.workspace == .data(kind))
                            .onTapGesture { model.showData(kind) }
                    }
                }

                Section("Domains") {
                    DomainRow(name: "All Domains", icon: "tray.full", count: model.allFiles.filter(\.isRegularFile).count,
                              size: model.domainSummaries.reduce(0) { $0 + $1.totalSize },
                              isSelected: model.selectedDomain == nil && model.workspace == .files)
                        .onTapGesture { model.showFiles(); model.selectedDomain = nil; model.selection = [] }
                    ForEach(model.domainSummaries) { summary in
                        DomainRow(name: summary.displayName, icon: DomainInfo.systemImage(for: summary.domain),
                                  count: summary.fileCount, size: summary.totalSize,
                                  isSelected: model.selectedDomain == summary.domain && model.workspace == .files)
                            .onTapGesture { model.showFiles(); model.selectedDomain = summary.domain; model.selection = [] }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Divider()
                HStack {
                    Button { model.openSingleBackupFolder() } label: { Label("Open Folder…", systemImage: "folder") }
                    Spacer()
                    Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Rescan \(model.backupRoot.path)")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: BackupDevice
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.productType.hasPrefix("iPad") ? "ipad" : "iphone")
                .font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(device.title).fontWeight(.medium).lineLimit(1)
                    if device.isEncrypted { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange) }
                }
                Text(device.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let date = device.lastBackupDate {
                    Text(date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .help(device.url.path)
    }
}

private struct ExploreRow: View {
    let name: String
    let icon: String
    let isSelected: Bool
    var body: some View {
        HStack {
            Label(name, systemImage: icon)
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct DomainRow: View {
    let name: String
    let icon: String
    let count: Int
    let size: Int64
    let isSelected: Bool
    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).lineLimit(1)
                    Text("\(count) files · \(AppModel.formatSize(size))").font(.caption2).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: icon) }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct PermissionView: View {
    @EnvironmentObject var model: AppModel
    let error: BackupError
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Can't read backups", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
            if case .permissionDenied = error {
                Button("Open Privacy Settings…") { model.openPrivacySettings() }
                Text("After enabling Full Disk Access, relaunch the app or press ⌘R.").font(.caption2).foregroundStyle(.tertiary)
            }
            Button("Choose Backups Folder…") { model.chooseBackupRoot() }
        }
        .padding(.vertical, 4)
    }
}
