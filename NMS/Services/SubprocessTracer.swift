import Foundation

/// Debug-only trace of every external command this app runs — `ping`, `arp`,
/// `traceroute`, `snmpget` — written into the same ordered stream as
/// `UIStateLogger` so subprocess activity and UI state can be read together.
///
/// This exists because the state log has a specific blind spot: it records
/// what reached the UI, so a subprocess that *never returns* produces no
/// output at all, and silence is indistinguishable from idle. That is
/// exactly what a hung `arp -a` looked like — a beachballed menu bar with a
/// four-minute-old child process, diagnosed only by attaching `sample` to
/// get a stack trace. A second case looked like an app bug and wasn't: an
/// SNMP sweep that found only the gateway, because macOS's Local Network
/// privacy was denying every other address. Both are one line each here.
///
/// **Two-phase on purpose.** Logging only on completion would produce
/// nothing whatsoever for a hung process — the precise failure this is for.
/// A `start` with no matching `end` *is* the signal. Read it that way:
/// unmatched `proc.start` entries are the interesting ones.
///
/// Compiled out entirely in Release, matching `UIStateLogger`: every method
/// body is `#if DEBUG`, so a shipping build carries inlinable no-ops and
/// never records which addresses were probed.
enum SubprocessTracer {
    /// Handed back by `begin` and passed to `end`. Carries an id because
    /// invocations overlap heavily — an SNMP sweep runs up to 32 `snmpget`s
    /// at once and connectivity checks fan out across every target — so
    /// start and end lines interleave and can only be paired by id.
    struct Invocation {
        let id: Int
        let command: String
        let startedAt: Date
    }

    /// Logs the start of a subprocess and returns a token to close it with.
    /// Call immediately before `process.run()`.
    static func begin(_ path: String, _ arguments: [String]) -> Invocation {
        #if DEBUG
        let id = nextID()
        let command = Self.describe(path, arguments)
        UIStateLogger.record("proc.start", "#\(id) \(command)")
        return Invocation(id: id, command: command, startedAt: Date())
        #else
        return Invocation(id: 0, command: "", startedAt: Date())
        #endif
    }

    /// Logs completion with elapsed time and outcome. `exitCode` is `nil`
    /// when the process failed to launch at all, which is a genuinely
    /// different failure from a non-zero exit and worth distinguishing —
    /// `snmpget` refusing to start is not the same as `snmpget` running and
    /// reporting no route to host.
    static func end(_ invocation: Invocation, exitCode: Int32?, byteCount: Int) {
        #if DEBUG
        let ms = Date().timeIntervalSince(invocation.startedAt) * 1000
        let outcome = exitCode.map { $0 == 0 ? "ok" : "exit \($0)" } ?? "launch failed"
        UIStateLogger.record(
            "proc.end",
            String(format: "#%d %@ — %@ in %.0fms, %d bytes",
                   invocation.id, invocation.command, outcome, ms, byteCount)
        )
        #endif
    }

    #if DEBUG
    /// Independent of `UIStateLogger`'s line sequence — this one pairs a
    /// start with its end, and stays readable as a small number even after
    /// the line counter has run far ahead.
    private nonisolated(unsafe) static var counter = 0
    private static let counterLock = NSLock()

    private static func nextID() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        counter += 1
        return counter
    }

    /// Last path component only (`ping`, not `/sbin/ping`) — the full path
    /// is fixed per service and known, so repeating it on every line would
    /// cost width without adding information. Arguments are kept in full:
    /// which community string, timeout, or target was used is frequently
    /// the thing in question.
    private static func describe(_ path: String, _ arguments: [String]) -> String {
        let name = (path as NSString).lastPathComponent
        return arguments.isEmpty ? name : "\(name) \(arguments.joined(separator: " "))"
    }
    #endif
}
