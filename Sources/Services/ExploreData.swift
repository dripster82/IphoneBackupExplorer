import Foundation
import SQLite3

/// A generic parsed record shown by the data viewers (call log, Safari, voicemail, calendar, etc.).
struct DataRecord: Identifiable, Hashable {
    let id: String
    var title: String
    var subtitle: String
    var date: Date?
    var fields: [Field]
    var body: String?
    /// relativePath (suffix) of an associated media file in the backup, if any (voicemail audio, photo).
    var mediaPathSuffix: String?
    var mediaDomain: String?

    struct Field: Hashable { let label: String; let value: String }

    /// Text used for global/local search.
    var searchText: String {
        ([title, subtitle, body ?? ""] + fields.map { "\($0.label) \($0.value)" }).joined(separator: " ")
    }
}

/// The kinds of parsed-data viewers beyond Files/Contacts/Messages.
enum DataKind: String, CaseIterable, Identifiable, Hashable {
    case calls, callsLegacy, safariHistory, safariBookmarks, notes, voicemails, calendar, reminders, photos
    var id: String { rawValue }

    var title: String {
        switch self {
        case .calls, .callsLegacy: return "Call History"
        case .safariHistory: return "Safari History"
        case .safariBookmarks: return "Bookmarks"
        case .notes: return "Notes"
        case .voicemails: return "Voicemail"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .photos: return "Photo Metadata"
        }
    }
    var icon: String {
        switch self {
        case .calls, .callsLegacy: return "phone"
        case .safariHistory: return "safari"
        case .safariBookmarks: return "bookmark"
        case .notes: return "note.text"
        case .voicemails: return "recordingtape"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .photos: return "photo.stack"
        }
    }
    /// Whether to also load contacts, to resolve phone numbers to names.
    var needsContacts: Bool { self == .calls || self == .callsLegacy || self == .voicemails }

    /// The path suffix (and optional domain) that locates this database in the backup.
    var pathSuffix: String {
        switch self {
        case .calls: return "CallHistory.storedata"
        case .callsLegacy: return "call_history.db"
        case .safariHistory: return "Safari/History.db"
        case .safariBookmarks: return "Safari/Bookmarks.db"
        case .notes: return "NoteStore.sqlite"
        case .voicemails: return "Voicemail/voicemail.db"
        case .calendar: return "Calendar.sqlitedb"
        case .reminders: return "Calendar.sqlitedb"
        case .photos: return "Photos.sqlite"
        }
    }
}

enum ExploreParser {
    // Apple Core Data / CF absolute time (seconds since 2001-01-01).
    static func appleSeconds(_ v: Double) -> Date? {
        guard v > 0 else { return nil }
        // Some columns store nanoseconds; normalise.
        let s = v > 1_000_000_000_000 ? v / 1_000_000_000 : v
        return Date(timeIntervalSinceReferenceDate: s)
    }
    static func unixSeconds(_ v: Double) -> Date? { v > 0 ? Date(timeIntervalSince1970: v) : nil }

