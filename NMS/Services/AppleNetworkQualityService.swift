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
    }

    struct Measurement {
        let downloadMbps: Double
        let uploadMbps: Double
        let downloadResponsivenessRPM: Int
        let uploadResponsivenessRPM: Int
        let baseRTTMs: Double
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
    /// doesn't request and doesn't parse.
    private struct RawResult: Decodable {
        let dl_throughput: Double
        let ul_throughput: Double
        let dl_responsiveness: Double
        let ul_responsiveness: Double
        let base_rtt: Double
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
    func measure(interfaceName: String?) -> Result<Measurement, QualityError> {
        guard Self.isAvailable else { return .failure(.unavailable) }

        var arguments = ["-c", "-s", "-M", "45"]
        if let interfaceName {
            arguments += ["-I", interfaceName]
        }

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

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: data.count)

        guard process.terminationStatus == 0 else {
            return .failure(.processFailed(process.terminationStatus))
        }
        guard let raw = try? JSONDecoder().decode(RawResult.self, from: data) else {
            return .failure(.unparseable)
        }

        return .success(Measurement(
            downloadMbps: raw.dl_throughput / 1_000_000,
            uploadMbps: raw.ul_throughput / 1_000_000,
            downloadResponsivenessRPM: Int(raw.dl_responsiveness.rounded()),
            uploadResponsivenessRPM: Int(raw.ul_responsiveness.rounded()),
            baseRTTMs: raw.base_rtt
        ))
    }
}
