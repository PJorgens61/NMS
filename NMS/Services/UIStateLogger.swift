import Foundation

/// Types whose default `String(describing:)` output is useless in the UI
/// state log and need a hand-written one instead. In practice this means
/// SwiftData `@Model` classes: verified directly that a class without a
/// custom description renders as bare `NMS.AppEventRecord` (and an array
/// of them as `[NMS.AppEventRecord, NMS.AppEventRecord]`), carrying zero
/// information, while structs render their full memberwise contents.
/// Structs therefore need no conformance — this exists only to rescue the
/// class-backed cases.
protocol UIStateLoggable {
    var uiStateDescription: String { get }
}

/// Debug-only, append-only record of every value pushed into the UI, so
/// "did this change what's actually displayed?" can be answered by reading
/// a file instead of by catching the popover open at exactly the right
/// moment. `MenuBarExtra(.window)` dismisses on *any* focus loss, which
/// makes screenshot-based verification a timing race; this doesn't race,
/// and unlike a screenshot it captures a *sequence* over time.
///
/// Deliberately separate from `AppEventRecord`, which stays as narrow as
/// its own doc comment insists ("something worth noticing happened", not a
/// catch-all debug log). This is the opposite in spirit: every write,
/// curated for nobody.
///
/// Not `os_log`/unified logging, which would otherwise be the obvious
/// choice — the log store turns out to be unreadable from the sandboxed
/// environment this exists to be read from (`log show` fails with
/// "Could not open local log store: Operation not permitted"), making it a
/// non-option for this one purpose. See `DESIGN-NOTES.md`.
///
/// Compiled out entirely in Release: every method body here is `#if DEBUG`,
/// so shipping builds carry inlinable no-ops, never a log file. That also
/// bounds the privacy question — these lines contain SSIDs, the public IP
/// and SNMP descriptors, and `~/Library/Logs/` is collected by sysdiagnose,
/// so it matters that a release build *cannot* be made to write them.
@MainActor
enum UIStateLogger {
    /// `seq | timestamp | ViewModel.property | value`, one line per write.
    ///
    /// Call from a `didSet` on an instrumented `@Published` property. Note
    /// this logs *writes*, not *changes*: `didSet` fires on identical
    /// reassignment too (verified), which is deliberate — it distinguishes
    /// "the code never ran" from "the code ran and produced the same
    /// value," usually the more useful distinction.
    static func log(_ property: String, _ value: Any) {
        #if DEBUG
        // Rendered *here*, on the main thread, for two reasons. `Any` isn't
        // `Sendable`, so handing the raw value to another queue is a
        // concurrency hazard; and more concretely, `AppEventRecord` is a
        // SwiftData `@Model` bound to the main context, so describing one
        // off the main thread would be genuinely unsafe. Only `Sendable`
        // values (Int, Date, String) cross the queue boundary.
        record(property, describe(value))
        #endif
    }

    /// Writes a pre-rendered line into the same ordered stream as `log`,
    /// callable from *any* thread — which `log` is not, being `@MainActor`.
    /// Exists for `SubprocessTracer`, whose events originate on whatever
    /// background queue the shell-out happens to be running on.
    ///
    /// Sharing one file rather than giving subprocesses their own is
    /// deliberate: the sequence that matters is the interleaved one. "`arp`
    /// started, and 228 seconds later `currentInterface` finally wrote" is
    /// only visible when both appear in a single ordered stream.
    nonisolated static func record(_ label: String, _ message: String) {
        #if DEBUG
        // Sequence and timestamp are both taken at the call site, never on
        // the writer thread — a timestamp taken at drain time would measure
        // scheduling latency rather than when the event happened, and a
        // counter incremented there could not preserve ordering at all.
        //
        // The lock deliberately spans the enqueue as well, not just the
        // counter increment. Taking the number and *then* enqueueing lets
        // two concurrent callers hand work to the writer thread in the
        // opposite order from the numbers they were given — observed
        // directly with two pings finishing in the same millisecond, which
        // wrote seq 14 to the file ahead of seq 13. Enqueueing under the
        // lock makes file order, sequence order and timestamp order all
        // agree. The lock is held for microseconds around appending to an
        // array, so even a 32-way SNMP sweep contends for nothing that
        // matters next to forking a process.
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        sequence += 1
        let seq = sequence
        let at = Date()
        writerThread.enqueue { write(seq: seq, at: at, property: label, value: message) }
        #endif
    }

    #if DEBUG
    /// Lock-protected rather than `@MainActor`-confined, because subprocess
    /// events arrive concurrently (a sweep runs up to 32 `snmpget`s at once,
    /// and ping fans out across every target). The lock keeps the counter
    /// monotonic so a gap still reliably means a dropped line.
    ///
    /// Both the counter and the enqueue happen under this lock (see
    /// `record`), so sequence order, timestamp order and the order lines
    /// actually land in the file all agree even with concurrent producers.
    private nonisolated(unsafe) static var sequence = 0
    private nonisolated static let sequenceLock = NSLock()

