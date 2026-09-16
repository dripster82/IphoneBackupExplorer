import SwiftUI

/// A node in a parsed property list, for the expandable tree preview.
struct PlistNode: Identifiable {
    let id = UUID()
    let key: String
    let value: String?
    var children: [PlistNode]?

    static func build(_ key: String, _ value: Any) -> PlistNode {
        if let dict = value as? [String: Any] {
            let kids = dict.keys.sorted().map { build($0, dict[$0]!) }
            return PlistNode(key: key, value: "{\(dict.count)}", children: kids)
        }
        if let arr = value as? [Any] {
            let kids = arr.enumerated().map { build("[\($0.offset)]", $0.element) }
            return PlistNode(key: key, value: "[\(arr.count)]", children: kids)
        }
        return PlistNode(key: key, value: describe(value), children: nil)
    }

    static func describe(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let b as Bool where (value as? NSNumber) === (b as NSNumber): return b ? "true" : "false"
        case let d as Date:
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: d)
        case let data as Data:
            let hex = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            return "\(data.count) bytes: \(hex)\(data.count > 16 ? "…" : "")"
        case let n as NSNumber: return n.stringValue
        default: return "\(value)"
        }
    }

    static func root(_ object: Any) -> [PlistNode] {
        if let dict = object as? [String: Any] { return dict.keys.sorted().map { build($0, dict[$0]!) } }
        if let arr = object as? [Any] { return arr.enumerated().map { build("[\($0.offset)]", $0.element) } }
        return [build("value", object)]
    }
}

struct PlistTreeView: View {
    let nodes: [PlistNode]
    var body: some View {
        List(nodes, children: \.children) { node in
            HStack(alignment: .firstTextBaseline) {
                Text(node.key).fontWeight(.medium)
                if let v = node.value {
                    Spacer()
                    Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        .textSelection(.enabled).lineLimit(4)
                }
            }
            .font(.system(.caption, design: node.children == nil ? .monospaced : .default))
        }
        .listStyle(.sidebar)
    }
}
