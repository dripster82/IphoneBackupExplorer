import SwiftUI
import AppKit
import QuickLookThumbnailing

struct MediaGridView: View {
    @EnvironmentObject var model: AppModel
    let files: [BackupFile]
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(files) { file in
                    MediaCell(file: file, isSelected: model.selection.contains(file.id))
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                if model.selection.contains(file.id) { model.selection.remove(file.id) } else { model.selection.insert(file.id) }
                            } else if NSEvent.modifierFlags.contains(.shift), let anchor = model.selection.first,
                                      let a = files.firstIndex(where: { $0.id == anchor }), let b = files.firstIndex(of: file) {
                                model.selection.formUnion(files[min(a, b)...max(a, b)].map(\.id))
                            } else {
                                model.selection = [file.id]
                            }
                        }
                        .contextMenu {
                            Button("Export…") {
                                let ids = model.selection.contains(file.id) ? model.selection : [file.id]
                                model.export(files: model.allFiles.filter { ids.contains($0.id) })
                            }
                        }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct MediaCell: View {
    @EnvironmentObject var model: AppModel
    let file: BackupFile
    let isSelected: Bool
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity).clipped()
                } else {
                    Image(systemName: failed ? "exclamationmark.triangle" : file.category.systemImage)
                        .font(.largeTitle).foregroundStyle(.tertiary)
                }
                if file.category == .videos {
                    VStack { Spacer(); HStack { Image(systemName: "play.circle.fill").foregroundStyle(.white).shadow(radius: 2); Spacer() }.padding(6) }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3))
            Text(file.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(AppModel.formatSize(file.size)).font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: file.id) { await load() }
    }

    private func load() async {
        image = nil; failed = false
        guard let session = model.session else { return }
        if let cached = ThumbnailCache.shared.image(for: file.id) { image = cached; return }
        let result = await ThumbnailCache.shared.generate(for: file, session: session)
        if let result { image = result } else { failed = true }
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 2000 }

    func image(for id: String) -> NSImage? { cache.object(forKey: id as NSString) }

    func generate(for file: BackupFile, session: BackupSession) async -> NSImage? {
        guard let url = try? await Task.detached(priority: .utility, operation: { try session.materialise(file) }).value else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 200, height: 200), scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let img = rep.nsImage
        cache.setObject(img, forKey: file.id as NSString)
        return img
    }
}
