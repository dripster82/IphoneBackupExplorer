import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.isLoadingFiles {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.loadedCount == 0 ? "Opening backup…" : "Reading manifest… \(model.loadedCount) files")
                        .foregroundStyle(.secondary)
                }
            } else if model.session == nil {
                ContentUnavailableView("No Backup Open", systemImage: "externaldrive.badge.icloud",
                                       description: Text("Select a backup in the sidebar, or open a backup folder with ⌘O."))
            } else {
                VStack(spacing: 0) {
                    CategoryBar()
                    Divider()
                    if model.viewMode == .grid && model.selectedCategory.isMedia {
                        MediaGridView(files: model.filteredFiles)
                    } else {
                        FileTableView(files: model.filteredFiles)
                    }
                    Divider()
                    StatusBar()
                }
            }
        }
        .navigationTitle(model.selectedDevice?.title ?? "iPhone Backup Explorer")
        .navigationSubtitle(model.selectedDomain.map { DomainInfo.displayName(for: $0) } ?? "")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search file names and paths")
        .toolbar {
            ToolbarItemGroup {
                if model.selectedCategory.isMedia {
                    Picker("View", selection: $model.viewMode) {
                        Image(systemName: "list.bullet").tag(AppModel.ViewMode.list)
                        Image(systemName: "square.grid.2x2").tag(AppModel.ViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .help("List or thumbnail grid")
                }
                Toggle(isOn: $model.showDirectories) { Image(systemName: "folder.badge.gearshape") }
                    .help("Show directory entries")
                Button { model.exportSelected() } label: { Label("Export Selected", systemImage: "square.and.arrow.up") }
                    .disabled(model.selection.isEmpty)
                    .help("Export the selected files (⌘E)")
                Button { model.exportAllVisible() } label: { Label("Export All in View", systemImage: "square.and.arrow.up.on.square") }
                    .disabled(model.session == nil)
                    .help("Export every file currently listed (⇧⌘E)")
            }
        }
    }
}

private struct CategoryBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let counts = model.categoryCounts
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FileCategory.allCases) { category in
                    let count = counts[category] ?? 0
                    Button {
                        model.selectedCategory = category
                        model.selection = []
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: category.systemImage)
                            Text(category.rawValue)
                            Text("\(count)").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(model.selectedCategory == category ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0 && category != .all)
                    .opacity(count == 0 && category != .all ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

private struct FileTableView: View {
    @EnvironmentObject var model: AppModel
    let files: [BackupFile]

    var body: some View {
        Table(files, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.fileName) { file in
                HStack(spacing: 6) {
                    Image(systemName: file.isDirectory ? "folder" : file.category.systemImage)
                        .foregroundStyle(.secondary)
                    Text(file.fileName.isEmpty ? "(root)" : file.fileName).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Path", value: \.relativePath) { file in
                Text((file.relativePath as NSString).deletingLastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .width(min: 120, ideal: 240)
            TableColumn("Domain", value: \.domain) { file in
                Text(file.domainDisplayName).lineLimit(1)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Size", value: \.size) { file in
                Text(file.isRegularFile ? AppModel.formatSize(file.size) : "—")
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)
            TableColumn("Modified", value: \.sortableModified) { file in
                if let d = file.modified {
                    Text(d, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                } else { Text("—") }
            }
            .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Export…") {
                let target = ids.isEmpty ? [] : model.allFiles.filter { ids.contains($0.id) }
                model.export(files: target)
            }
        } primaryAction: { ids in
            model.export(files: model.allFiles.filter { ids.contains($0.id) })
        }
    }
}

extension BackupFile {
    var sortableModified: Date { modified ?? .distantPast }
}

private struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let files = model.filteredFiles
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let selected = model.selectedFiles
        HStack {
            Text("\(files.count) items · \(AppModel.formatSize(total))")
            Spacer()
            if !selected.isEmpty {
                Text("\(selected.count) selected · \(AppModel.formatSize(selected.reduce(0) { $0 + $1.size }))")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}
