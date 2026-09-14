import Foundation
import SQLite3

/// Stand-in for the MBFile class archived inside each Files.file blob in Manifest.db.
@objc(MBFile) final class MBFile: NSObject, NSCoding {
    let size: Int64
    let protectionClass: Int
    let encryptionKey: Data?
    let lastModified: Int64
    let mode: Int

    init?(coder: NSCoder) {
        size = coder.decodeInt64(forKey: "Size")
        protectionClass = coder.decodeInteger(forKey: "ProtectionClass")
        encryptionKey = coder.decodeObject(forKey: "EncryptionKey") as? Data
        lastModified = coder.decodeInt64(forKey: "LastModified")
        mode = coder.decodeInteger(forKey: "Mode")
        super.init()
    }
    func encode(with coder: NSCoder) {}

    static func decode(_ blob: Data) -> MBFile? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(MBFile.self, forClassName: "MBFile")
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: "root") as? MBFile
    }
}

/// Read-only access to a (decrypted) Manifest.db.
final class ManifestDatabase {
    private var db: OpaquePointer?

    init(url: URL) throws {
        // Open read-only and `immutable=1` via a file: URI. immutable tells SQLite the file
        // cannot change, so it never tries to create or lock the -wal/-shm sidecars — the usual
        // cause of "unable to open database file" / "database is locked" on protected backups.
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        var encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        encoded = encoded.replacingOccurrences(of: "?", with: "%3f").replacingOccurrences(of: "#", with: "%23")
        let uri = "file:\(encoded)?immutable=1"
        var rc = sqlite3_open_v2(uri, &handle, flags, nil)
        if rc != SQLITE_OK {
            // Fall back to a plain read-only open by path.
            sqlite3_close(handle); handle = nil
            rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        }
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(handle)
            throw BackupError.sqlite(msg)
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    /// Loads all rows of the Files table, decoding each metadata blob.
    func loadFiles(progress: ((Int) -> Void)? = nil) throws -> [BackupFile] {
        let sql = "SELECT fileID, domain, relativePath, flags, file FROM Files"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BackupError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var files: [BackupFile] = []
        files.reserveCapacity(50_000)
        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let fileID = String(cString: sqlite3_column_text(stmt, 0))
            let domain = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let relativePath = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let flags = Int(sqlite3_column_int(stmt, 3))

            var size: Int64 = 0
            var modified: Date? = nil
            var protectionClass = 0
            var encryptionKey: Data? = nil
            if let blobPtr = sqlite3_column_blob(stmt, 4) {
                let blobLen = Int(sqlite3_column_bytes(stmt, 4))
                let blob = Data(bytes: blobPtr, count: blobLen)
                if let meta = MBFile.decode(blob) {
                    size = meta.size
                    protectionClass = meta.protectionClass
                    if meta.lastModified > 0 { modified = Date(timeIntervalSince1970: TimeInterval(meta.lastModified)) }
                    if let key = meta.encryptionKey, key.count > 4 { encryptionKey = key.dropFirst(4) }
                }
            }
            files.append(BackupFile(id: fileID, domain: domain, relativePath: relativePath, flags: flags,
                                    size: size, modified: modified, protectionClass: protectionClass, encryptionKey: encryptionKey))
            count += 1
            if count % 2000 == 0 { progress?(count) }
        }
        return files
    }
}
