import SwiftUI
import AppKit
import MapKit
import ImageIO
import CoreLocation

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
                List(selection: $model.recordSelection) {
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
        .navigationSubtitle(subtitle)
        .searchable(text: $model.dataSearch, placement: .toolbar, prompt: "Search \(kind.title.lowercased())")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Toggle("Sort by name", isOn: $model.dataSortByName)
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                Button { model.exportRecords(kind: kind) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(model.records.isEmpty)
                    .help("Export selected rows (or all shown)")
            }
        }
    }

    private var subtitle: String {
        let n = model.filteredRecords.count
        let sel = model.recordSelection.count
        return sel > 0 ? "\(sel) selected of \(n)" : "\(n) items"
    }
}

struct DataDetailView: View {
    @EnvironmentObject var model: AppModel
    let kind: DataKind
    @State private var mediaURL: URL?
    @State private var image: NSImage?
    @State private var exif: [(String, String)] = []
    @State private var coordinate: CLLocationCoordinate2D?

    var body: some View {
        if let record = model.currentRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(record.title, systemImage: kind.icon).font(.title3).bold()

                    // Associated media (voicemail audio, photo).
                    if record.mediaPathSuffix != nil {
                        mediaView(for: record)
                    }

                    if let coordinate {
                        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))) {
                            Marker(record.title, coordinate: coordinate)
                        }
                        .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !exif.isEmpty {
                        DisclosureGroup("Photo details") {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                ForEach(exif, id: \.0) { e in
                                    GridRow { Text(e.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing); Text(e.1).textSelection(.enabled) }
                                }
                            }.font(.caption)
                        }
                    }
                    if !record.fields.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(record.fields, id: \.self) { f in
                                GridRow {
                                    Text(f.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                    HStack(spacing: 6) {
                                        Text(f.value).textSelection(.enabled)
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(f.value, forType: .string)
                                        } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
                                        .help("Copy \(f.label)")
                                    }
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
        mediaURL = nil; image = nil; exif = []; coordinate = nil
        guard let file = model.mediaFile(for: record), let session = model.session else { return }
        let url = try? await Task.detached(priority: .userInitiated) { try session.materialise(file) }.value
        mediaURL = url
        // Map coordinate from the record's Location field.
        if let loc = record.fields.first(where: { $0.label == "Location" })?.value {
            let parts = loc.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { coordinate = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]) }
        }
        if let url, ["jpg","jpeg","png","heic","heif","gif","tiff"].contains(url.pathExtension.lowercased()) {
            image = await Task.detached { NSImage(contentsOf: url) }.value
            exif = await Task.detached { DataDetailView.readEXIF(url) }.value
        }
    }

    static func readEXIF(_ url: URL) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
        var out: [(String, String)] = []
        if let w = props[kCGImagePropertyPixelWidth], let h = props[kCGImagePropertyPixelHeight] {
            out.append(("Dimensions", "\(w) × \(h)"))
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let lens = exif[kCGImagePropertyExifLensModel] as? String { out.append(("Lens", lens)) }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { out.append(("ISO", "\(iso)")) }
            if let f = exif[kCGImagePropertyExifFNumber] as? Double { out.append(("Aperture", String(format: "f/%.1f", f))) }
            if let et = exif[kCGImagePropertyExifExposureTime] as? Double, et > 0 { out.append(("Shutter", et < 1 ? "1/\(Int((1/et).rounded()))s" : "\(et)s")) }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake] as? String, let modelName = tiff[kCGImagePropertyTIFFModel] as? String {
                out.append(("Camera", "\(make) \(modelName)"))
            }
        }
        return out
    }

    private func openInMaps(_ coords: String) {
        let q = coords.replacingOccurrences(of: " ", with: "")
        if let url = URL(string: "https://maps.apple.com/?ll=\(q)") { NSWorkspace.shared.open(url) }
    }
}