    /// Serial, and deliberately a dedicated `Thread` rather than a
    /// `DispatchQueue` — even a private serial one. A `DispatchQueue`
    /// (unless targeted elsewhere) runs its work on a thread borrowed from
    /// the process-wide QoS thread pool, the same bounded pool that
    /// `DispatchQueue.global(qos: .utility)` hands out everywhere else in
    /// this app (ping/SNMP subprocesses, and — until this was diagnosed —
    /// `DNSResolutionService`/`ReverseDNSService`'s calls into
    /// `getaddrinfo`/`getnameinfo`, which have no cancellation and can run
    /// far past their own stated timeout). Enough of that pool blocked at
    /// once starves every queue drawing from it, including an unrelated
    /// private serial one. That's the best explanation found for a real
    /// 17+ minute gap in this file with no crash and nothing else wrong: a
    /// concurrency change to `ConnectivityViewModel` landed shortly before
    /// the gap started, adding more simultaneous blocking calls onto that
    /// pool per round. A dedicated thread owns its own pthread outright, so
    /// it keeps draining no matter how saturated the shared pool gets.
    private nonisolated static let writerThread: WriterThread = {
        let thread = WriterThread()
        thread.name = "Thistle.NMS.ui-state-log"
        thread.qualityOfService = .utility
        thread.start()
        return thread
    }()

    /// A run loop of one: waits for work, drains it, and — finding none —
    /// wakes on its own every `heartbeatInterval` to prove it's still
    /// alive. That last part is the whole point: a stalled `DispatchQueue`
    /// can't be asked "are you still draining?" after the fact, which is
    /// exactly how the 17-minute gap above was only found by comparing
    /// wall-clock timestamps days later. A heartbeat line makes a future
    /// stall visible immediately, in the file itself, from whatever *did*
    /// keep running.
    /// `@unchecked Sendable`: every mutable stored property (`pending`) is
    /// only ever touched while holding `condition`, so it's genuinely safe
    /// to share across threads — the compiler just can't see a lock as a
    /// proof of that. Same pattern as `BonjourDiscoveryService`'s
    /// `UnsafeBox`.
    private final class WriterThread: Thread, @unchecked Sendable {
        static let heartbeatInterval: TimeInterval = 20
        private let condition = NSCondition()
        private var pending: [() -> Void] = []

        func enqueue(_ work: @escaping () -> Void) {
            condition.lock()
            pending.append(work)
            condition.signal()
            condition.unlock()
        }

        override func main() {
            condition.lock()
            while true {
                while pending.isEmpty {
                    let signaled = condition.wait(until: Date().addingTimeInterval(Self.heartbeatInterval))
                    if !signaled && pending.isEmpty {
                        condition.unlock()
                        UIStateLogger.record("heartbeat", "writer thread alive")
                        condition.lock()
                    }
                }
                let work = pending.removeFirst()
                condition.unlock()
                work()
                condition.lock()
            }
        }
    }

    private nonisolated static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NMS", isDirectory: true)
        .appendingPathComponent("ui-state.log")

    /// These three are touched *only* from `writerThread`, which is what
    /// makes them safe without a lock — hence `nonisolated(unsafe)`, which
    /// states that invariant rather than hiding it. `ISO8601DateFormatter`
    /// in particular is not documented as thread-safe, so confining it to
    /// that one thread is load-bearing, not incidental.
    private nonisolated(unsafe) static var handle: FileHandle?
    private nonisolated(unsafe) static var didPrepare = false
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated static func write(seq: Int, at: Date, property: String, value: String) {
        prepare(at: at)
        guard let handle else { return }
        let line = "\(seq) | \(formatter.string(from: at)) | \(property) | \(value)\n"
        guard let data = line.data(using: .utf8) else { return }
        // `FileHandle.write` is unbuffered — it goes straight to the file
        // descriptor, so a line is readable by `cat`/`tail -f` from another
        // process the instant it's written. No flushing to get right, and
        // no risk of the interesting lines sitting in a buffer when the app
        // is killed.
        try? handle.write(contentsOf: data)
    }

    /// Truncates at first write rather than appending across launches: this
    /// is session-scoped debug tooling, not history, so it sidesteps
    /// unbounded growth by simply not persisting across restarts. Doing it
    /// lazily here (instead of from app startup) keeps the whole feature
    /// self-contained in this one file — nothing to remember to call.
    /// Stamped with the *first write's* timestamp rather than `Date()` at
    /// prepare time. Those differ: a real line's timestamp is captured at
    /// its call site, while this runs later, on the writer thread — using
    /// the current time here produced a header stamped after the line
    /// below it, so the file opened with the sequence already reading
    /// backwards. For a log whose entire purpose is a faithful ordering,
    /// that's worth the extra parameter.
    private nonisolated static func prepare(at firstWrite: Date) {
        guard !didPrepare else { return }
        didPrepare = true
        let manager = FileManager.default
        try? manager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        manager.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        // Stamps which run this file covers, so there's never doubt about
        // whether truncation actually happened.
        let header = "0 | \(formatter.string(from: firstWrite)) | UIStateLogger | session started\n"
        if let data = header.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
    }

    /// Renders a value as exactly one line. The newline escaping is not
    /// defensive padding: the line-oriented format is the entire basis for
    /// grepping this file and for reading the sequence, and one stray
    /// newline silently splits a single write into two apparent ones.
    /// `lastError` is assigned straight from `error.localizedDescription`,
    /// and SNMP `sysDescr` is multi-line on plenty of network gear, so
    /// real values here genuinely can contain them.
    private static func describe(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        // Unwrapped so a present value reads as itself and an absent one as
        // a bare `nil`, rather than everything being wrapped in `Optional(…)`.
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first?.value else { return "nil" }
            return describe(inner)
        }
        if let loggable = value as? UIStateLoggable {
            return loggable.uiStateDescription
        }
        // Mapped element-wise rather than described whole, so that a
        // `UIStateLoggable` element type is honored inside a collection too
        // — the array case is exactly where the useless class rendering
        // would otherwise show up.
        if let array = value as? [Any] {
            return "[" + array.map(describe).joined(separator: ", ") + "]"
        }
        return String(describing: value)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
    #endif
}
