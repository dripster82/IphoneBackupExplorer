import SwiftUI

struct GlobalSearchView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.globalResults()
        let groups = Dictionary(grouping: results, by: \.group)
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search files, contacts, messages and data…", text: $model.globalSearchText)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { if let first = results.first { model.openResult(first) } }
                if !model.globalSearchText.isEmpty {
                    Button { model.globalSearchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            if model.globalSearchText.trimmingCharacters(in: .whitespaces).count < 2 {
                hint("Type at least two characters.")
            } else if results.isEmpty {
                hint("No matches. Contacts and messages are included once loaded.")
            } else {
                List {
                    ForEach(groups.keys.sorted(), id: \.self) { group in
                        Section(group) {
                            ForEach(groups[group] ?? []) { r in
                                Button { model.openResult(r) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: r.icon).foregroundStyle(.secondary).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(r.title).lineLimit(1)
                                            if !r.subtitle.isEmpty {
                                                Text(r.subtitle).font(.caption).foregroundStyle(.secondary)
                                                    .lineLimit(1).truncationMode(.middle)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 640, height: 460)
        .onAppear { focused = true; model.ensureSearchDataLoaded() }
    }

    private func hint(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
    }
}