    static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var cols: Set<String> = []
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW { cols.insert(SQLiteReader.text(stmt, 1)) }
        }
        return cols
    }

    static func fmtDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s <= 0 { return "0s" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
    static func dateStr(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }

    // MARK: Dispatch

    static func parse(_ kind: DataKind, url: URL, resolver: ContactResolver?) throws -> [DataRecord] {
        guard let db = SQLiteReader.open(url) else { throw BackupError.sqlite("could not open \(kind.title) database") }
        defer { sqlite3_close(db) }
        switch kind {
        case .calls:          return try callHistory(db, resolver: resolver)
        case .callsLegacy:    return try callHistoryLegacy(db, resolver: resolver)
        case .safariHistory:  return try safariHistory(db)
        case .safariBookmarks:return try safariBookmarks(db)
        case .voicemails:     return try voicemails(db, resolver: resolver)
        case .calendar:       return try calendarItems(db, reminders: false)
        case .reminders:      return try calendarItems(db, reminders: true)
        case .notes:          return try notes(db)
        case .photos:         return try photos(db)
        }
    }

    // MARK: Calls (modern CallHistory.storedata — Core Data)

    static func callHistory(_ db: OpaquePointer, resolver: ContactResolver?) throws -> [DataRecord] {
        guard SQLiteReader.tableExists(db, "ZCALLRECORD") else { throw BackupError.sqlite("no call records") }
        let cols = columns(db, "ZCALLRECORD")
        let addr = cols.contains("ZADDRESS") ? "ZADDRESS" : "NULL"
        let orig = cols.contains("ZORIGINATED") ? "ZORIGINATED" : "NULL"
        let ans = cols.contains("ZANSWERED") ? "ZANSWERED" : "NULL"
        let dur = cols.contains("ZDURATION") ? "ZDURATION" : "0"
        let sql = "SELECT Z_PK, \(addr), ZDATE, \(dur), \(orig), \(ans) FROM ZCALLRECORD ORDER BY ZDATE DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [DataRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            var number = SQLiteReader.text(stmt, 1)
            if number.isEmpty, let blob = sqlite3_column_blob(stmt, 1) {
                number = String(decoding: Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1))), as: UTF8.self)
            }
            let date = appleSeconds(sqlite3_column_double(stmt, 2))
            let duration = sqlite3_column_double(stmt, 3)
            let originated = sqlite3_column_int(stmt, 4) == 1
            let answered = sqlite3_column_int(stmt, 5) == 1
            let name = resolver?.name(for: number) ?? (number.isEmpty ? "Unknown" : number)
            let dir = originated ? "Outgoing" : (answered ? "Incoming" : "Missed")
            out.append(DataRecord(id: "call-\(pk)", title: name,
                                  subtitle: "\(dir) · \(fmtDuration(duration)) · \(dateStr(date))",
                                  date: date,
                                  fields: [.init(label: "Number", value: number),
                                           .init(label: "Direction", value: dir),
                                           .init(label: "Duration", value: fmtDuration(duration)),
                                           .init(label: "When", value: dateStr(date))],
                                  body: nil, mediaPathSuffix: nil, mediaDomain: nil))
        }
        return out
    }

    static func callHistoryLegacy(_ db: OpaquePointer, resolver: ContactResolver?) throws -> [DataRecord] {
        guard SQLiteReader.tableExists(db, "call") else { throw BackupError.sqlite("no call table") }
        let sql = "SELECT ROWID, address, date, duration, flags FROM call ORDER BY date DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [DataRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let number = SQLiteReader.text(stmt, 1)
            let date = unixSeconds(sqlite3_column_double(stmt, 2))
            let duration = sqlite3_column_double(stmt, 3)
            let flags = sqlite3_column_int(stmt, 4)
            let dir = (flags & 1) != 0 ? "Outgoing" : "Incoming"
            let name = resolver?.name(for: number) ?? (number.isEmpty ? "Unknown" : number)
            out.append(DataRecord(id: "call-\(pk)", title: name,
                                  subtitle: "\(dir) · \(fmtDuration(duration)) · \(dateStr(date))", date: date,
                                  fields: [.init(label: "Number", value: number), .init(label: "Direction", value: dir),
                                           .init(label: "Duration", value: fmtDuration(duration)), .init(label: "When", value: dateStr(date))]))
        }
        return out
    }

    // MARK: Safari

    static func safariHistory(_ db: OpaquePointer) throws -> [DataRecord] {
        guard SQLiteReader.tableExists(db, "history_items") else { throw BackupError.sqlite("no Safari history") }
        let hasVisits = SQLiteReader.tableExists(db, "history_visits")
        let sql = hasVisits
            ? "SELECT hi.url, hv.title, hv.visit_time FROM history_visits hv JOIN history_items hi ON hi.id = hv.history_item ORDER BY hv.visit_time DESC LIMIT 5000"
            : "SELECT url, '' , 0 FROM history_items"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [DataRecord] = []; var i = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let urlStr = SQLiteReader.text(stmt, 0)
            let title = SQLiteReader.text(stmt, 1)
            let date = appleSeconds(sqlite3_column_double(stmt, 2))
            out.append(DataRecord(id: "hist-\(i)", title: title.isEmpty ? urlStr : title,
                                  subtitle: urlStr, date: date,
                                  fields: [.init(label: "URL", value: urlStr), .init(label: "Visited", value: dateStr(date))]))
            i += 1
        }
        return out
    }

    static func safariBookmarks(_ db: OpaquePointer) throws -> [DataRecord] {
        guard SQLiteReader.tableExists(db, "bookmarks") else { throw BackupError.sqlite("no bookmarks") }
        let cols = columns(db, "bookmarks")
        guard cols.contains("URL") || cols.contains("url") else { throw BackupError.sqlite("no bookmark URLs") }
        let urlCol = cols.contains("URL") ? "URL" : "url"
        let titleCol = cols.contains("title") ? "title" : (cols.contains("Title") ? "Title" : "''")
        let sql = "SELECT \(titleCol), \(urlCol) FROM bookmarks WHERE \(urlCol) IS NOT NULL AND \(urlCol) <> ''"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [DataRecord] = []; var i = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let title = SQLiteReader.text(stmt, 0); let urlStr = SQLiteReader.text(stmt, 1)
            out.append(DataRecord(id: "bm-\(i)", title: title.isEmpty ? urlStr : title, subtitle: urlStr, date: nil,
                                  fields: [.init(label: "URL", value: urlStr)]))
            i += 1
        }
        return out
    }

    // MARK: Voicemail

    static func voicemails(_ db: OpaquePointer, resolver: ContactResolver?) throws -> [DataRecord] {
        guard SQLiteReader.tableExists(db, "voicemail") else { throw BackupError.sqlite("no voicemail table") }
        let cols = columns(db, "voicemail")
        let dur = cols.contains("duration") ? "duration" : "0"
        let whereClause = cols.contains("trashed_date") ? "WHERE trashed_date IS NULL OR trashed_date = 0" : ""
        let sql = "SELECT ROWID, sender, date, \(dur) FROM voicemail \(whereClause) ORDER BY date DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BackupError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [DataRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let sender = SQLiteReader.text(stmt, 1)
            let date = unixSeconds(sqlite3_column_double(stmt, 2))
            let duration = sqlite3_column_double(stmt, 3)
            let name = resolver?.name(for: sender) ?? (sender.isEmpty ? "Unknown" : sender)
            out.append(DataRecord(id: "vm-\(pk)", title: name,
                                  subtitle: "\(fmtDuration(duration)) · \(dateStr(date))", date: date,
                                  fields: [.init(label: "From", value: sender), .init(label: "Duration", value: fmtDuration(duration)),
                                           .init(label: "When", value: dateStr(date))],
                                  body: nil, mediaPathSuffix: "Voicemail/\(pk).amr", mediaDomain: "HomeDomain"))
        }
        return out
    }

    // MARK: Calendar / Reminders (Calendar.sqlitedb)

    static func calendarItems(_ db: OpaquePointer, reminders: Bool) throws -> [DataRecord] {
        guard SQLiteReader.tableExists(db, "CalendarItem") else { throw BackupError.sqlite("no calendar items") }
        let cols = columns(db, "CalendarItem")
        let hasDue = cols.contains("due_date")
        let hasStart = cols.contains("start_date")
        let hasCompleted = cols.contains("completed")
        let summaryCol = cols.contains("summary") ? "summary" : "title"
        var out: [DataRecord] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if reminders {
            guard hasDue || hasCompleted else { return [] }
            let sql = "SELECT ROWID, \(summaryCol), \(hasDue ? "due_date" : "NULL"), \(hasCompleted ? "completed" : "0") FROM CalendarItem WHERE \(hasDue ? "due_date IS NOT NULL" : "1=0") ORDER BY \(hasDue ? "due_date" : "ROWID") DESC"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                let summary = SQLiteReader.text(stmt, 1)
                let due = appleSeconds(sqlite3_column_double(stmt, 2))
                let done = sqlite3_column_int(stmt, 3) == 1
                out.append(DataRecord(id: "rem-\(pk)", title: summary.isEmpty ? "(no title)" : summary,
                                      subtitle: (done ? "✓ Completed" : "○ Open") + (due != nil ? " · due \(dateStr(due))" : ""),
                                      date: due, fields: [.init(label: "Due", value: dateStr(due)), .init(label: "Status", value: done ? "Completed" : "Open")]))
            }
        } else {
            guard hasStart else { return [] }
            let sql = "SELECT ROWID, \(summaryCol), start_date, \(cols.contains("end_date") ? "end_date" : "start_date"), \(cols.contains("all_day") ? "all_day" : "0") FROM CalendarItem WHERE start_date IS NOT NULL ORDER BY start_date DESC"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(db))) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                let summary = SQLiteReader.text(stmt, 1)
                let start = appleSeconds(sqlite3_column_double(stmt, 2))
                let end = appleSeconds(sqlite3_column_double(stmt, 3))
                let allDay = sqlite3_column_int(stmt, 4) == 1
                out.append(DataRecord(id: "evt-\(pk)", title: summary.isEmpty ? "(no title)" : summary,
                                      subtitle: (allDay ? "All day · " : "") + dateStr(start),
                                      date: start,
                                      fields: [.init(label: "Starts", value: dateStr(start)), .init(label: "Ends", value: dateStr(end)),
                                               .init(label: "All day", value: allDay ? "Yes" : "No")]))
            }
        }
        return out
    }

    // MARK: Notes (modern NoteStore.sqlite — best effort)

    static func notes(_ db: OpaquePointer) throws -> [DataRecord] {
        if SQLiteReader.tableExists(db, "ZICCLOUDSYNCINGOBJECT") {
            let cols = columns(db, "ZICCLOUDSYNCINGOBJECT")
            let titleCol = cols.contains("ZTITLE1") ? "ZTITLE1" : (cols.contains("ZTITLE") ? "ZTITLE" : "NULL")
            let snippetCol = cols.contains("ZSNIPPET") ? "ZSNIPPET" : "NULL"
            let modCol = cols.contains("ZMODIFICATIONDATE1") ? "ZMODIFICATIONDATE1" : (cols.contains("ZMODIFICATIONDATE") ? "ZMODIFICATIONDATE" : "NULL")
            let sql = "SELECT Z_PK, \(titleCol), \(snippetCol), \(modCol) FROM ZICCLOUDSYNCINGOBJECT WHERE \(titleCol) IS NOT NULL AND \(titleCol) <> '' ORDER BY \(modCol) DESC"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw BackupError.sqlite("notes query failed") }
            var out: [DataRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                let title = SQLiteReader.text(stmt, 1)
                let snippet = SQLiteReader.text(stmt, 2)
                let mod = appleSeconds(sqlite3_column_double(stmt, 3))
                out.append(DataRecord(id: "note-\(pk)", title: title, subtitle: snippet, date: mod,
                                      fields: [.init(label: "Modified", value: dateStr(mod))],
                                      body: snippet.isEmpty ? nil : snippet))
            }
            return out
        }
        // Legacy notes.sqlite
        if SQLiteReader.tableExists(db, "ZNOTE") {
            let sql = "SELECT n.Z_PK, n.ZTITLE, b.ZCONTENT FROM ZNOTE n LEFT JOIN ZNOTEBODY b ON b.ZNOTE = n.Z_PK ORDER BY n.Z_PK DESC"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw BackupError.sqlite("notes query failed") }
            var out: [DataRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                let title = SQLiteReader.text(stmt, 1)
                let html = SQLiteReader.text(stmt, 2)
                let text = stripHTML(html)
                out.append(DataRecord(id: "note-\(pk)", title: title.isEmpty ? String(text.prefix(40)) : title,
                                      subtitle: String(text.prefix(80)), date: nil, fields: [], body: text))
            }
            return out
        }
        throw BackupError.sqlite("unrecognised Notes database")
    }

    static func stripHTML(_ s: String) -> String {
        var out = ""; var inTag = false
        for ch in s { if ch == "<" { inTag = true } else if ch == ">" { inTag = false } else if !inTag { out.append(ch) } }
        return out.replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Photos metadata (Photos.sqlite — best effort)

    static func photos(_ db: OpaquePointer) throws -> [DataRecord] {
        guard SQLiteReader.tableExists(db, "ZASSET") else { throw BackupError.sqlite("no photo assets") }
        let cols = columns(db, "ZASSET")
        let fn = cols.contains("ZFILENAME") ? "ZFILENAME" : "NULL"
        let dir = cols.contains("ZDIRECTORY") ? "ZDIRECTORY" : "NULL"
        let dc = cols.contains("ZDATECREATED") ? "ZDATECREATED" : "NULL"
        let lat = cols.contains("ZLATITUDE") ? "ZLATITUDE" : "NULL"
        let lon = cols.contains("ZLONGITUDE") ? "ZLONGITUDE" : "NULL"
        let fav = cols.contains("ZFAVORITE") ? "ZFAVORITE" : "0"
        let sql = "SELECT Z_PK, \(fn), \(dir), \(dc), \(lat), \(lon), \(fav) FROM ZASSET ORDER BY \(dc) DESC LIMIT 20000"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw BackupError.sqlite(String(cString: sqlite3_errmsg(db))) }
        var out: [DataRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let filename = SQLiteReader.text(stmt, 1)
            let directory = SQLiteReader.text(stmt, 2)
            let created = appleSeconds(sqlite3_column_double(stmt, 3))
            let latitude = sqlite3_column_double(stmt, 4)
            let longitude = sqlite3_column_double(stmt, 5)
            let favorite = sqlite3_column_int(stmt, 6) == 1
            var fields: [DataRecord.Field] = [.init(label: "File", value: filename), .init(label: "Created", value: dateStr(created))]
            var loc: String? = nil
            if latitude != 0, longitude != 0, latitude > -90, latitude < 90 {
                loc = String(format: "%.5f, %.5f", latitude, longitude)
                fields.append(.init(label: "Location", value: loc!))
            }
            if favorite { fields.append(.init(label: "Favorite", value: "Yes")) }
            let suffix = directory.isEmpty ? filename : "\(directory)/\(filename)"
            out.append(DataRecord(id: "asset-\(pk)", title: filename.isEmpty ? "Asset \(pk)" : filename,
                                  subtitle: [dateStr(created), loc].compactMap { $0 }.joined(separator: " · "),
                                  date: created, fields: fields, body: nil,
                                  mediaPathSuffix: "Media/\(suffix)", mediaDomain: "CameraRollDomain"))
        }
        return out
    }
}

