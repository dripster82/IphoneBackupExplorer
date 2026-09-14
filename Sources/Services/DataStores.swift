import Foundation
import SQLite3

let SQLITE_TRANSIENT_DS = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Models

struct Contact: Identifiable, Hashable {
    let id: Int
    var first: String
    var last: String
    var middle: String
    var organization: String
    var nickname: String
    var phones: [String]
    var emails: [String]
    var note: String

    var fullName: String {
        let name = [first, middle, last].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        if !nickname.isEmpty { return nickname }
        if !organization.isEmpty { return organization }
        return phones.first ?? emails.first ?? "No Name"
    }
    var sortKey: String {
        let l = last.isEmpty ? first : last
        return (l.isEmpty ? fullName : l).lowercased()
    }
    var initials: String {
        let parts = fullName.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }
}

struct MessageAttachment: Hashable {
    let transferName: String
    let mime: String
    /// relativePath of the file inside the backup (MediaDomain), e.g. Library/SMS/Attachments/…
    let pathSuffix: String
    var isImage: Bool { mime.hasPrefix("image/") || ["jpg","jpeg","png","heic","heif","gif"].contains((pathSuffix as NSString).pathExtension.lowercased()) }
    var displayName: String { transferName.isEmpty ? (pathSuffix as NSString).lastPathComponent : transferName }
}

struct SMSMessage: Identifiable, Hashable {
    let id: Int
    let text: String
    let date: Date?
    let isFromMe: Bool
    let service: String
    let sender: String
    var attachments: [MessageAttachment] = []
}

struct Conversation: Identifiable, Hashable {
    let id: Int
    let name: String
    let handles: [String]
    var messages: [SMSMessage]
    var lastDate: Date? { messages.last?.date }
    var preview: String { messages.last.map { ($0.isFromMe ? "You: " : "") + $0.text } ?? "" }
}

// MARK: - SQLite helper

enum SQLiteReader {
    /// Opens a database read-only + immutable (never touches -wal/-shm), returning nil on failure.
    static func open(_ url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        var encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        encoded = encoded.replacingOccurrences(of: "?", with: "%3f").replacingOccurrences(of: "#", with: "%23")
        let uri = "file:\(encoded)?immutable=1"
        if sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK { return handle }
        sqlite3_close(handle); handle = nil
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK { return handle }
        sqlite3_close(handle)
        return nil
    }

    static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT_DS)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }
}

// MARK: - Contacts

enum ContactsStore {
    static func load(from url: URL) throws -> [Contact] {
        guard let db = SQLiteReader.open(url) else { throw BackupError.sqlite("could not open AddressBook") }
        defer { sqlite3_close(db) }
        guard SQLiteReader.tableExists(db, "ABPerson") else { throw BackupError.sqlite("not an Address Book database") }

        var people: [Int: Contact] = [:]
        var stmt: OpaquePointer?
        let personSQL = "SELECT ROWID, First, Last, Middle, Organization, Nickname, Note FROM ABPerson"
        if sqlite3_prepare_v2(db, personSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                people[id] = Contact(id: id,
                                     first: SQLiteReader.text(stmt, 1), last: SQLiteReader.text(stmt, 2),
                                     middle: SQLiteReader.text(stmt, 3), organization: SQLiteReader.text(stmt, 4),
                                     nickname: SQLiteReader.text(stmt, 5),
                                     phones: [], emails: [], note: SQLiteReader.text(stmt, 6))
            }
        }
        sqlite3_finalize(stmt); stmt = nil

