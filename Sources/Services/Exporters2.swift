import Foundation

enum HTMLUtil {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "\n", with: "<br>")
    }
}

/// Renders a conversation as a self-contained HTML page with chat bubbles and inline images.
/// `imageData` supplies base64 data for an attachment path suffix (already decrypted/materialised).
enum TranscriptExport {
    static func html(_ conversation: Conversation, imageData: (MessageAttachment) -> (mime: String, base64: String)?) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var rows = ""
        for m in conversation.messages {
            let side = m.isFromMe ? "me" : "them"
            var inner = ""
            for att in m.attachments {
                if let img = imageData(att) {
                    inner += "<img src=\"data:\(img.mime);base64,\(img.base64)\" />"
                } else {
                    inner += "<div class=\"file\">📎 \(HTMLUtil.esc(att.displayName))</div>"
                }
            }
            if !m.text.isEmpty { inner += "<div class=\"txt\">\(HTMLUtil.esc(m.text))</div>" }
            let meta = "\(HTMLUtil.esc(m.sender)) · \(m.date.map { df.string(from: $0) } ?? "")"
            rows += "<div class=\"row \(side)\"><div class=\"bubble\">\(inner)<div class=\"meta\">\(meta)</div></div></div>\n"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(HTMLUtil.esc(conversation.name))</title>
        <style>
        body{font:14px -apple-system,Helvetica,Arial,sans-serif;background:#f2f2f7;margin:0;padding:20px;color:#000}
        h1{font-size:18px;text-align:center}
        .row{display:flex;margin:4px 0}.me{justify-content:flex-end}.them{justify-content:flex-start}
        .bubble{max-width:70%;padding:8px 12px;border-radius:16px;background:#e5e5ea}
        .me .bubble{background:#0b93f6;color:#fff}
        .bubble img{max-width:260px;border-radius:10px;display:block;margin:2px 0}
        .meta{font-size:10px;opacity:.6;margin-top:3px}
        .file{padding:4px 0}
        @media(prefers-color-scheme:dark){body{background:#000;color:#fff}.bubble{background:#26252a}}
        </style></head><body>
        <h1>\(HTMLUtil.esc(conversation.name))</h1>
        \(rows)
        </body></html>
        """
    }

    static func plain(_ conversation: Conversation) -> String { MessagesStore.transcript(conversation) }
}

/// Calendar events → iCalendar (.ics).
enum CalendarExport {
    static func ics(_ records: [DataRecord]) -> String {
        func stamp(_ d: Date) -> String {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmmss"; f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: d) + "Z"
        }
        var out = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//iPhone Backup Explorer//EN\r\n"
        for r in records {
            out += "BEGIN:VEVENT\r\n"
            out += "SUMMARY:\(r.title.replacingOccurrences(of: "\n", with: " "))\r\n"
            if let start = r.date { out += "DTSTART:\(stamp(start))\r\n" }
            if let ends = r.fields.first(where: { $0.label == "Ends" })?.value, !ends.isEmpty { /* end parsed from field text is unreliable; skip */ }
            out += "UID:\(r.id)@ibe\r\n"
            out += "END:VEVENT\r\n"
        }
        out += "END:VCALENDAR\r\n"
        return out
    }
}

/// Notes → a single Markdown document.
enum NotesExport {
    static func markdown(_ records: [DataRecord]) -> String {
        var out = "# Notes\n\n"
        for r in records {
            out += "## \(r.title)\n\n"
            if let d = r.date { out += "_\(ExploreParser.dateStr(d))_\n\n" }
            out += (r.body ?? r.subtitle) + "\n\n---\n\n"
        }
        return out
    }
}

/// Bookmarks → Netscape bookmark file (re-importable into browsers).
enum BookmarksExport {
    static func html(_ records: [DataRecord]) -> String {
        var out = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n"
        for r in records {
            let url = r.fields.first { $0.label == "URL" }?.value ?? r.subtitle
            out += "    <DT><A HREF=\"\(HTMLUtil.esc(url))\">\(HTMLUtil.esc(r.title))</A>\n"
        }
        out += "</DL><p>\n"
        return out
    }
}
