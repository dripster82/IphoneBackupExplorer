import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    enum ViewMode: String, CaseIterable { case list, grid }

    // Backup discovery
    @Published var backupRoot: URL = {
        if let path = UserDefaults.standard.string(forKey: "backupRootPath"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return BackupLocator.defaultBackupRoot
    }() {
        didSet { UserDefaults.standard.set(backupRoot.path, forKey: "backupRootPath") }
    }
    @Published var devices: [BackupDevice] = []
    @Published var scanError: BackupError?
    @Published var isScanning = false

    // Open backup
    @Published var selectedDeviceID: String?
    @Published private(set) var session: BackupSession?
    @Published private(set) var allFiles: [BackupFile] = []
    @Published private(set) var domainSummaries: [DomainSummary] = []
    @Published var isLoadingFiles = false
    @Published var loadedCount = 0
    @Published var pendingPasswordDevice: BackupDevice?
    @Published var passwordError: String?

    // Workspace (files vs. parsed data views)
    enum Workspace: Equatable, Hashable { case files, contacts, messages, data(DataKind) }
    @Published var workspace: Workspace = .files
    @Published var contacts: [Contact] = []
    @Published var conversations: [Conversation] = []
    @Published var isLoadingData = false
    @Published var dataError: String?
    @Published var selectedContactID: Int?
    @Published var selectedConversationID: Int?
    @Published var contactSearch = ""
    @Published var messageSearch = ""

    // Generic data viewers (calls, Safari, voicemail, calendar, reminders, notes, photos)
    @Published var records: [DataRecord] = []
    @Published var selectedRecordID: String?
    @Published var dataSearch = ""
    private var recordCache: [DataKind: [DataRecord]] = [:]

    // Global search
    @Published var showGlobalSearch = false
    @Published var globalSearchText = ""

    // Browsing
    @Published var selectedCategory: FileCategory = .all
    @Published var selectedDomain: String?
    @Published var searchText = ""
    @Published var viewMode: ViewMode = .list
    @Published var selection: Set<String> = []
    @Published var sortOrder: [KeyPathComparator<BackupFile>] = [KeyPathComparator(\.relativePath)]
    @Published var showDirectories = false

    // Export
    @Published var exportProgress: ExportProgress?
    @Published var exportResultMessage: String?
    private var exportToken: CancelToken?

    // Copy whole backup
    @Published var copyProgress: CopyProgress?
    private var copyToken: CancelToken?

    @Published var alertMessage: String?

    private var openTask: Task<Void, Never>?

    var selectedDevice: BackupDevice? { devices.first { $0.id == selectedDeviceID } }

    // MARK: Discovery

    func scan() {
        isScanning = true
        scanError = nil
        let root = backupRoot
        Task.detached(priority: .userInitiated) {
            let result: Result<[BackupDevice], Error> = Result { try BackupLocator.scan(root: root) }
            await MainActor.run {
                self.isScanning = false
                switch result {
                case .success(let devices): self.devices = devices
                case .failure(let error):
                    self.devices = []
                    self.scanError = (error as? BackupError) ?? .permissionDenied(root)
                }
            }
        }
    }

    func chooseBackupRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the MobileSync Backup folder (contains one folder per device)"
        panel.directoryURL = backupRoot
        if panel.runModal() == .OK, let url = panel.url {
            backupRoot = url
            scan()
        }
    }

    func openSingleBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a single iPhone backup folder (contains Manifest.db)"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let device = try BackupLocator.load(backupFolder: url)
                if !devices.contains(where: { $0.id == device.id }) { devices.insert(device, at: 0) }
                select(device)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    /// Handle a folder dropped onto the window: open it as a single backup, or as a backups root.
    func openDroppedFolder(_ url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        let hasManifest = fm.fileExists(atPath: url.appendingPathComponent("Manifest.db").path)
            || fm.fileExists(atPath: url.appendingPathComponent("Info.plist").path)
        if hasManifest {
            do {
                let device = try BackupLocator.load(backupFolder: url)
                if !devices.contains(where: { $0.id == device.id }) { devices.insert(device, at: 0) }
                select(device)
            } catch { alertMessage = error.localizedDescription }
        } else {
            backupRoot = url
            scan()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Opening

    func select(_ device: BackupDevice?) {
        guard let device else { closeBackup(); return }
        if device.id == selectedDeviceID, session != nil { return }
        closeBackup()
        selectedDeviceID = device.id
        if device.isEncrypted {
            passwordError = nil
            pendingPasswordDevice = device
        } else {
            open(device, password: nil)
        }
    }

    func submitPassword(_ password: String) {
        guard let device = pendingPasswordDevice else { return }
        open(device, password: password)
    }

    func cancelPassword() {
        pendingPasswordDevice = nil
        selectedDeviceID = nil
    }

    private func open(_ device: BackupDevice, password: String?) {
        openTask?.cancel()
        isLoadingFiles = true
        loadedCount = 0
        openTask = Task {
            let result: Result<(BackupSession, [BackupFile]), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let session = try BackupSession(device: device, password: password)
                    let files = try session.loadFiles { count in
                        Task { @MainActor in self.loadedCount = count }
                    }
                    return .success((session, files))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled else { return }
            isLoadingFiles = false
            switch result {
            case .success(let (session, files)):
                pendingPasswordDevice = nil
                passwordError = nil
                self.session = session
                UserDefaults.standard.set(device.id, forKey: "lastDeviceID")
                self.allFiles = files
                self.domainSummaries = AppModel.summarise(files)
                self.selectedDomain = nil
                self.selectedCategory = .all
                self.selection = []
                self.workspace = .files
                self.contacts = []
                self.conversations = []
                self.selectedContactID = nil
                self.selectedConversationID = nil
                self.records = []
                self.selectedRecordID = nil
                self.recordCache = [:]
                self.dataError = nil
            case .failure(let error):
                if device.isEncrypted, case BackupError.wrongPassword = error {
                    passwordError = BackupError.wrongPassword.localizedDescription
                    pendingPasswordDevice = device
                } else if device.isEncrypted, pendingPasswordDevice != nil {
                    passwordError = error.localizedDescription
                } else {
                    alertMessage = error.localizedDescription
                    selectedDeviceID = nil
                }
            }
        }
    }

    func closeBackup() {
        openTask?.cancel()
        session?.clearCache()
        session = nil
        allFiles = []
        domainSummaries = []
        selection = []
        selectedDomain = nil
        searchText = ""
        selectedDeviceID = nil
        isLoadingFiles = false
        workspace = .files
        contacts = []
        conversations = []
        selectedContactID = nil
        selectedConversationID = nil
        records = []
        selectedRecordID = nil
        recordCache = [:]
    }

    // MARK: Parsed data views (Contacts / Messages)

    var contactsFile: BackupFile? {
        allFiles.first { $0.domain == "HomeDomain" && $0.relativePath == "Library/AddressBook/AddressBook.sqlitedb" }
    }
    var messagesFile: BackupFile? {
        allFiles.first { $0.domain == "HomeDomain" && $0.relativePath == "Library/SMS/sms.db" }
    }

    var filteredContacts: [Contact] {
        let q = contactSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return contacts }
        return contacts.filter {
            $0.fullName.localizedCaseInsensitiveContains(q)
                || $0.phones.contains { $0.localizedCaseInsensitiveContains(q) }
                || $0.emails.contains { $0.localizedCaseInsensitiveContains(q) }
                || $0.organization.localizedCaseInsensitiveContains(q)
        }
    }
    var filteredConversations: [Conversation] {
        let q = messageSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return conversations }
        return conversations.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.handles.contains { $0.localizedCaseInsensitiveContains(q) }
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }
    var selectedContact: Contact? { contacts.first { $0.id == selectedContactID } }
    var selectedConversation: Conversation? { conversations.first { $0.id == selectedConversationID } }

    func showFiles() { workspace = .files }

    // MARK: Generic data viewers

    /// Finds a backup file whose relativePath ends with `suffix` (optionally in a specific domain).
    func file(pathSuffix suffix: String, domain: String? = nil) -> BackupFile? {
        allFiles.first { f in
            f.isRegularFile && f.relativePath.hasSuffix(suffix) && (domain == nil || f.domain == domain)
        }
    }

    func dataFile(for kind: DataKind) -> BackupFile? { file(pathSuffix: kind.pathSuffix) }

    /// Which data viewers to offer, based on which databases exist in this backup.
    var availableDataKinds: [DataKind] {
        var kinds: [DataKind] = []
        for kind in DataKind.allCases where dataFile(for: kind) != nil {
            // Prefer modern call history over the legacy DB when both exist.
            if kind == .callsLegacy && kinds.contains(.calls) { continue }
            if kind == .calls, dataFile(for: .callsLegacy) != nil { /* keep modern, drop legacy later */ }
            kinds.append(kind)
        }
        if kinds.contains(.calls) { kinds.removeAll { $0 == .callsLegacy } }
        return kinds
    }

    var filteredRecords: [DataRecord] {
        let q = dataSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        return records.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
    }
    var selectedRecord: DataRecord? { records.first { $0.id == selectedRecordID } }

    /// The backup file backing a record's associated media (voicemail audio, photo), if present.
    func mediaFile(for record: DataRecord) -> BackupFile? {
        guard let suffix = record.mediaPathSuffix else { return nil }
        return file(pathSuffix: suffix, domain: record.mediaDomain)
    }

    func showData(_ kind: DataKind) {
        workspace = .data(kind)
        selectedRecordID = nil
        dataSearch = ""
        if let cached = recordCache[kind] {
            records = cached
            selectedRecordID = cached.first?.id
            return
        }
        records = []
        guard let session, let file = dataFile(for: kind) else { return }
        let needContacts = kind.needsContacts
        let contactsFile = self.contactsFile
        let existingContacts = self.contacts
        isLoadingData = true
        dataError = nil
        Task {
            let result: Result<[DataRecord], Error> = await Task.detached(priority: .userInitiated) {
                do {
                    var resolver: ContactResolver? = nil
                    if needContacts {
                        var list = existingContacts
                        if list.isEmpty, let cf = contactsFile { list = (try? ContactsStore.load(from: session.materialise(cf))) ?? [] }
                        resolver = ContactResolver(list)
                    }
                    let url = try session.materialise(file)
                    return .success(try ExploreParser.parse(kind, url: url, resolver: resolver))
                } catch { return .failure(error) }
            }.value
            isLoadingData = false
            guard workspace == .data(kind) else { return }
            switch result {
            case .success(let recs):
                recordCache[kind] = recs
                records = recs
                selectedRecordID = recs.first?.id
            case .failure(let error):
                dataError = error.localizedDescription
            }
        }
    }

    func showContacts() {
        workspace = .contacts
        guard contacts.isEmpty, let session, let file = contactsFile else { return }
        loadData(file: file, session: session) { url in try ContactsStore.load(from: url) }
            onSuccess: { self.contacts = $0; self.selectedContactID = $0.first?.id }
    }

    func showMessages() {
        workspace = .messages
        guard conversations.isEmpty, let session, let file = messagesFile else { return }
        let contactsFile = self.contactsFile
        let existingContacts = self.contacts
        isLoadingData = true
        dataError = nil
        Task {
            let result: Result<(convos: [Conversation], contacts: [Contact]), Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let convos = try MessagesStore.load(from: session.materialise(file))
                        // Load the address book too (if not already loaded) so handles can be named.
                        var contactsList = existingContacts
                        if contactsList.isEmpty, let cf = contactsFile {
                            contactsList = (try? ContactsStore.load(from: session.materialise(cf))) ?? []
                        }
                        let resolver = ContactResolver(contactsList)
                        return .success((MessagesStore.resolve(convos, with: resolver), contactsList))
                    } catch { return .failure(error) }
                }.value
            isLoadingData = false
            switch result {
            case .success(let (convos, loadedContacts)):
                self.conversations = convos
                self.selectedConversationID = convos.first?.id
                if self.contacts.isEmpty { self.contacts = loadedContacts }
            case .failure(let error):
                self.dataError = error.localizedDescription
            }
        }
    }

    private func loadData<T>(file: BackupFile, session: BackupSession,
                             parse: @escaping (URL) throws -> T,
                             onSuccess: @escaping (T) -> Void) {
        isLoadingData = true
        dataError = nil
        Task {
            let result: Result<T, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let url = try session.materialise(file)
                    return .success(try parse(url))
                } catch { return .failure(error) }
            }.value
            isLoadingData = false
            switch result {
            case .success(let value): onSuccess(value)
            case .failure(let error): dataError = error.localizedDescription
            }
        }
    }

    // MARK: Global search

    /// Load contacts/messages into their arrays for searching, without switching the visible workspace.
    func ensureSearchDataLoaded() {
        if let session, contacts.isEmpty, let cf = contactsFile {
            Task {
                let list = await Task.detached(priority: .utility) { (try? ContactsStore.load(from: session.materialise(cf))) ?? [] }.value
                if contacts.isEmpty { contacts = list }
            }
        }
        if let session, conversations.isEmpty, let mf = messagesFile {
            let existing = contacts
            let cf = contactsFile
            Task {
                let convos = await Task.detached(priority: .utility) { () -> [Conversation] in
                    guard let raw = try? MessagesStore.load(from: session.materialise(mf)) else { return [] }
                    var list = existing
                    if list.isEmpty, let cf { list = (try? ContactsStore.load(from: session.materialise(cf))) ?? [] }
                    return MessagesStore.resolve(raw, with: ContactResolver(list))
                }.value
                if conversations.isEmpty { conversations = convos }
            }
        }
    }

    func globalResults() -> [GlobalResult] {
        let q = globalSearchText.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var out: [GlobalResult] = []

        for f in allFiles where f.isRegularFile && f.relativePath.localizedCaseInsensitiveContains(q) {
            out.append(GlobalResult(id: "f-\(f.id)", group: "Files", icon: f.category.systemImage,
                                    title: f.fileName, subtitle: f.domainDisplayName + " · " + f.relativePath,
                                    target: .file(f.id)))
            if out.count > 60 { break }
        }
        for c in contacts where c.fullName.localizedCaseInsensitiveContains(q)
            || c.phones.contains(where: { $0.localizedCaseInsensitiveContains(q) })
            || c.emails.contains(where: { $0.localizedCaseInsensitiveContains(q) }) {
            out.append(GlobalResult(id: "c-\(c.id)", group: "Contacts", icon: "person.crop.circle",
                                    title: c.fullName, subtitle: (c.phones + c.emails).joined(separator: " · "),
                                    target: .contact(c.id)))
        }
        for convo in conversations where convo.name.localizedCaseInsensitiveContains(q)
            || convo.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(q) }) {
            let hit = convo.messages.first { $0.text.localizedCaseInsensitiveContains(q) }
            out.append(GlobalResult(id: "m-\(convo.id)", group: "Messages", icon: "message",
                                    title: convo.name, subtitle: hit?.text ?? convo.preview,
                                    target: .conversation(convo.id)))
        }
        for (kind, recs) in recordCache {
            for r in recs where r.searchText.localizedCaseInsensitiveContains(q) {
                out.append(GlobalResult(id: "r-\(kind.rawValue)-\(r.id)", group: kind.title, icon: kind.icon,
                                        title: r.title, subtitle: r.subtitle, target: .record(kind, r.id)))
            }
        }
        return out
    }

    func openResult(_ result: GlobalResult) {
        showGlobalSearch = false
        switch result.target {
        case .file(let id):
            showFiles(); selectedDomain = nil; selectedCategory = .all; searchText = ""
            selection = [id]
        case .contact(let cid):
            showContacts(); selectedContactID = cid
        case .conversation(let convoID):
            showMessages(); selectedConversationID = convoID
        case .record(let kind, let rid):
            showData(kind); selectedRecordID = rid
        }
    }

    func exportContacts() {
        guard !contacts.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Contacts.vcf"
        panel.allowedContentTypes = [.vCard, .commaSeparatedText]
        panel.message = "Export \(contacts.count) contacts (vCard, or choose .csv)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = url.pathExtension.lowercased() == "csv" ? ContactsStore.csv(contacts) : ContactsStore.vCard(contacts)
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { alertMessage = error.localizedDescription }
    }

    /// Export the current data viewer's records to CSV.
    func exportRecords(kind: DataKind) {
        guard !records.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(kind.title).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Export \(records.count) \(kind.title.lowercased()) rows as CSV"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DataRecord.csv(records).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { alertMessage = error.localizedDescription }
    }

    /// Export any backup file via a save panel (used for message attachments).
    func exportFileWithPanel(_ file: BackupFile, suggestedName: String) {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName.isEmpty ? file.fileName : suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try session.extract(file, to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { alertMessage = error.localizedDescription }
    }

    /// Export a single record's associated media file (voicemail audio, photo).
    func exportRecordMedia(_ record: DataRecord) {
        guard let session, let file = mediaFile(for: record) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try session.extract(file, to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { alertMessage = error.localizedDescription }
    }

    func exportConversation(_ conversation: Conversation) {
        let panel = NSSavePanel()
        let safe = conversation.name.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "Messages - \(safe).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MessagesStore.transcript(conversation).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { alertMessage = error.localizedDescription }
    }

    private static func summarise(_ files: [BackupFile]) -> [DomainSummary] {
        var counts: [String: (Int, Int64)] = [:]
        for f in files where f.isRegularFile {
            let e = counts[f.domain] ?? (0, 0)
            counts[f.domain] = (e.0 + 1, e.1 + f.size)
        }
        return counts.map { DomainSummary(domain: $0.key, fileCount: $0.value.0, totalSize: $0.value.1) }
            .sorted { a, b in
                let ap = a.domain.hasPrefix("AppDomain") || a.domain.hasPrefix("Sys")
                let bp = b.domain.hasPrefix("AppDomain") || b.domain.hasPrefix("Sys")
                if ap != bp { return !ap }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
    }

    // MARK: Filtering

    var filteredFiles: [BackupFile] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var result = allFiles.filter { file in
            if !showDirectories && !file.isRegularFile { return false }
            if let d = selectedDomain, file.domain != d { return false }
            if !selectedCategory.matches(file.category) { return false }
            if !query.isEmpty && !file.relativePath.localizedCaseInsensitiveContains(query)
                && !file.domain.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
        result.sort(using: sortOrder)
        return result
    }

    var selectedFiles: [BackupFile] {
        let ids = selection
        return filteredFiles.filter { ids.contains($0.id) }
    }

    var singleSelectedFile: BackupFile? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return allFiles.first { $0.id == id }
    }

    var categoryCounts: [FileCategory: Int] {
        var counts: [FileCategory: Int] = [:]
        for f in allFiles where f.isRegularFile && (selectedDomain == nil || f.domain == selectedDomain) {
            counts[f.category, default: 0] += 1
            counts[.all, default: 0] += 1
            if f.category == .photos || f.category == .videos { counts[.media, default: 0] += 1 }
        }
        return counts
    }

    // MARK: Export

    func exportSelected() { export(files: selectedFiles) }
    func exportAllVisible() { export(files: filteredFiles.filter { $0.isRegularFile }) }

    func export(files: [BackupFile]) {
        guard let session, !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export"
        panel.message = "Choose a destination folder for \(files.count) file\(files.count == 1 ? "" : "s")"

        let layoutPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        layoutPopup.addItems(withTitles: ["Keep folder structure (Domain/Path)", "Flat (all files in one folder)"])
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Layout:"), layoutPopup])
        accessory.orientation = .horizontal
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let options = ExportOptions(layout: layoutPopup.indexOfSelectedItem == 1 ? .flat : .preserveStructure)

        let token = CancelToken()
        exportToken = token
        exportProgress = ExportProgress(total: files.count)
        exportResultMessage = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let throttle = ProgressThrottle()
            let result = Exporter.export(files: files, from: session, to: destination, options: options,
                                         isCancelled: { token.isCancelled },
                                         progress: { state in
                                             if throttle.shouldEmit(force: state.completed == state.total) {
                                                 Task { @MainActor in self?.exportProgress = state }
                                             }
                                         })
            await MainActor.run {
                guard let self else { return }
                self.exportProgress = nil
                let ok = result.completed - result.failures.count
                var message = "Exported \(ok) of \(result.total) file\(result.total == 1 ? "" : "s") to \(destination.path)."
                if !result.failures.isEmpty {
                    let sample = result.failures.prefix(5).map { "• \($0.0.relativePath): \($0.1.localizedDescription)" }.joined(separator: "\n")
                    message += "\n\n\(result.failures.count) failed:\n\(sample)"
                    if result.failures.count > 5 { message += "\n…" }
                }
                if token.isCancelled { message = "Export cancelled. " + message }
                self.exportResultMessage = message
                if ok > 0 { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            }
        }
    }

    func cancelExport() { exportToken?.cancel() }

    // MARK: Copy whole backup

    /// Copies an entire backup folder (raw, still-encrypted blobs) to a destination the user picks.
    /// Works with no password because it never decrypts anything.
    func copyBackup(_ device: BackupDevice) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Copy Here"
        panel.message = "Choose where to copy the backup of “\(device.title)”. A folder named \(device.id) will be created inside."
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let destination = parent.appendingPathComponent(device.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.messageText = "“\(device.id)” already exists here"
            alert.informativeText = "A folder with this backup's name is already in that location. Replace it?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let token = CancelToken()
        copyToken = token
        copyProgress = CopyProgress(deviceTitle: device.title)
        let source = device.url
        Task.detached(priority: .userInitiated) { [weak self] in
            let throttle = ProgressThrottle()
            let result = BackupCopier.copy(from: source, to: destination,
                                           isCancelled: { token.isCancelled },
                                           progress: { state in
                                               if throttle.shouldEmit(force: state.completed == state.total) {
                                                   Task { @MainActor in self?.copyProgress = state }
                                               }
                                           })
            await MainActor.run {
                guard let self else { return }
                self.copyProgress = nil
                if token.isCancelled {
                    try? FileManager.default.removeItem(at: destination)
                    self.exportResultMessage = "Copy cancelled. Partial copy removed."
                } else if let error = result.error {
                    self.exportResultMessage = "Copy failed: \(error.localizedDescription)"
                } else {
                    self.exportResultMessage = "Copied \(result.completed) file\(result.completed == 1 ? "" : "s") (\(AppModel.formatSize(result.copiedBytes))) to \(destination.path)."
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            }
        }
    }

    func cancelCopy() { copyToken?.cancel() }

    // MARK: Helpers

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