        // property 3 = phone, 4 = email
        let mvSQL = "SELECT record_id, property, value FROM ABMultiValue WHERE property IN (3,4) AND value IS NOT NULL"
        if sqlite3_prepare_v2(db, mvSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rid = Int(sqlite3_column_int(stmt, 0))
                let prop = sqlite3_column_int(stmt, 1)
                let value = SQLiteReader.text(stmt, 2)
                guard !value.isEmpty, people[rid] != nil else { continue }
                if prop == 3 { people[rid]?.phones.append(value) } else { people[rid]?.emails.append(value) }
            }
        }
        sqlite3_finalize(stmt)

        return people.values.sorted { a, b in
            if a.sortKey != b.sortKey { return a.sortKey < b.sortKey }
            return a.id < b.id
        }
    }

    static func vCard(_ contacts: [Contact]) -> String {
        var out = ""
        for c in contacts {
            out += "BEGIN:VCARD\r\nVERSION:3.0\r\n"
            out += "N:\(c.last);\(c.first);\(c.middle);;\r\n"
            out += "FN:\(c.fullName)\r\n"
            if !c.organization.isEmpty { out += "ORG:\(c.organization)\r\n" }
            if !c.nickname.isEmpty { out += "NICKNAME:\(c.nickname)\r\n" }
            for p in c.phones { out += "TEL:\(p)\r\n" }
            for e in c.emails { out += "EMAIL:\(e)\r\n" }
            if !c.note.isEmpty { out += "NOTE:\(c.note.replacingOccurrences(of: "\n", with: "\\n"))\r\n" }
            out += "END:VCARD\r\n"
        }
        return out
    }
}

// MARK: - Messages

enum MessagesStore {
    static func load(from url: URL) throws -> [Conversation] {
        guard let db = SQLiteReader.open(url) else { throw BackupError.sqlite("could not open sms.db") }
        defer { sqlite3_close(db) }
        guard SQLiteReader.tableExists(db, "message") else { throw BackupError.sqlite("not a Messages database") }

        // handle id -> address
        var handleAddr: [Int: String] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT ROWID, id FROM handle", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW { handleAddr[Int(sqlite3_column_int(stmt, 0))] = SQLiteReader.text(stmt, 1) }
        }
        sqlite3_finalize(stmt); stmt = nil

