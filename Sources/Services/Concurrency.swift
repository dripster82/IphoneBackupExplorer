import Foundation

/// A thread-safe cancellation flag that can be read from a background thread without
/// hopping to the main actor (which would serialize a tight loop against the UI).
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// Rate-limits how often a progress closure marshals to the main actor. A long export
/// produces tens of thousands of updates; pushing every one floods the main thread and
/// actually slows the copy loop down. This lets through at most one update per `interval`,
/// plus any update flagged `force` (e.g. the final one).
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval
    init(interval: TimeInterval = 0.1) { self.interval = interval }
    func shouldEmit(force: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if force || now.timeIntervalSince(last) >= interval { last = now; return true }
        return false
    }
}
