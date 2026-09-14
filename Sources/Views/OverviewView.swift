import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    private struct Cat: Identifiable { let id: String; let category: FileCategory; let count: Int; let size: Int64 }

    private var categoryStats: [Cat] {
        var counts: [FileCategory: (Int, Int64)] = [:]
        for f in model.allFiles where f.isRegularFile {
            let e = counts[f.category] ?? (0, 0)
            counts[f.category] = (e.0 + 1, e.1 + f.size)
        }
        return counts.map { Cat(id: $0.key.rawValue, category: $0.key, count: $0.value.0, size: $0.value.1) }
            .filter { $0.category != .all && $0.category != .media }
            .sorted { $0.size > $1.size }
    }
    private var totalSize: Int64 { model.allFiles.reduce(0) { $0 + ($1.isRegularFile ? $1.size : 0) } }
    private var fileCount: Int { model.allFiles.filter(\.isRegularFile).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let d = model.selectedDevice {
                    HStack(spacing: 12) {
                        Image(systemName: d.productType.hasPrefix("iPad") ? "ipad" : "iphone").font(.system(size: 40)).foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(d.title).font(.title).bold()
                            Text(d.subtitle).foregroundStyle(.secondary)
                            if let date = d.lastBackupDate {
                                Text("Last backup \(date.formatted(date: .long, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // Stat cards
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    stat("Files", "\(fileCount)", "doc.on.doc")
                    stat("Total Size", AppModel.formatSize(totalSize), "internaldrive")
                    stat("Photos", "\(count(.photos))", "photo")
                    stat("Videos", "\(count(.videos))", "film")
                    if let d = model.selectedDevice, !d.installedApps.isEmpty { stat("Apps", "\(d.installedApps.count)", "app") }
                }

                // What's inside — clickable
                Text("What's inside").font(.headline)
                FlowChips(items: availableChips)

                // Storage by category
                Text("Storage by category").font(.headline)
                VStack(spacing: 8) {
                    ForEach(categoryStats) { c in
                        HStack {
                            Label(c.category.rawValue, systemImage: c.category.systemImage).frame(width: 150, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                                    RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.7))
                                        .frame(width: max(4, geo.size.width * barFraction(c.size)))
                                }
                            }
                            .frame(height: 16)
                            Text(AppModel.formatSize(c.size)).font(.caption).monospacedDigit().frame(width: 80, alignment: .trailing)
                            Text("\(c.count)").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        }
                    }
                }

                // Top domains
                Text("Largest domains").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.domainSummaries.sorted { $0.totalSize > $1.totalSize }.prefix(8)) { s in
                        HStack {
                            Label(s.displayName, systemImage: DomainInfo.systemImage(for: s.domain)).lineLimit(1)
                            Spacer()
                            Text("\(s.fileCount) files").font(.caption).foregroundStyle(.secondary)
                            Text(AppModel.formatSize(s.totalSize)).font(.caption).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private func count(_ c: FileCategory) -> Int { model.allFiles.filter { $0.isRegularFile && $0.category == c }.count }
    private func barFraction(_ size: Int64) -> Double {
        let maxSize = categoryStats.map(\.size).max() ?? 1
        return maxSize > 0 ? Double(size) / Double(maxSize) : 0
    }

    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold().monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private struct Chip: Identifiable { let id = UUID(); let title: String; let icon: String; let action: () -> Void }
    private var availableChips: [Chip] {
        var chips: [Chip] = []
        if model.contactsFile != nil { chips.append(Chip(title: "Contacts", icon: "person.crop.circle") { model.showContacts() }) }
        if model.messagesFile != nil { chips.append(Chip(title: "Messages", icon: "message") { model.showMessages() }) }
        if model.whatsappFile != nil { chips.append(Chip(title: "WhatsApp", icon: "phone.bubble") { model.showWhatsApp() }) }
        for k in model.availableDataKinds { chips.append(Chip(title: k.title, icon: k.icon) { model.showData(k) }) }
        return chips
    }

    private struct FlowChips: View {
        let items: [Chip]
        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(items) { chip in
                    Button(action: chip.action) {
                        Label(chip.title, systemImage: chip.icon).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct OverviewDetail: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let d = model.selectedDevice, !d.installedApps.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Installed apps (\(d.installedApps.count))").font(.headline)
                    ForEach(d.installedApps, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Overview", systemImage: "chart.bar", description: Text("A summary of what's inside this backup."))
        }
    }
}
