import SwiftUI
import AppKit
import MapKit
import ImageIO
import QuickLookThumbnailing

struct PhotosGalleryView: View {
    @EnvironmentObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: 8)]

    var body: some View {
        Group {
            if model.isLoadingData && model.records.isEmpty {
                ProgressView("Reading Photos…")
            } else if let err = model.dataError {
                ContentUnavailableView("Can't Read Photos", systemImage: "photo.badge.exclamationmark", description: Text(err))
            } else if model.records.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.stack", description: Text("This backup has no photo library metadata."))
            } else {
                let photos = model.filteredPhotos
                let groups = groupByDay(photos)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.0) { day, items in
                            Section {
                                LazyVGrid(columns: columns, spacing: 8) {
                                    ForEach(items) { rec in
                                        PhotoCell(record: rec, isSelected: model.photoSelection.contains(rec.id))
                                            .onTapGesture { select(rec, in: photos) }
                                    }
                                }
                            } header: {
                                Text(day).font(.headline).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("Photos")
        .navigationSubtitle(subtitle)
        .searchable(text: $model.dataSearch, placement: .toolbar, prompt: "Search photos")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Toggle("Favorites only", isOn: $model.photoFavoritesOnly)
                    Toggle("With location", isOn: $model.photoGPSOnly)
                    if !model.photoAlbums.isEmpty {
                        Divider()
                        Picker("Album", selection: $model.photoAlbumFilter) {
                            Text("All Albums").tag(String?.none)
                            ForEach(model.photoAlbums, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                Button { exportSelectedOrAll() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export selected photos (or all shown) into dated folders")
            }
        }
    }

    private var subtitle: String {
        let n = model.filteredPhotos.count
        let sel = model.photoSelection.count
        return sel > 0 ? "\(sel) selected of \(n)" : "\(n) items"
    }

    private func exportSelectedOrAll() {
        let photos = model.filteredPhotos
        let chosen = model.photoSelection.isEmpty ? photos : photos.filter { model.photoSelection.contains($0.id) }
        model.exportPhotos(chosen)
    }

    private func select(_ rec: DataRecord, in photos: [DataRecord]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.photoSelection.contains(rec.id) { model.photoSelection.remove(rec.id) } else { model.photoSelection.insert(rec.id) }
        } else if flags.contains(.shift), let anchor = model.selectedRecordID,
                  let a = photos.firstIndex(where: { $0.id == anchor }), let b = photos.firstIndex(of: rec) {
            model.photoSelection.formUnion(photos[min(a,b)...max(a,b)].map(\.id))
        } else {
            model.photoSelection = [rec.id]
        }
        model.selectedRecordID = rec.id
    }

    private func groupByDay(_ recs: [DataRecord]) -> [(String, [DataRecord])] {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none
        var order: [String] = []; var map: [String: [DataRecord]] = [:]
        for r in recs {
            let key = r.date.map { f.string(from: $0) } ?? "Undated"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(r)
        }
        return order.map { ($0, map[$0]!) }
    }
}

private struct PhotoCell: View {
    @EnvironmentObject var model: AppModel
    let record: DataRecord
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: isVideo ? "film" : "photo").font(.title2).foregroundStyle(.tertiary)
            }
            if record.fields.contains(where: { $0.label == "Favorite" }) {
                Image(systemName: "heart.fill").foregroundStyle(.pink).padding(4).font(.caption)
            }
            if isVideo {
                VStack { Spacer(); HStack { Image(systemName: "play.circle.fill").foregroundStyle(.white).shadow(radius: 2); Spacer() } }.padding(4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3))
        .task(id: record.id) { await load() }
    }

    private var isVideo: Bool {
        ["mov","mp4","m4v"].contains((record.mediaPathSuffix as NSString?)?.pathExtension.lowercased() ?? "")
    }

    private func load() async {
        if let c = ThumbnailCache.shared.image(for: record.id) { image = c; return }
        guard let session = model.session, let file = model.mediaFile(for: record) else { return }
        image = await ThumbnailCache.shared.generate(for: file, session: session)
    }
}
