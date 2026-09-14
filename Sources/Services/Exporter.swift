import Foundation

struct ExportOptions {
    enum Layout { case preserveStructure, flat }
    var layout: Layout = .preserveStructure
}

struct ExportProgress {
    var completed: Int = 0
    var total: Int = 0
    var currentFile: String = ""
    var failures: [(BackupFile, Error)] = []
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

enum Exporter {
    /// Exports the given files into `destination`.
    static func export(files: [BackupFile], from session: BackupSession, to destination: URL,
                       options: ExportOptions, isCancelled: @escaping () -> Bool,
                       progress: @escaping (ExportProgress) -> Void) -> ExportProgress {
        var state = ExportProgress(total: files.count)
        var usedFlatNames: Set<String> = []
        for file in files {
            if isCancelled() { break }
            guard file.isRegularFile else { state.completed += 1; continue }
            state.currentFile = file.fileName
            progress(state)

            let target: URL
            switch options.layout {
            case .preserveStructure:
                target = destination
                    .appendingPathComponent(sanitise(file.domainDisplayName), isDirectory: true)
                    .appendingPathComponent(file.relativePath)
            case .flat:
                var name = file.fileName.isEmpty ? file.id : file.fileName
                var n = 1
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                while usedFlatNames.contains(name.lowercased()) {
                    n += 1
                    name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                }
                usedFlatNames.insert(name.lowercased())
                target = destination.appendingPathComponent(name)
            }
            do { try session.extract(file, to: target) }
            catch { state.failures.append((file, error)) }
            state.completed += 1
            progress(state)
        }
        return state
    }

    private static func sanitise(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
