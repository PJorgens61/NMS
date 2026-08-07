import Foundation

/// Runs Apple's own `/usr/bin/networkQuality` — the same test behind
/// System Settings → Network Quality Test — for the one signal
/// `NetworkQualityService`'s Cloudflare-based throughput test deliberately
/// doesn't produce: **responsiveness under load** (RPM, round-trips-per-
/// minute while the link is saturated — a bufferbloat measurement). See
/// DESIGN-NOTES.md's "Network Quality" section: this was the half of that
/// design explicitly deferred at the time ("narrower scope: the Cloudflare
/// throughput path only, nothing from networkQuality"), built now as a
/// second, complementary source rather than a replacement — both feed the
/// same `NetworkQualityResult`/recent-runs list, distinguished by `source`.
struct AppleNetworkQualityService {
    private static let executablePath = "/usr/bin/networkQuality"

    /// An Apple-bundled tool, not a guaranteed-forever syscall — same
    /// caution already applied to `snmpget`/`dig`/`ipconfig` elsewhere in
    /// this app.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    enum QualityError: Error {
        case unavailable
        case processFailed(Int32)
        case unparseable
        /// Real JSON, decoded fine, but `responsiveness` itself wasn't
        /// there — found live (2026-08-06): `-M 5`'s 5s budget is usually
        /// enough for parallel mode to finish, but confirmed directly
        /// that it isn't always; two immediate reruns of the identical
        /// command both succeeded right after one that came back missing
        /// the field entirely. Distinct from `.unparseable` (genuinely
        /// broken/unexpected output) on purpose — this is valid output
        /// that simply didn't get far enough in time, same shape as
        /// `Measurement.downloadResponsivenessRPM`'s own doc comment
        /// already documents for the full (`-s`) test, just not
        /// previously extended to this quicker, parallel-mode path.
        case incomplete
    }

    struct Measurement {
        let downloadMbps: Double
        let uploadMbps: Double
        /// `nil` if `-M`'s runtime cap cut the test short before this
        /// direction's load-then-measure sequence finished — confirmed
        /// live, not theoretical: forcing an artificially tiny `-M`
        /// reproduced a real run whose JSON was missing
        /// `dl_responsiveness` entirely while every other field (both
        /// directions' throughput and byte counts, idle latency) came
        /// through intact. RPM is the field this can happen to because
        /// it's the last thing computed per direction, sequentially —
        /// throughput/bytes/idle-latency are all established earlier in
        /// the run and survived the same forced cutoff. See `RawResult`.
        let downloadResponsivenessRPM: Int?
        let uploadResponsivenessRPM: Int?
        let baseRTTMs: Double
        /// Real, exact byte counts — not derived from throughput × time.
        /// See `RawResult`'s doc comment: this is genuinely large, GB-
        /// scale per run, not the ~50MB the Cloudflare-endpoint path
        /// costs — worth surfacing directly rather than only gesturing
        /// at "uses your data plan."
        let downloadBytesTransferred: Int
        let uploadBytesTransferred: Int
        /// The tool's own full human-readable report (`-v`), for whoever
        /// wants more than this app's own summary shows — every idle-
        /// latency/responsiveness breakdown by transport layer (TCP/TLS/
        /// HTTP), protocol mix, ECN/L4S status, endpoint — none of which
        /// this app parses or interprets, just captured verbatim. Raised
        /// directly: experts want the full picture, not just NMS's own
        /// distillation of it. Displayed as-is, not parsed into
        /// structured fields — Apple's own prose wording could change
        /// between macOS versions, and nothing here needs to be
        /// programmatically correct, only readable by a human who already
        /// knows how to interpret it.
        let verboseOutput: String
    }

    /// The tool's own machine-readable schema (`man networkQuality`) —
    /// only the fields this app actually displays are declared;
    /// `Decodable` silently ignores everything else, which matters here
    /// specifically: a real run's `-c` output also includes several dozen
    /// raw per-request latency-sample arrays (`il_*`, `lud_*`) used
    /// internally to compute the summary fields below, none of it meant
    /// for display and not worth modeling.
    ///
    /// **Units, confirmed against the man page rather than assumed**:
    /// `dl_throughput`/`ul_throughput` are bits per second, not bytes —
    /// an 8x error was caught here before it shipped, by checking rather
    /// than guessing from a plausible-looking Mbps-sized number.
    /// `dl_responsiveness`/`ul_responsiveness` (RPM) are **only emitted
    /// in sequential mode** (`-s`); parallel mode (the default) returns a
    /// single combined `responsiveness` field instead, which this app
    /// doesn't request and doesn't parse. **Also optional for a second,
    /// confirmed-live reason**: a run cut short by `-M`'s timeout can
    /// omit one direction's RPM entirely while every other field still
    /// comes through — see `Measurement.downloadResponsivenessRPM`'s doc
    /// comment. Declaring these `Double?` (rather than required) is what
    /// lets `JSONDecoder` still succeed on that real, truncated shape
    /// instead of failing the whole decode and surfacing a generic
    /// "produced unreadable output" error for a run that actually
    /// produced a perfectly good throughput reading.
    ///
    /// **`dl_bytes_transferred`/`ul_bytes_transferred` are real, raised
    /// directly and confirmed live** (`networkQuality -c ...`, inspected
    /// the actual JSON output) — genuine byte counts, not derived from
    /// throughput × elapsed time. Absent from the man page's own
    /// "COMPUTER OUTPUT FIELD DESCRIPTION" list entirely (checked
    /// directly, not assumed missing), but present in every real run's
    /// output regardless. Confirmed magnitude live: 1-2GB per direction
    /// on this connection, not the double-digit MB a user might expect
    /// from "uses your data plan, ~30s" alone.
    private struct RawResult: Decodable {
        let dl_throughput: Double
        let ul_throughput: Double
        let dl_responsiveness: Double?
        let ul_responsiveness: Double?
        let base_rtt: Double
        let dl_bytes_transferred: Int
        let ul_bytes_transferred: Int
    }

    /// Parallel mode's own JSON shape — a single combined `responsiveness`
    /// field, not `dl_responsiveness`/`ul_responsiveness` split by
    /// direction (those are sequential-mode-only, confirmed against the
    /// man page). This is exactly what `measureQuick` requests: parallel
    /// mode is what makes a real, complete measurement possible in ~5s at
    /// all — confirmed live, a forced `-M 5` sequential run needs the
    /// full ~25-40s sequential load-then-measure sequence per direction
    /// and comes back with fields missing, while the same 5s budget in
    /// parallel mode produces a complete, valid result every field
    /// present.
    private struct RawQuickResult: Decodable {
        let responsiveness: Double?
    }

    /// Blocking — call off the main thread, same contract as
    /// `SNMPService.sweep`/`probe`.
    ///
    /// Always sequential (`-s`): RPM under load, split by direction, is
    /// the entire reason this service exists alongside the faster
    /// Cloudflare test — running in the (faster) default parallel mode
    /// would silently drop the one signal this was built for. Costs real
    /// time: ~25-30s observed here, versus roughly a second for a 50MB
    /// Cloudflare round trip on this same connection.
    ///
    /// `-M 45` mirrors the safety cap `NetworkQualityService` already
    /// uses for the same reason: a bad link must not leave the UI
    /// spinning indefinitely.
    ///
    /// `-I <interface>`, when known, binds the test to the interface NMS
    /// is actually tracking rather than whatever the OS's default route
    /// picks on a multi-homed Mac — the one gap `NetworkQualityService`
    /// itself couldn't close, since `URLSession` has no equivalent flag.
    ///
    /// **JSON goes to a temp file, not stdout — confirmed necessary, not
    /// a style choice.** `-v` (verbose human-readable text) and `-c`
    /// (JSON) both write to stdout by default, which would interleave
    /// two incompatible formats in one stream. Tested directly:
    /// `-c<path>` (attached, no space — the man page's own `-c
    /// [filename]` reads like a separate argument, but isn't; confirmed
    /// by testing both ways) cleanly separates them, verbose text on
    /// stdout and valid JSON in the file, with nothing lost from either.
    /// This is what lets this app keep parsing structured history
    /// exactly as before while also capturing the full verbose report —
    /// no tradeoff between the two turned out to be necessary.
    func measure(interfaceName: String?) -> Result<Measurement, QualityError> {
        guard Self.isAvailable else { return .failure(.unavailable) }

        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("networkQuality-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        var arguments = ["-v", "-c\(jsonURL.path)", "-s", "-M", "45"]
        if let interfaceName {
            arguments += ["-I", interfaceName]
        }

        switch runProcess(arguments: arguments) {
        case let .failure(error):
            return .failure(error)
        case let .success(stdoutData):
            guard
                let jsonData = try? Data(contentsOf: jsonURL),
                let raw = try? JSONDecoder().decode(RawResult.self, from: jsonData)
            else {
                return .failure(.unparseable)
            }
            let verboseOutput = String(data: stdoutData, encoding: .utf8) ?? ""
            return .success(Measurement(
                downloadMbps: raw.dl_throughput / 1_000_000,
                uploadMbps: raw.ul_throughput / 1_000_000,
                downloadResponsivenessRPM: raw.dl_responsiveness.map { Int($0.rounded()) },
                uploadResponsivenessRPM: raw.ul_responsiveness.map { Int($0.rounded()) },
                baseRTTMs: raw.base_rtt,
                downloadBytesTransferred: raw.dl_bytes_transferred,
                uploadBytesTransferred: raw.ul_bytes_transferred,
                verboseOutput: verboseOutput
            ))
        }
    }

    /// A ~5s popover-friendly check — raised directly, for a business
    /// user who wants a quick "is my connection OK for a call right now"
    /// read rather than the full sequential test's ~25-40s/GB-scale cost.
    /// **Deliberately parallel mode (no `-s`)**: confirmed live that this
    /// is what actually makes a real result possible in 5 seconds at all
    /// — sequential mode's per-direction load-then-measure sequence
    /// genuinely needs the ~25-40s `measure(interfaceName:)` gives it, and
    /// a 5s cap on that mode reliably comes back with fields missing (see
    /// `RawQuickResult`'s doc comment). Parallel mode's own combined RPM
    /// figure is exactly the "one number, one verdict" this needs, not a
    /// downgrade — it's what makes the whole feature possible within a
    /// budget short enough to actually be "quick."
    ///
    /// Still real cost, just not *zero* cost the way a ping is — plain
    /// `-M 5` still saturates the link at full throughput for those 5
    /// seconds (confirmed live: ~880MB on a fast connection). Not free,
    /// just short.
    func measureQuick(interfaceName: String?) -> Result<Int, QualityError> {
        guard Self.isAvailable else { return .failure(.unavailable) }

        var arguments = ["-c", "-M", "5"]
        if let interfaceName {
            arguments += ["-I", interfaceName]
        }

        switch runProcess(arguments: arguments) {
        case let .failure(error):
            return .failure(error)
        case let .success(data):
            guard let raw = try? JSONDecoder().decode(RawQuickResult.self, from: data) else {
                return .failure(.unparseable)
            }
            guard let responsiveness = raw.responsiveness else {
                return .failure(.incomplete)
            }
            return .success(Int(responsiveness.rounded()))
        }
    }

    /// Shared subprocess plumbing for both `measure(interfaceName:)` and
    /// `measureQuick(interfaceName:)` — runs `networkQuality`, returns raw
    /// stdout bytes on a clean exit. Neither caller's own JSON-decoding
    /// step lives here: `measure` reads its JSON from a temp file (stdout
    /// carries `-v` text instead, see that method's own doc comment),
    /// while `measureQuick` decodes stdout directly — different enough
    /// that folding decoding into this helper too would need a generic
    /// parameter for no real gain.
    private func runProcess(arguments: [String]) -> Result<Data, QualityError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let trace = SubprocessTracer.begin(process.executableURL!.path, process.arguments ?? [])
        do {
            try process.run()
        } catch {
            SubprocessTracer.end(trace, exitCode: nil, byteCount: 0)
            return .failure(.processFailed(-1))
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: stdoutData.count)

        guard process.terminationStatus == 0 else {
            return .failure(.processFailed(process.terminationStatus))
        }
        return .success(stdoutData)
    }
}