        let hasChat = SQLiteReader.tableExists(db, "chat") && SQLiteReader.tableExists(db, "chat_message_join")
        // message id -> chat id
        var msgChat: [Int: Int] = [:]
        var chatName: [Int: String] = [:]
        var chatHandles: [Int: [String]] = [:]
        if hasChat {
            if sqlite3_prepare_v2(db, "SELECT ROWID, chat_identifier, display_name FROM chat", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let cid = Int(sqlite3_column_int(stmt, 0))
                    let ident = SQLiteReader.text(stmt, 1); let disp = SQLiteReader.text(stmt, 2)
                    chatName[cid] = disp.isEmpty ? ident : disp
                }
            }
            sqlite3_finalize(stmt); stmt = nil
            if sqlite3_prepare_v2(db, "SELECT chat_id, message_id FROM chat_message_join", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW { msgChat[Int(sqlite3_column_int(stmt, 1))] = Int(sqlite3_column_int(stmt, 0)) }
            }
            sqlite3_finalize(stmt); stmt = nil
            if SQLiteReader.tableExists(db, "chat_handle_join"),
               sqlite3_prepare_v2(db, "SELECT chat_id, handle_id FROM chat_handle_join", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let cid = Int(sqlite3_column_int(stmt, 0)); let hid = Int(sqlite3_column_int(stmt, 1))
                    if let a = handleAddr[hid] { chatHandles[cid, default: []].append(a) }
                }
            }
            sqlite3_finalize(stmt); stmt = nil
        }

        // Attachments: message_id -> [MessageAttachment]
        var msgAttachments: [Int: [MessageAttachment]] = [:]
        if SQLiteReader.tableExists(db, "attachment") && SQLiteReader.tableExists(db, "message_attachment_join") {
            let aSQL = "SELECT maj.message_id, a.filename, a.transfer_name, a.mime_type FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id"
            if sqlite3_prepare_v2(db, aSQL, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let mid = Int(sqlite3_column_int(stmt, 0))
                    var filename = SQLiteReader.text(stmt, 1)
                    let transfer = SQLiteReader.text(stmt, 2)
                    let mime = SQLiteReader.text(stmt, 3)
                    // Stored as "~/Library/SMS/Attachments/…"; strip the leading ~/ to get the backup path.
                    if filename.hasPrefix("~/") { filename = String(filename.dropFirst(2)) }
                    else if filename.hasPrefix("/var/mobile/") { filename = String(filename.dropFirst("/var/mobile/".count)) }
                    guard !filename.isEmpty else { continue }
                    msgAttachments[mid, default: []].append(MessageAttachment(transferName: transfer, mime: mime, pathSuffix: filename))
                }
            }
            sqlite3_finalize(stmt); stmt = nil
        }

        var convMessages: [Int: [SMSMessage]] = [:]
        let msgSQL = "SELECT ROWID, text, attributedBody, date, is_from_me, handle_id, service FROM message ORDER BY date ASC"
        if sqlite3_prepare_v2(db, msgSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let mid = Int(sqlite3_column_int(stmt, 0))
                var text = SQLiteReader.text(stmt, 1)
                if text.isEmpty, let blobPtr = sqlite3_column_blob(stmt, 2) {
                    let len = Int(sqlite3_column_bytes(stmt, 2))
                    text = decodeAttributedBody(Data(bytes: blobPtr, count: len))
                }
                let rawDate = sqlite3_column_int64(stmt, 3)
                let date = appleDate(rawDate)
                let fromMe = sqlite3_column_int(stmt, 4) == 1
                let hid = Int(sqlite3_column_int(stmt, 5))
                let service = SQLiteReader.text(stmt, 6)
                let sender = fromMe ? "You" : (handleAddr[hid] ?? "Unknown")
                let cid = msgChat[mid] ?? (hid == 0 ? -1 : 1_000_000 + hid) // fall back: group by handle when no chat table
                let msg = SMSMessage(id: mid, text: text, date: date, isFromMe: fromMe, service: service, sender: sender, attachments: msgAttachments[mid] ?? [])
                convMessages[cid, default: []].append(msg)
                if chatName[cid] == nil { chatName[cid] = handleAddr[hid] ?? "Unknown" }
                if hid != 0, let a = handleAddr[hid], !(chatHandles[cid]?.contains(a) ?? false) { chatHandles[cid, default: []].append(a) }
            }
        }
        sqlite3_finalize(stmt)

        let conversations = convMessages.map { (cid, msgs) -> Conversation in
            let handles = chatHandles[cid] ?? []
            let name = chatName[cid] ?? handles.first ?? "Unknown"
            return Conversation(id: cid, name: name, handles: handles, messages: msgs)
        }
        return conversations.sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    /// sms.db stores dates as seconds (old) or nanoseconds (iOS 11+) since 2001-01-01.
    static func appleDate(_ raw: Int64) -> Date? {
        guard raw != 0 else { return nil }
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000.0 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Best-effort extraction of message text from the `attributedBody` typedstream blob
    /// (modern iOS leaves `text` NULL and stores the string in an NSAttributedString archive).
    static func decodeAttributedBody(_ data: Data) -> String {
        guard let markerRange = data.range(of: Data("NSString".utf8)) else { return "" }
        var i = markerRange.upperBound
        // skip class/version bytes until the '+' (0x2B) start-of-string marker
        var guardCount = 0
        while i < data.count, data[i] != 0x2B, guardCount < 16 { i += 1; guardCount += 1 }
        guard i < data.count, data[i] == 0x2B else { return "" }
        i += 1
        guard i < data.count else { return "" }
        var length = Int(data[i]); i += 1
        if length == 0x81 {          // 1-byte flag, next 2 bytes little-endian length
            guard i + 1 < data.count else { return "" }
            length = Int(data[i]) | (Int(data[i + 1]) << 8); i += 2
        } else if length == 0x82 {   // next 3 bytes
            guard i + 2 < data.count else { return "" }
            length = Int(data[i]) | (Int(data[i + 1]) << 8) | (Int(data[i + 2]) << 16); i += 3
        }
        guard length > 0, i + length <= data.count else { return "" }
        return String(decoding: data[i..<i + length], as: UTF8.self)
    }

    static func transcript(_ conversation: Conversation) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var out = "Conversation with \(conversation.name)\n"
        if !conversation.handles.isEmpty { out += "Participants: \(conversation.handles.joined(separator: ", "))\n" }
        out += String(repeating: "=", count: 40) + "\n\n"
        for m in conversation.messages {
            let when = m.date.map { df.string(from: $0) } ?? "?"
            out += "[\(when)] \(m.sender): \(m.text)\n"
        }
        return out
    }
}

