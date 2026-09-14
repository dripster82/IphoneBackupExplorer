import Foundation

struct CopyProgress {
    var deviceTitle: String = ""
    var completed: Int = 0
    var total: Int = 0
    var copiedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var currentFile: String = ""
    var error: Error?
    var fraction: Double { totalBytes == 0 ? 0 : Double(copiedBytes) / Double(totalBytes) }
}

/// Copies an entire backup folder verbatim (raw blobs, plists, Manifest.db) to a new location.
/// Never decrypts, so it needs no password and produces an identical, still-usable backup.
enum BackupCopier {
    static func copy(from source: URL, to destination: URL,
                     isCancelled: @escaping () -> Bool,
                     progress: @escaping (CopyProgress) -> Void) -> CopyProgress {
        var state = CopyProgress()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]

        // First pass: tally files and bytes so the progress bar is meaningful.
        var files: [URL] = []
        if let en = fm.enumerator(at: source, includingPropertiesForKeys: keys) {
            for case let url as URL in en {
                if isCancelled() { state.error = CocoaError(.userCancelled); return state }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true {
                    files.append(url)
                    state.totalBytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        state.total = files.count
        progress(state)

        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in files {
                if isCancelled() { state.error = CocoaError(.userCancelled); return state }
                let relative = file.path.replacingOccurrences(of: source.path + "/", with: "")
                let target = destination.appendingPathComponent(relative)
                state.currentFile = file.lastPathComponent
                progress(state)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: file, to: target)
                state.completed += 1
                state.copiedBytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                progress(state)
            }
        } catch {
            state.error = error
        }
        return state
    }
}
