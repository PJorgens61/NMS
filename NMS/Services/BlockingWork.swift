import Foundation

/// Runs a genuinely *blocking* call — a subprocess waiting on
/// `waitUntilExit()`, a POSIX resolver call — from an `async` context
/// without holding a thread while it waits.
///
/// **Why this isn't just `Task { }`.** Swift's concurrency runtime has its
/// own cooperative thread pool, sized to roughly one thread per core, and
/// unlike libdispatch's pool it deliberately does *not* grow under load —
/// the whole design assumes tasks suspend rather than block. A `Task` that
/// calls `waitUntilExit()` holds one of those few threads hostage for the
/// full duration, and enough of them at once wedges the concurrency
/// runtime process-wide, not merely this app's own work. Moving blocking
/// calls into `Task`s without this would be a downgrade from the
/// `DispatchQueue` code it replaced, not an improvement.
///
/// So the blocking half runs on `DispatchQueue.global(qos: .utility)`,
/// which does grow, while the caller merely suspends — holding no thread
/// at all. The point isn't "block a dispatch thread instead of a
/// cooperative one"; it's that *waiting* costs no thread anywhere, and
/// only the work that truly must block occupies the pool built to absorb
/// it.
///
/// This is the same shape `LANDiscoveryViewModel.performScan` already
/// wrote out inline before there were three callers wanting it.
nonisolated enum BlockingWork {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}
