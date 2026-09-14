import Foundation
import AppKit

/// Headless helpers driven by launch arguments.
///  -selfTest <backupFolder> [-password <pw>] [-out <dir>]   full open + optional export
///  -diagnose <backupFolder> [-diagOut <file>]               write a diagnosis of why a backup won't open
enum SelfTest {
    static func runIfRequested() {
        let defaults = UserDefaults.standard
        if let folder = defaults.string(forKey: "diagnose"), !folder.isEmpty {
            diagnose(folder: folder, out: defaults.string(forKey: "diagOut"))
        }
        if defaults.bool(forKey: "diagnosePick") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.message = "Select the backup folder to diagnose"
            panel.prompt = "Diagnose"
            if panel.runModal() == .OK, let url = panel.url {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                diagnose(folder: url.path, out: defaults.string(forKey: "diagOut"))
            } else {
                exit(0)
            }
        }
        if let folder = defaults.string(forKey: "listExplore"), !folder.isEmpty {
            do {
                let device = try BackupLocator.load(backupFolder: URL(fileURLWithPath: folder))
                let session = try BackupSession(device: device, password: defaults.string(forKey: "password"))
                let files = try session.loadFiles()
                print("files: \(files.count)")
                func has(_ suffix: String) -> Bool { files.contains { $0.isRegularFile && $0.relativePath.hasSuffix(suffix) } }
                print("contacts file: \(has("AddressBook.sqlitedb"))")
                print("messages file: \(has("SMS/sms.db"))")
                for kind in DataKind.allCases where has(kind.pathSuffix) {
                    print("explore kind available: \(kind.rawValue) (\(kind.title))")
                }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        if let raw = defaults.string(forKey: "parseData"), !raw.isEmpty,
           let db = defaults.string(forKey: "db"), !db.isEmpty {
            if raw == "remindersModern" {
                let recs = ExploreParser.remindersModern(url: URL(fileURLWithPath: db))
                print("remindersModern: \(recs.count) records")
                for r in recs.prefix(8) { print("  • \(r.title) | \(r.subtitle)") }
                exit(0)
            }
            guard let kind = DataKind(rawValue: raw) else { print("unknown kind \(raw)"); exit(1) }
            do {
                let recs = try ExploreParser.parse(kind, url: URL(fileURLWithPath: db), resolver: nil)
                print("\(kind.title): \(recs.count) records")
                for r in recs.prefix(8) {
                    print("  • \(r.title) | \(r.subtitle) | media=\(r.mediaPathSuffix ?? "-")")
                }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        if defaults.bool(forKey: "checkUpdate") {
            let current = defaults.string(forKey: "asVersion") ?? "1.0.0"
            let sem = DispatchSemaphore(value: 0)
            Task {
                defer { sem.signal() }
                struct GHAsset: Decodable { let name: String; let browser_download_url: String }
                struct GHRelease: Decodable { let tag_name: String; let html_url: String; let draft: Bool; let assets: [GHAsset] }
                let url = URL(string: "https://api.github.com/repos/dripster82/IphoneBackupExplorer/releases?per_page=30")!
                var req = URLRequest(url: url); req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    print("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                    let releases = try JSONDecoder().decode([GHRelease].self, from: data)
                    let cur = AppVersion(current)!
                    for r in releases {
                        let v = AppVersion(r.tag_name)
                        print("  release \(r.tag_name) -> parsed \(v?.raw ?? "nil") channel=\(v.map { "\($0.channel)" } ?? "-") draft=\(r.draft) assets=\(r.assets.map(\.name))")
                    }
                    let best = releases.compactMap { r -> (AppVersion, GHRelease)? in
                        guard !r.draft, let v = AppVersion(r.tag_name) else { return nil }; return (v, r)
                    }.max(by: { $0.0 < $1.0 })
                    if let best {
                        let asset = Updater.pickDMGAsset(best.1.assets.map { ($0.name, $0.browser_download_url) })
                        print("current=\(current) best=\(best.0.raw) newer=\(cur < best.0) dmg=\(asset?.lastPathComponent ?? "none")")
                    } else { print("no candidate releases") }
                } catch { print("ERROR: \(error.localizedDescription)") }
            }
            sem.wait()
            exit(0)
        }
        if let db = defaults.string(forKey: "parseContacts"), !db.isEmpty {
            do {
                let contacts = try ContactsStore.load(from: URL(fileURLWithPath: db))
                print("contacts: \(contacts.count)")
                for c in contacts.prefix(10) { print("  \(c.fullName) | phones=\(c.phones) emails=\(c.emails) org=\(c.organization)") }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        if let db = defaults.string(forKey: "parseMessages"), !db.isEmpty {
            do {
                var convos = try MessagesStore.load(from: URL(fileURLWithPath: db))
                if let ab = defaults.string(forKey: "withContacts"), !ab.isEmpty {
                    let contacts = try ContactsStore.load(from: URL(fileURLWithPath: ab))
                    convos = MessagesStore.resolve(convos, with: ContactResolver(contacts))
                    print("(resolved against \(contacts.count) contacts)")
                }
                print("conversations: \(convos.count)")
                for c in convos.prefix(10) {
                    print("  [\(c.name)] handles=\(c.handles) msgs=\(c.messages.count) last=\(c.lastDate.map { "\($0)" } ?? "-")")
                    for m in c.messages.prefix(4) { print("      \(m.isFromMe ? "Me" : m.sender): \(m.text)") }
                }
                exit(0)
            } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
        }
        guard let folder = defaults.string(forKey: "selfTest"), !folder.isEmpty else { return }
        let password = defaults.string(forKey: "password")
        let out = defaults.string(forKey: "out").map { URL(fileURLWithPath: $0) }
        do {
            let device = try BackupLocator.load(backupFolder: URL(fileURLWithPath: folder))
            print("device: \(device.title) \(device.subtitle) encrypted=\(device.isEncrypted) apps=\(device.installedApps.count)")
            let session = try BackupSession(device: device, password: password)
            let files = try session.loadFiles()
            print("files: \(files.count)")
            for f in files.sorted(by: { $0.relativePath < $1.relativePath }) {
                print("  [\(f.isDirectory ? "D" : "F")] \(f.domain) \(f.relativePath) size=\(f.size) cat=\(f.category.rawValue) class=\(f.protectionClass) key=\(f.encryptionKey?.count ?? 0)")
            }
            if let out {
                let regular = files.filter(\.isRegularFile)
                let result = Exporter.export(files: regular, from: session, to: out, options: ExportOptions(), isCancelled: { false }, progress: { _ in })
                print("exported: \(result.completed - result.failures.count)/\(result.total)")
                for (f, e) in result.failures { print("  FAIL \(f.relativePath): \(e.localizedDescription)") }
            }
            exit(0)
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Produces a plain-text diagnosis without needing a password, and writes it to `out` (or stdout).
    private static func diagnose(folder: String, out: String?) {
        var lines: [String] = []
        func log(_ s: String) { lines.append(s) }
        let url = URL(fileURLWithPath: folder)
        let fm = FileManager.default
        log("Backup folder: \(folder)")
        log("Readable: \(fm.isReadableFile(atPath: folder))")

        for name in ["Manifest.db", "Manifest.plist", "Info.plist", "Status.plist", "Manifest.mbdb", "Manifest.db-wal", "Manifest.db-shm"] {
            let p = url.appendingPathComponent(name).path
            if let attrs = try? fm.attributesOfItem(atPath: p) {
                log("  \(name): \(attrs[.size] as? Int ?? -1) bytes")
            }
        }

        let manifestDB = url.appendingPathComponent("Manifest.db")
        if let handle = try? FileHandle(forReadingFrom: manifestDB) {
            let header = handle.readData(ofLength: 16)
            try? handle.close()
            let hex = header.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(decoding: header, as: UTF8.self).map { $0.isASCII && $0 != "\0" ? $0 : "." }
            log("Manifest.db header hex : \(hex)")
            log("Manifest.db header text: \(String(ascii))")
            log("Looks like SQLite      : \(header.starts(with: Data("SQLite format 3".utf8)))")
        } else {
            log("Manifest.db: could not open for reading (permission or missing)")
        }

        let mpData = (try? Data(contentsOf: url.appendingPathComponent("Manifest.plist"))) ?? Data()
        let mp = ((try? PropertyListSerialization.propertyList(from: mpData, options: [], format: nil)) as? [String: Any]) ?? [:]
        if mp.isEmpty {
            log("Manifest.plist: empty or unreadable")
        } else {
            log("Manifest.plist IsEncrypted : \(mp["IsEncrypted"].map { "\($0)" } ?? "absent")")
            log("Manifest.plist Version     : \(mp["Version"].map { "\($0)" } ?? "absent")")
            log("Manifest.plist BackupKeyBag: \((mp["BackupKeyBag"] as? Data)?.count.description ?? "absent") bytes")
            log("Manifest.plist ManifestKey : \((mp["ManifestKey"] as? Data)?.count.description ?? "absent") bytes")
        }

        do {
            let device = try BackupLocator.load(backupFolder: url)
            log("Parsed device: \(device.title) | \(device.subtitle) | encrypted=\(device.isEncrypted)")
        } catch {
            log("Parse Info/Manifest: ERROR \(error.localizedDescription)")
        }

        // Try opening without a password to reproduce the DB error the UI shows.
        do {
            let device = try BackupLocator.load(backupFolder: url)
            let session = try BackupSession(device: device, password: nil)
            let files = try session.loadFiles()
            log("Open (no password): SUCCESS, \(files.count) files")
        } catch {
            log("Open (no password): \(error.localizedDescription)")
        }

        let text = lines.joined(separator: "\n") + "\n"
        if let out {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        }
        print(text)
        exit(0)
    }
}
