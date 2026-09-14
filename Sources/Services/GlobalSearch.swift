import Foundation

/// A single cross-cutting search hit shown in the global search sheet.
struct GlobalResult: Identifiable, Hashable {
    enum Target: Hashable {
        case file(String)                 // fileID
        case contact(Int)
        case conversation(Int)
        case record(DataKind, String)     // kind + record id
    }
    let id: String
    let group: String
    let icon: String
    let title: String
    let subtitle: String
    let target: Target
}
