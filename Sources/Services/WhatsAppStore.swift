import Foundation
import SQLite3

/// Parses WhatsApp's ChatStorage.sqlite into the same Conversation/SMSMessage model as iMessage,
/// so it can reuse the Messages UI.
enum WhatsAppStore {
    static func load(from url: URL, resolver: ContactResolver?) throws -> [Conversation] {
        guard let db = SQLiteReader.open(url) else { throw BackupError.sqlite("could not open ChatStorage") }
        defer { sqlite3_close(db) }
        guard SQLiteReader.tableExists(db, "ZWAMESSAGE"), SQLiteReader.tableExists(db, "ZWACHATSESSION") else {
            throw BackupError.sqlite("not a WhatsApp database")
        }

        // session Z_PK -> (name, jid)
        var sessionName: [Int: String] = [:]
        var sessionJID: [Int: String] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT Z_PK, ZPARTNERNAME, ZCONTACTJID FROM ZWACHATSESSION", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = Int(sqlite3_column_int(stmt, 0))
                sessionName[pk] = SQLiteReader.text(stmt, 1)
                sessionJID[pk] = SQLiteReader.text(stmt, 2)
            }
        }
        sqlite3_finalize(stmt); stmt = nil

        func phone(fromJID jid: String) -> String { String(jid.prefix { $0 != "@" }) }

        var convMessages: [Int: [SMSMessage]] = [:]
        let sql = "SELECT Z_PK, ZTEXT, ZMESSAGEDATE, ZISFROMME, ZCHATSESSION, ZFROMJID FROM ZWAMESSAGE ORDER BY ZMESSAGEDATE ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(db))) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let mid = Int(sqlite3_column_int(stmt, 0))
            let text = SQLiteReader.text(stmt, 1)
            let date = ExploreParser.appleSeconds(sqlite3_column_double(stmt, 2))
            let fromMe = sqlite3_column_int(stmt, 3) == 1
            let session = Int(sqlite3_column_int(stmt, 4))
            let fromJID = SQLiteReader.text(stmt, 5)
            guard !text.isEmpty else { continue }   // skip pure-media/system rows without text
            let partner = sessionName[session] ?? phone(fromJID: sessionJID[session] ?? "")
            let senderPhone = phone(fromJID: fromJID.isEmpty ? (sessionJID[session] ?? "") : fromJID)
            let sender = fromMe ? "You" : (resolver?.name(for: senderPhone) ?? (partner.isEmpty ? senderPhone : partner))
            convMessages[session, default: []].append(
                SMSMessage(id: mid, text: text, date: date, isFromMe: fromMe, service: "WhatsApp", sender: sender))
        }
        sqlite3_finalize(stmt)

        let conversations = convMessages.map { (session, msgs) -> Conversation in
            let jid = sessionJID[session] ?? ""
            let phoneNum = phone(fromJID: jid)
            let name = sessionName[session].flatMap { $0.isEmpty ? nil : $0 }
                ?? resolver?.name(for: phoneNum) ?? (phoneNum.isEmpty ? "Unknown" : phoneNum)
            return Conversation(id: session, name: name, handles: phoneNum.isEmpty ? [] : [phoneNum], messages: msgs)
        }
        return conversations.sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }
}
