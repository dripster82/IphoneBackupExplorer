import Foundation

/// A decrypted keychain entry (a password, token, certificate reference, etc.).
struct KeychainItem: Identifiable {
    let id = UUID()
    let kind: Kind
    /// Account / username.
    var account: String?
    /// Service (generic passwords) or server (internet passwords).
    var service: String?
    /// Human-readable label.
    var label: String?
    /// Access group / owning app identifier.
    var accessGroup: String?
    /// The secret value (password / token), decoded as UTF-8 where possible.
    var secret: String?
    /// Raw secret bytes when not printable text.
    var secretData: Data?
    var created: Date?
    var modified: Date?
    /// Protocol + port for internet passwords, protocol type for others.
    var proto: String?
    /// A deleted item retained only as a tombstone for sync (no usable secret).
    var isTombstone = false
    /// Every decoded attribute, for the detail view.
    var attributes: [(String, String)] = []

    enum Kind: String { case genericPassword = "genp", internetPassword = "inet", certificate = "cert", key = "keys" }
}

/// Reads and decrypts the `keychain-backup.plist` from an *encrypted* backup.
enum KeychainStore {
    /// Parse every keychain item that can be decrypted with the given session's backup keybag.
    /// Items in "ThisDeviceOnly" protection classes cannot be recovered from any backup and are skipped.
    static func load(from data: Data, session: BackupSession) -> [KeychainItem] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return []
        }
        var items: [KeychainItem] = []
        for section in ["genp", "inet", "cert", "keys"] {
            guard let rows = plist[section] as? [[String: Any]],
                  let kind = KeychainItem.Kind(rawValue: section) else { continue }
            for row in rows {
                guard let blob = row["v_Data"] as? Data,
                      let plain = decryptItem(blob, session: session) else { continue }
                if let item = parseItem(plain, kind: kind) { items.append(item) }
            }
        }
        return items
    }

    /// Convenience: decode the keychain and present it as DataRecords for the generic data views.
    /// Only items carrying a recoverable secret (password/token) or account are shown.
    static func records(from data: Data, session: BackupSession) -> [DataRecord] {
        // Internal sync/bookkeeping attributes that add noise to the detail view.
        let noise: Set<String> = ["Account", "Service", "Server", "Password", "Access Group", "Protocol",
                                  "Created", "Modified", "sha1", "persistref", "UUID", "sync", "tomb",
                                  "musr", "atyp", "agrp", "vwht", "tkid", "sync1", "pdmn", "Accessible"]
        return load(from: data, session: session).compactMap { item -> DataRecord? in
            let hasSecret = item.secret != nil || item.secretData != nil
            // Drop tombstones (deleted items) and empty non-secret entries — pure noise for the user.
            if item.isTombstone && !hasSecret { return nil }
            let title = item.account ?? item.service ?? item.label ?? "(keychain item)"
            var fields: [DataRecord.Field] = [.init(label: "Type", value: typeLabel(item))]
            if let a = item.account, !a.isEmpty { fields.append(.init(label: "Account", value: a)) }
            if let s = item.service, !s.isEmpty {
                fields.append(.init(label: item.kind == .internetPassword ? "Server" : "Service", value: s))
            }
            if let secret = item.secret, !secret.isEmpty {
                fields.append(.init(label: "Password", value: secret))
            } else if let d = item.secretData {
                fields.append(.init(label: "Password", value: "\(d.count) bytes (binary)"))
            }
            if let g = item.accessGroup, !g.isEmpty { fields.append(.init(label: "Access Group", value: g)) }
            if let p = item.proto, !p.isEmpty { fields.append(.init(label: "Protocol", value: p)) }
            if let d = item.created { fields.append(.init(label: "Created", value: ExploreParser.dateStr(d))) }
            if let d = item.modified { fields.append(.init(label: "Modified", value: ExploreParser.dateStr(d))) }
            // Fold in any remaining meaningful attributes not already surfaced.
            for (k, v) in item.attributes where !noise.contains(k) && !v.isEmpty && v != "0" {
                if fields.contains(where: { $0.label == k }) { continue }
                fields.append(.init(label: k, value: v))
            }
            let subtitle = [typeLabel(item), item.service].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
            return DataRecord(id: item.id.uuidString,
                              title: title,
                              subtitle: hasSecret ? subtitle : "\(subtitle) · no stored secret",
                              date: item.modified ?? item.created,
                              fields: fields, body: nil)
        }
    }

    private static func typeLabel(_ item: KeychainItem) -> String {
        if item.service == "AirPort" { return "Wi-Fi Password" }
        switch item.kind {
        case .genericPassword: return "Password / Token"
        case .internetPassword: return "Website Login"
        case .certificate: return "Certificate"
        case .key: return "Key"
        }
    }

    /// Decrypts one item blob. Returns the DER attribute payload, or nil if the item's protection
    /// class is not recoverable from a backup (e.g. ThisDeviceOnly) or the tag fails.
    static func decryptItem(_ blob: Data, session: BackupSession) -> Data? {
        guard blob.count >= 12 else { return nil }
        func le32(_ o: Int) -> Int { Int(blob.subdata(in: o..<o+4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
        let clas = le32(4), wrapLen = le32(8)
        guard wrapLen > 0, blob.count >= 12 + wrapLen + 16 else { return nil }
        let wrapped = blob.subdata(in: 12..<12 + wrapLen)
        guard let key = session.keychainUnwrap(protectionClass: clas, wrappedKey: wrapped) else { return nil }
        let rest = blob.subdata(in: 12 + wrapLen..<blob.count)
        let ct = rest.subdata(in: 0..<rest.count - 16)
        let tag = rest.subdata(in: rest.count - 16..<rest.count)
        // iOS backup keychain items: AES-256-GCM, empty IV, empty AAD, tag appended.
        return Crypto.aesGCMDecrypt(key: key, iv: Data(), ciphertext: ct, tag: tag, aad: Data())
    }

    // MARK: - DER

    /// Minimal DER walker for the keychain attribute set: SET { SEQUENCE { UTF8String key, value } … }.
    private static func parseItem(_ der: Data, kind: KeychainItem.Kind) -> KeychainItem? {
        let bytes = [UInt8](der)
        var i = 0
        guard let (topTag, topLen, topHdr) = readTLV(bytes, i) else { return nil }
        guard topTag == 0x31 else { return nil }            // SET
        var item = KeychainItem(kind: kind)
        var attrs: [(String, String)] = []
        i = topHdr
        let end = topHdr + topLen
        while i < end {
            guard let (seqTag, seqLen, seqHdr) = readTLV(bytes, i) else { break }
            let seqEnd = seqHdr + seqLen
            if seqTag == 0x30 {                              // SEQUENCE { key, value }
                var j = seqHdr
                if let (kTag, kLen, kHdr) = readTLV(bytes, j), kTag == 0x0c {   // UTF8String key
                    let key = String(decoding: bytes[kHdr..<kHdr + kLen], as: UTF8.self)
                    j = kHdr + kLen
                    if let (vTag, vLen, vHdr) = readTLV(bytes, j) {
                        let valBytes = Array(bytes[vHdr..<min(vHdr + vLen, bytes.count)])
                        assign(&item, &attrs, key: key, tag: vTag, value: Data(valBytes))
                    }
                }
            }
            i = seqEnd
        }
        item.attributes = attrs
        return item
    }

    /// Reads one TLV. Returns (tag, contentLength, headerEndOffset) or nil.
    private static func readTLV(_ b: [UInt8], _ start: Int) -> (tag: Int, len: Int, hdrEnd: Int)? {
        guard start < b.count else { return nil }
        let tag = Int(b[start])
        var p = start + 1
        guard p <= b.count, p - 1 < b.count, p < b.count else { return nil }
        var len = Int(b[p]); p += 1
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n >= 1, n <= 4, p + n <= b.count else { return nil }
            len = 0
            for _ in 0..<n { len = (len << 8) | Int(b[p]); p += 1 }
        }
        guard p + len <= b.count else { return nil }
        return (tag, len, p)
    }

    private static func assign(_ item: inout KeychainItem, _ attrs: inout [(String, String)],
                               key: String, tag: Int, value: Data) {
        let text = decodeValue(tag: tag, value: value)
        switch key {
        case "acct": item.account = text
        case "svce", "srvr": item.service = text
        case "labl", "desc": if item.label == nil { item.label = text }
        case "agrp": item.accessGroup = text
        case "ptcl", "sdmn": if item.proto == nil, !text.isEmpty { item.proto = text }
        case "cdat": item.created = decodeDate(tag: tag, value: value)
        case "mdat": item.modified = decodeDate(tag: tag, value: value)
        case "tomb": item.isTombstone = (value.first ?? 0) != 0 || text == "1" || text == "true"
        case "v_Data", "data":
            if let s = String(data: value, encoding: .utf8), s.allSatisfy({ !$0.isNewline || true }), isMostlyPrintable(value) {
                item.secret = s
            } else {
                item.secretData = value
            }
        default: break
        }
        // Record every attribute (secret shown only as a length in the detail view).
        if key == "v_Data" || key == "data" {
            attrs.append((prettyKey(key), item.secret ?? "\(value.count) bytes"))
        } else if !text.isEmpty {
            attrs.append((prettyKey(key), text))
        }
    }

    private static func isMostlyPrintable(_ d: Data) -> Bool {
        guard !d.isEmpty else { return false }
        let printable = d.filter { $0 == 9 || $0 == 10 || $0 == 13 || ($0 >= 32 && $0 < 127) }.count
        return Double(printable) / Double(d.count) > 0.85
    }

    private static func decodeValue(tag: Int, value: Data) -> String {
        switch tag {
        case 0x0c, 0x13, 0x16:                               // UTF8String / Printable / IA5
            return String(decoding: value, as: UTF8.self)
        case 0x02:                                           // INTEGER
            var n = 0; for b in value { n = (n << 8) | Int(b) }; return String(n)
        case 0x01:                                           // BOOLEAN
            return (value.first ?? 0) != 0 ? "true" : "false"
        case 0x04:                                           // OCTET STRING
            if isMostlyPrintable(value) { return String(decoding: value, as: UTF8.self) }
            return value.isEmpty ? "" : "\(value.count) bytes"
        case 0x17, 0x18:                                     // UTCTime / GeneralizedTime
            return String(decoding: value, as: UTF8.self)
        default:
            return value.isEmpty ? "" : "\(value.count) bytes"
        }
    }

    private static func decodeDate(tag: Int, value: Data) -> Date? {
        // Keychain dates are usually CFAbsoluteTime doubles stored as a string or an OCTET STRING.
        if let s = String(data: value, encoding: .utf8), let t = Double(s) {
            return Date(timeIntervalSinceReferenceDate: t)
        }
        return nil
    }

    private static func prettyKey(_ k: String) -> String {
        switch k {
        case "acct": return "Account"
        case "svce": return "Service"
        case "srvr": return "Server"
        case "labl": return "Label"
        case "desc": return "Description"
        case "agrp": return "Access Group"
        case "ptcl": return "Protocol"
        case "port": return "Port"
        case "path": return "Path"
        case "sdmn": return "Security Domain"
        case "atyp": return "Auth Type"
        case "v_Data", "data": return "Password"
        case "gena": return "Generic"
        case "cdat": return "Created"
        case "mdat": return "Modified"
        case "pdmn": return "Accessible"
        default: return k
        }
    }
}
