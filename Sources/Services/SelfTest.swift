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
