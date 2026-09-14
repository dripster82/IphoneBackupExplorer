import Foundation

/// An opened backup: knows how to locate, decrypt and materialise any file in it.
final class BackupSession {
    let device: BackupDevice
    private let keybag: Keybag?
    private let manifestDBURL: URL
    private let workDirectory: URL
    private var materialised: [String: URL] = [:]
    private let lock = NSLock()

    static func workRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("IphoneBackupExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Opens a backup. `password` is required (and validated) for encrypted backups.
    init(device: BackupDevice, password: String?) throws {
        self.device = device
        workDirectory = BackupSession.workRoot().appendingPathComponent(device.id, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let rawManifest = device.url.appendingPathComponent("Manifest.db")
        guard FileManager.default.fileExists(atPath: rawManifest.path) else {
            throw device.hasManifestDB ? BackupError.manifestMissing : BackupError.legacyFormat
        }

        if device.isEncrypted {
            guard let password, !password.isEmpty else { throw BackupError.encryptedNeedsPassword }
            let plist = BackupLocator.manifestPlist(for: device)
            guard let keybagData = plist["BackupKeyBag"] as? Data,
                  let manifestKey = plist["ManifestKey"] as? Data, manifestKey.count > 4 else {
                throw BackupError.keybagMissing
            }
            let bag = try Keybag(data: keybagData)
            try bag.unlock(password: password)
            keybag = bag

            let classID = Int(manifestKey.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let key = try bag.unwrapKey(protectionClass: classID, wrappedKey: manifestKey.dropFirst(4))
            let encrypted = try Data(contentsOf: rawManifest)
            let decrypted = try Crypto.aesCBCDecryptNoPadding(key: key, data: encrypted)
            guard decrypted.starts(with: Data("SQLite format 3".utf8)) else { throw BackupError.wrongPassword }
            manifestDBURL = workDirectory.appendingPathComponent("Manifest.db")
            try decrypted.write(to: manifestDBURL, options: .atomic)
        } else {
            // Not flagged as encrypted. Verify the manifest really is a SQLite database before
            // handing it to SQLite, so we can give a useful error instead of a cryptic DB failure.
            let handle = try? FileHandle(forReadingFrom: rawManifest)
            let header = handle?.readData(ofLength: 16) ?? Data()
            try? handle?.close()
            if !header.starts(with: Data("SQLite format 3".utf8)) {
                let plist = BackupLocator.manifestPlist(for: device)
                if plist["ManifestKey"] != nil {
                    // The manifest really is encrypted; route to the password prompt.
                    throw BackupError.encryptedNeedsPassword
                }
                throw BackupError.notADatabase(header)
            }
            keybag = nil
            manifestDBURL = rawManifest
        }
    }

    func loadFiles(progress: ((Int) -> Void)? = nil) throws -> [BackupFile] {
        let db = try ManifestDatabase(url: manifestDBURL)
        return try db.loadFiles(progress: progress)
    }

    /// Writes the decrypted/plain contents of `file` to `destination` (overwriting).
    func extract(_ file: BackupFile, to destination: URL) throws {
        let source = file.storageURL(in: device.url)
        guard FileManager.default.fileExists(atPath: source.path) else { throw BackupError.fileMissing(file.id) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if let keybag, let wrapped = file.encryptionKey {
            let key = try keybag.unwrapKey(protectionClass: file.protectionClass, wrappedKey: wrapped)
            try Crypto.aesCBCDecryptFile(key: key, from: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        if let modified = file.modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
        }
    }

    /// Returns the file's plain contents (for small files such as plists / text).
    func contents(of file: BackupFile) throws -> Data {
        let source = file.storageURL(in: device.url)
        guard FileManager.default.fileExists(atPath: source.path) else { throw BackupError.fileMissing(file.id) }
        let raw = try Data(contentsOf: source)
        if let keybag, let wrapped = file.encryptionKey {
            let key = try keybag.unwrapKey(protectionClass: file.protectionClass, wrappedKey: wrapped)
            return try Crypto.aesCBCDecryptNoPadding(key: key, data: raw)
        }
        return raw
    }

    /// Returns a URL to a readable copy of the file with its real filename/extension
    /// (hard link for plain backups, decrypted copy for encrypted ones). Cached per session.
    func materialise(_ file: BackupFile) throws -> URL {
        lock.lock()
        if let cached = materialised[file.id], FileManager.default.fileExists(atPath: cached.path) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let source = file.storageURL(in: device.url)
        guard FileManager.default.fileExists(atPath: source.path) else { throw BackupError.fileMissing(file.id) }
        let dir = workDirectory.appendingPathComponent("preview", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = file.fileExtension
        var dest = dir.appendingPathComponent(file.id)
        if !ext.isEmpty { dest = dest.appendingPathExtension(ext) }

        if !FileManager.default.fileExists(atPath: dest.path) {
            if keybag != nil, file.encryptionKey != nil {
                try extract(file, to: dest)
            } else {
                do { try FileManager.default.linkItem(at: source, to: dest) }
                catch { try FileManager.default.copyItem(at: source, to: dest) }
            }
        }
        lock.lock()
        materialised[file.id] = dest
        lock.unlock()
        return dest
    }

    func clearCache() {
        lock.lock(); materialised.removeAll(); lock.unlock()
        try? FileManager.default.removeItem(at: workDirectory.appendingPathComponent("preview"))
    }
}
