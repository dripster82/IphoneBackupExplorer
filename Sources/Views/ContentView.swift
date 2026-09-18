import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            Group {
                switch model.workspace {
                case .overview: OverviewView()
                case .files: FileBrowserView()
                case .contacts: ContactsListView()
                case .messages: MessagesListView()
                case .whatsapp: MessagesListView()
                case .data(.photos): PhotosGalleryView()
                case .data(.keychain): KeychainListView()
                case .data(let kind): DataListView(kind: kind)
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 620)
        } detail: {
            Group {
                switch model.workspace {
                case .overview: OverviewDetail()
                case .files: PreviewPane()
                case .contacts: ContactDetailView()
                case .messages: ConversationView()
                case .whatsapp: ConversationView()
                case .data(.photos): DataDetailView(kind: .photos)
                case .data(let kind): DataDetailView(kind: kind)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 380)
        }
        .onAppear {
            model.scan()
            updater.checkForUpdates()
        }
        .onChange(of: updater.updateAvailableVersion) { _, version in
            // Surface a found update once per launch without nagging on later re-checks.
            if version != nil, !updater.autoPrompted {
                updater.autoPrompted = true
                updater.showUpdatesUI = true
            }
        }
        .sheet(isPresented: $updater.showUpdatesUI) { UpdatesView() }
        .sheet(isPresented: $model.showGlobalSearch) { GlobalSearchView() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.openDroppedFolder(url) } }
            }
            return true
        }
        .sheet(item: $model.pendingPasswordDevice) { device in
            PasswordSheet(device: device)
        }
        .sheet(isPresented: Binding(get: { model.exportProgress != nil }, set: { _ in })) {
            ExportProgressSheet()
        }
        .sheet(isPresented: Binding(get: { model.copyProgress != nil }, set: { _ in })) {
            CopyProgressSheet()
        }
        .alert("Export Complete", isPresented: Binding(get: { model.exportResultMessage != nil },
                                                       set: { if !$0 { model.exportResultMessage = nil } })) {
            Button("OK") { model.exportResultMessage = nil }
        } message: {
            Text(model.exportResultMessage ?? "")
        }
        .alert("Error", isPresented: Binding(get: { model.alertMessage != nil },
                                             set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}
