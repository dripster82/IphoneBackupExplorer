import SwiftUI

/// The Passwords (keychain) list, grouped into collapsible sections by credential type.
struct KeychainListView: View {
    @EnvironmentObject var model: AppModel
    /// Sections start collapsed; the user expands the type they want.
    @State private var collapsed: Set<String> = ["website", "wifi", "application", "system"]

    /// Section order + presentation.
    private static let groupInfo: [(key: String, title: String, icon: String)] = [
        ("website", "Website Logins", "globe"),
        ("wifi", "Wi-Fi Passwords", "wifi"),
        ("application", "App Passwords", "app.badge"),
        ("system", "System Items", "gearshape"),
    ]

    var body: some View {
        Group {
            if model.isLoadingData && model.records.isEmpty {
                ProgressView("Reading Passwords…")
            } else if let err = model.dataError {
                ContentUnavailableView("Can't Read Passwords", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if model.records.isEmpty {
                ContentUnavailableView("No Passwords", systemImage: "key.fill", description: Text("This backup has no keychain data."))
            } else {
                let grouped = Dictionary(grouping: model.filteredRecords, by: { $0.group ?? "other" })
                List(selection: $model.recordSelection) {
                    ForEach(Self.groupInfo, id: \.key) { info in
                        if let rows = grouped[info.key], !rows.isEmpty {
                            Section(isExpanded: expansion(info.key)) {
                                ForEach(rows) { record in row(record) }
                            } header: {
                                header(info, rows: rows)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Passwords")
        .navigationSubtitle(subtitle)
        .searchable(text: $model.dataSearch, placement: .toolbar, prompt: "Search passwords")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Toggle("Sort by name", isOn: $model.dataSortByName)
                    Divider()
                    Toggle("Show system items (\(model.keychainSystemCount))", isOn: $model.keychainShowSystem)
                    Divider()
                    Button("Select All (\(model.filteredRecords.count))") { model.selectAllVisibleRecords() }
                    Button("Deselect All") { model.recordSelection = [] }
                        .disabled(model.recordSelection.isEmpty)
                } label: { Label("Options", systemImage: "slider.horizontal.3") }
                Menu {
                    Button("Export Selected (\(model.recordSelection.count))") { model.exportRecords(kind: .keychain) }
                        .disabled(model.recordSelection.isEmpty)
                    Button("Export All Shown (\(model.filteredRecords.count))") {
                        model.exportRecords(kind: .keychain, rows: model.filteredRecords)
                    }
                    Divider()
                    ForEach(Self.groupInfo, id: \.key) { info in
                        let rows = model.filteredRecords.filter { $0.group == info.key }
                        if !rows.isEmpty {
                            Button("Export \(info.title) (\(rows.count))") { model.exportRecords(kind: .keychain, rows: rows) }
                        }
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(model.records.isEmpty)
                    .help("Export selected, all, or a whole section")
            }
        }
    }

    private func header(_ info: (key: String, title: String, icon: String), rows: [DataRecord]) -> some View {
        Label("\(info.title)  (\(rows.count))", systemImage: info.icon)
            .font(.callout.weight(.semibold))
            .contentShape(Rectangle())
            .onTapGesture {
                if collapsed.contains(info.key) { collapsed.remove(info.key) } else { collapsed.insert(info.key) }
            }
            .contextMenu {
                Button("Select All \(info.title) (\(rows.count))") { model.selectRecords(inGroup: info.key) }
                Button("Export \(info.title)…") { model.exportRecords(kind: .keychain, rows: rows) }
            }
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(key) },
                set: { open in if open { collapsed.remove(key) } else { collapsed.insert(key) } })
    }

    private func row(_ record: DataRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.title).lineLimit(1)
            if !record.subtitle.isEmpty {
                Text(record.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 1)
        .tag(record.id)
    }

    private var subtitle: String {
        let n = model.filteredRecords.count
        let sel = model.recordSelection.count
        return sel > 0 ? "\(sel) selected of \(n)" : "\(n) items"
    }
}
