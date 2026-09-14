import SwiftUI

@main
struct IphoneBackupExplorerApp: App {
    @StateObject private var model = AppModel()

    init() { SelfTest.runIfRequested() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Backup Folder…") { model.openSingleBackupFolder() }
                    .keyboardShortcut("o")
                Button("Choose Backups Location…") { model.chooseBackupRoot() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Copy Backup to Folder…") {
                    if let device = model.selectedDevice { model.copyBackup(device) }
                }
                .keyboardShortcut("d")
                .disabled(model.selectedDevice == nil)
                Divider()
                Button("Refresh Backups") { model.scan() }
                    .keyboardShortcut("r")
            }
            CommandMenu("Export") {
                Button("Export Selected Files…") { model.exportSelected() }
                    .keyboardShortcut("e")
                    .disabled(model.selection.isEmpty)
                Button("Export All Files in View…") { model.exportAllVisible() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.session == nil)
            }
        }
    }
}