extension DataRecord {
    /// CSV of a record set: a union of all field labels plus title/date/body.
    static func csv(_ records: [DataRecord]) -> String {
        func esc(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n"))
                ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
        }
        var labels: [String] = []
        for r in records { for f in r.fields where !labels.contains(f.label) { labels.append(f.label) } }
        var out = (["Title", "Date"] + labels + ["Body"]).map(esc).joined(separator: ",") + "\n"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for r in records {
            var row = [r.title, r.date.map { df.string(from: $0) } ?? ""]
            for label in labels { row.append(r.fields.first { $0.label == label }?.value ?? "") }
            row.append(r.body ?? "")
            out += row.map(esc).joined(separator: ",") + "\n"
        }
        return out
    }
}

extension ExploreParser {
    /// Modern Reminders live in Library/Reminders/Container_v1/Stores/Data-*.sqlite (Core Data),
    /// spread across several store files. Parse one store's ZREMCDREMINDER rows.
    static func remindersModern(url: URL) -> [DataRecord] {
        guard let db = SQLiteReader.open(url) else { return [] }
        defer { sqlite3_close(db) }
        guard SQLiteReader.tableExists(db, "ZREMCDREMINDER") else { return [] }
        let cols = columns(db, "ZREMCDREMINDER")
        func col(_ n: String, _ fallback: String = "NULL") -> String { cols.contains(n) ? n : fallback }
        let sql = "SELECT Z_PK, \(col("ZTITLE")), \(col("ZNOTES")), \(col("ZDUEDATE")), \(col("ZCOMPLETED","0")), \(col("ZCOMPLETIONDATE")), \(col("ZCREATIONDATE")), \(col("ZFLAGGED","0")) FROM ZREMCDREMINDER WHERE \(col("ZTITLE")) IS NOT NULL ORDER BY \(col("ZCREATIONDATE")) DESC"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [DataRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let title = SQLiteReader.text(stmt, 1)
            let notes = SQLiteReader.text(stmt, 2)
            let due = appleSeconds(sqlite3_column_double(stmt, 3))
            let done = sqlite3_column_int(stmt, 4) == 1
            let completed = appleSeconds(sqlite3_column_double(stmt, 5))
            let flagged = sqlite3_column_int(stmt, 7) == 1
            var fields: [DataRecord.Field] = [.init(label: "Status", value: done ? "Completed" : "Open")]
            if due != nil { fields.append(.init(label: "Due", value: dateStr(due))) }
            if completed != nil { fields.append(.init(label: "Completed", value: dateStr(completed))) }
            if flagged { fields.append(.init(label: "Flagged", value: "Yes")) }
            out.append(DataRecord(id: "rem-\(url.lastPathComponent)-\(pk)",
                                  title: title.isEmpty ? "(no title)" : title,
                                  subtitle: (done ? "✓ " : "○ ") + (due != nil ? "due \(dateStr(due))" : (notes.isEmpty ? "" : notes)),
                                  date: due ?? completed, fields: fields, body: notes.isEmpty ? nil : notes))
        }
        return out
    }
}
