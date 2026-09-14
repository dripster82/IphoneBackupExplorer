import SwiftUI
import AppKit

struct DataListView: View {
    @EnvironmentObject var model: AppModel
    let kind: DataKind

    var body: some View {
        Group {
            if model.isLoadingData && model.records.isEmpty {
                ProgressView("Reading \(kind.title)…")
            } else if let err = model.dataError {
                ContentUnavailableView("Can't Read \(kind.title)", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if model.records.isEmpty {
                ContentUnavailableView("No \(kind.title)", systemImage: kind.icon, description: Text("This backup has no \(kind.title.lowercased())."))
            } else {
                List(selection: $model.selectedRecordID) {
                    ForEach(model.filteredRecords) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(record.title, systemImage: kind.icon).lineLimit(1)
                                Spacer()
                                if let d = record.date {
                                    Text(d, format: .dateTime.day().month(.abbreviated).year()).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if !record.subtitle.isEmpty {
                                Text(record.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 1)
                        .tag(record.id)
                    }
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationSubtitle(model.records.isEmpty ? "" : "\(model.records.count) items")
        .searchable(text: $model.dataSearch, placement: .toolbar, prompt: "Search \(kind.title.lowercased())")
        .toolbar {
            ToolbarItem {
                Button { model.exportRecords(kind: kind) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(model.records.isEmpty)
                    .help("Export all \(kind.title.lowercased()) as CSV")
            }
        }
    }
}

struct DataDetailView: View {
    @EnvironmentObject var model: AppModel
    let kind: DataKind
    @State private var mediaURL: URL?
    @State private var image: NSImage?

    var body: some View {
        if let record = model.selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(record.title, systemImage: kind.icon).font(.title3).bold()

                    // Associated media (voicemail audio, photo).
                    if record.mediaPathSuffix != nil {
                        mediaView(for: record)
                    }

                    if !record.fields.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(record.fields, id: \.self) { f in
                                GridRow {
                                    Text(f.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                    Text(f.value).textSelection(.enabled)
                                }
                            }
                        }
                        .font(.callout)
                    }

                    if let body = record.body, !body.isEmpty {
                        Divider()
                        Text(body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let loc = record.fields.first(where: { $0.label == "Location" })?.value {
                        Button { openInMaps(loc) } label: { Label("Show on Map", systemImage: "map") }
                    }
                    if record.mediaPathSuffix != nil, model.mediaFile(for: record) != nil {
                        Button { model.exportRecordMedia(record) } label: { Label("Export File", systemImage: "square.and.arrow.up") }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: record.id) { await loadMedia(record) }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: kind.icon)
        }
    }

    @ViewBuilder private func mediaView(for record: DataRecord) -> some View {
        if let url = mediaURL {
            let ext = url.pathExtension.lowercased()
            if ["amr", "m4a", "mp3", "wav", "caf", "aac"].contains(ext) {
                AVPlayerViewRepresentable(url: url).frame(height: 80)
            } else if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                QuickLookView(url: url).frame(height: 280)
            }
        } else if model.mediaFile(for: record) != nil {
            ProgressView().controlSize(.small)
        } else {
            Label("Media file not found in backup", systemImage: "questionmark.square.dashed")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadMedia(_ record: DataRecord) async {
        mediaURL = nil; image = nil
        guard let file = model.mediaFile(for: record), let session = model.session else { return }
        let url = try? await Task.detached(priority: .userInitiated) { try session.materialise(file) }.value
        mediaURL = url
        if let url, ["jpg","jpeg","png","heic","heif","gif","tiff"].contains(url.pathExtension.lowercased()) {
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }

    private func openInMaps(_ coords: String) {
        let q = coords.replacingOccurrences(of: " ", with: "")
        if let url = URL(string: "https://maps.apple.com/?ll=\(q)") { NSWorkspace.shared.open(url) }
    }
}