// MARK: - Linking SMS handles to contacts

/// Maps phone numbers / emails to contact names, tolerant of formatting and country-code differences.
struct ContactResolver {
    private var byEmail: [String: String] = [:]
    private var byPhone: [String: String] = [:]

    init(_ contacts: [Contact]) {
        for c in contacts {
            let name = c.fullName
            guard name != "No Name" else { continue }
            for e in c.emails where !e.isEmpty { byEmail[e.lowercased()] = name }
            for p in c.phones {
                let key = ContactResolver.phoneKey(p)
                if !key.isEmpty { byPhone[key] = name }
            }
        }
    }

    var isEmpty: Bool { byEmail.isEmpty && byPhone.isEmpty }

    /// Last 9 digits of a phone number (enough to match across +CC / spacing differences),
    /// or all digits when shorter.
    static func phoneKey(_ s: String) -> String {
        let digits = s.filter(\.isNumber)
        return digits.count > 9 ? String(digits.suffix(9)) : digits
    }

    func name(for handle: String) -> String? {
        if handle.contains("@") { return byEmail[handle.lowercased()] }
        let key = ContactResolver.phoneKey(handle)
        return key.isEmpty ? nil : byPhone[key]
    }
}

extension MessagesStore {
    /// Replaces raw phone/email identifiers with contact names where a match exists.
    /// The original addresses are kept in `handles` so the thread header can still show them.
    static func resolve(_ conversations: [Conversation], with resolver: ContactResolver) -> [Conversation] {
        guard !resolver.isEmpty else { return conversations }
        return conversations.map { convo in
            var name = convo.name
            // If the conversation title is just one of its raw handles, swap in the contact name.
            if convo.handles.contains(name) || convo.handles.count == 1 {
                let addr = convo.handles.first ?? name
                if let resolved = resolver.name(for: addr) { name = resolved }
            } else if convo.handles.count > 1 {
                // Group chat: build a names list, using contact names where known.
                let parts = convo.handles.map { resolver.name(for: $0) ?? $0 }
                if parts.contains(where: { resolver.name(for: $0) != nil }) || name.isEmpty {
                    name = parts.joined(separator: ", ")
                }
            }
            let messages = convo.messages.map { m -> SMSMessage in
                guard !m.isFromMe, let resolved = resolver.name(for: m.sender) else { return m }
                return SMSMessage(id: m.id, text: m.text, date: m.date, isFromMe: m.isFromMe,
                                  service: m.service, sender: resolved, attachments: m.attachments)
            }
            return Conversation(id: convo.id, name: name, handles: convo.handles, messages: messages)
        }
    }
}

extension ContactsStore {
    static func csv(_ contacts: [Contact]) -> String {
        func esc(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n"))
                ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
        }
        var out = "Name,First,Last,Organization,Phones,Emails,Note\n"
        for c in contacts {
            out += [c.fullName, c.first, c.last, c.organization,
                    c.phones.joined(separator: " / "), c.emails.joined(separator: " / "), c.note]
                .map(esc).joined(separator: ",") + "\n"
        }
        return out
    }
}
