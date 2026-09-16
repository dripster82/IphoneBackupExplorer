import SwiftUI
import AppKit
import AVKit
import Quartz

struct PreviewPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let file = model.singleSelectedFile, let session = model.session {
                FilePreview(file: file, session: session)
            } else if model.selection.count > 1 {
                let files = model.selectedFiles
                ContentUnavailableView {
                    Label("\(files.count) files selected", systemImage: "doc.on.doc")
                } description: {
                    Text(AppModel.formatSize(files.reduce(0) { $0 + $1.size }))
                } actions: {
                    Button("Export Selected…") { model.exportSelected() }
                }
            } else if let device = model.selectedDevice, model.session != nil {
                DeviceInfoView(device: device)
            } else {
                ContentUnavailableView("No Selection", systemImage: "eye.slash", description: Text("Select a file to preview it."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeviceInfoView: View {
    let device: BackupDevice
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: device.productType.hasPrefix("iPad") ? "ipad" : "iphone").font(.system(size: 40)).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(device.title).font(.title2).bold()
                        Text(device.subtitle).foregroundStyle(.secondary)
                    }
                }
                InfoGrid(rows: [
                    ("Model", BackupDevice.friendlyModel(device.productType) + (device.productType.isEmpty ? "" : " (\(device.productType))")),
                    ("iOS", device.productVersion + (device.buildVersion.isEmpty ? "" : " (\(device.buildVersion))")),
                    ("Serial", device.serialNumber),
                    ("Phone", device.phoneNumber),
                    ("Last backup", device.lastBackupDate.map { $0.formatted(date: .long, time: .shortened) } ?? ""),
                    ("Encrypted", device.isEncrypted ? "Yes" : "No"),
                    ("Backup version", device.backupVersion),
                    ("UDID", device.id),
                    ("Location", device.url.path),
                ])
                if !device.installedApps.isEmpty {
                    Text("Installed apps (\(device.installedApps.count))").font(.headline).padding(.top, 6)
                    ForEach(device.installedApps, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InfoGrid: View {
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows.filter { !$0.1.isEmpty }, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(row.1).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }
}

private struct FilePreview: View {
    @EnvironmentObject var model: AppModel
    let file: BackupFile
    let session: BackupSession
    @State private var url: URL?
    @State private var text: String?
    @State private var plistNodes: [PlistNode]?
    @State private var showRawPlist = false
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if loading {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView("Can't Preview", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let plistNodes, !showRawPlist {
                    PlistTreeView(nodes: plistNodes)
                } else if let text {
                    ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                } else if let url {
                    switch file.category {
                    case .photos: ImagePreview(url: url)
                    case .videos, .audio: AVPlayerViewRepresentable(url: url)
                    default: QuickLookView(url: url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.fileName).font(.headline).textSelection(.enabled)
                    InfoGrid(rows: [
                        ("Domain", file.domainDisplayName),
                        ("Path", file.relativePath),
                        ("Size", AppModel.formatSize(file.size)),
                        ("Modified", file.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""),
                        ("Type", file.utType?.localizedDescription ?? file.fileExtension.uppercased()),
                        ("Protection", file.encryptionKey == nil ? "" : "Class \(file.protectionClass)"),
                        ("File ID", file.id),
                    ])
                    HStack {
                        Button("Export…") { model.export(files: [file]) }
                        if plistNodes != nil {
                            Button(showRawPlist ? "Tree View" : "Raw Text") { showRawPlist.toggle() }
                        }
                        if let url {
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Quick Look") { QuickLookPanelController.shared.show(url) }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 230)
        }
        .task(id: file.id) { await load() }
    }

    private func load() async {
        url = nil; text = nil; plistNodes = nil; showRawPlist = false; error = nil; loading = true
        defer { loading = false }
        guard file.isRegularFile else { error = "Directories have no content."; return }
        let f = file, s = session
        do {
            let ext = f.fileExtension
            if ["plist", "json", "txt", "xml", "html", "csv", "md", "vcf", "ics", "strings", "log"].contains(ext), f.size < 5_000_000 {
                let data = try await Task.detached { try s.contents(of: f) }.value
                if ext == "plist" || data.starts(with: Data("bplist".utf8)),
                   let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                    plistNodes = PlistNode.root(obj)
                }
                text = PreviewFormatter.text(from: data, extension: ext)
                return
            }
            if ext.isEmpty, f.size < 500_000, let data = try? await Task.detached(operation: { try s.contents(of: f) }).value,
               data.starts(with: Data("bplist".utf8)) {
                if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) { plistNodes = PlistNode.root(obj) }
                text = PreviewFormatter.text(from: data, extension: "plist"); return
            }
            url = try await Task.detached(priority: .userInitiated) { try s.materialise(f) }.value
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum PreviewFormatter {
    static func text(from data: Data, extension ext: String) -> String {
        if ext == "plist" || data.starts(with: Data("bplist".utf8)) {
            if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0),
               let s = String(data: xml, encoding: .utf8) { return s }
        }
        if ext == "json", let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: pretty, encoding: .utf8) { return s }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

private struct ImagePreview: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let u = url
            image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: u) }.value
        }
    }
}

/// AppKit AVPlayerView wrapper. Avoids SwiftUI's VideoPlayer (which can crash instantiating
/// _AVKit_SwiftUI generic metadata on some macOS builds).
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        let current = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        if current != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != (url as NSURL) { view.previewItem = url as NSURL }
    }
}

final class QuickLookPanelController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPanelController()
    private var url: URL?
    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}
