import Foundation

/// Loads the local hop (Wi-Fi or Ethernet, whichever this Mac is on) to
/// expose weaknesses an idle-latency ping can't — a marginal Wi-Fi signal
/// or a flaky switch port often handles small pings fine while dropping
/// or retransmitting under sustained large-frame load. See
/// `PUNCHLIST.md`'s "local Wi-Fi stress test" entry for the full
/// reasoning behind the mechanism below.
///
/// **Not `ping -f` flood mode** — that needs root, which this app has
/// none of and shouldn't ask for. **Also not one `Process` spawn per
/// packet**, the original design — measured directly (not assumed) that
/// approach plateaus around ~1000-1200 pings/sec system-wide no matter
/// how many concurrent streams are added, because fork/exec overhead —
/// not the ~2ms local RTT — is the real bottleneck; by 200 one-shot
/// streams CPU was pinned near 100% for zero extra throughput. Instead:
/// one long-lived `ping` process per stream, looping internally via its
/// own `-i` interval, so N streams cost N process spawns for the whole
/// burst, not thousands. Measured result: 24 streams this way reach
/// ~4800 attempted pings/sec at ~40% CPU, versus the old design's ~1050/
/// sec at ~64% CPU for the same stream count.
///
/// **The `-i` interval floor is empirically ~0.002s here, not the 1
/// second `man ping` claims requires root.** Tested directly: `-i 0.005`
/// and `-i 0.002` both ran fine as a regular user; `-i 0.001` failed
/// immediately ("interval too short: Operation not permitted"). This
/// contradicts the man page, so it may not hold on every machine/macOS
/// version this app runs on (the MacBook Air in this project's two-Mac
/// setup, or a future OS) — `parseAttempted` below reads ping's own
/// summary line rather than assuming the fast interval always works, so
/// a rejected interval shows up as zero attempted packets rather than
/// silently misreporting.
nonisolated struct WiFiStressTestService {
    /// 200 Hz per stream — comfortable margin above the ~0.002s floor
    /// found by direct testing, so a slightly stricter floor on another
    /// machine still has room before hitting it.
    static let pingInterval: TimeInterval = 0.005

    /// One stream's result: `attempted` comes from ping's own "N packets
    /// transmitted" summary line (authoritative even if the process
    /// exited early or the interval was rejected on this machine — see
    /// this type's own doc comment), `rttsMs` from every individual
    /// `time=` reply line.
    struct StreamOutcome {
        let attempted: Int
        let rttsMs: [Double]
    }

    /// Runs one continuous, MTU-sized, `-D` (Don't Fragment) ping stream
    /// against `host` for roughly `duration`, at `Self.pingInterval`.
    ///
    /// `-s 1472`: a full 1500-byte frame after the 28-byte IP+ICMP
    /// header — large enough that a marginal link's real failure mode
    /// (drops/retransmits under large-frame load) actually shows up,
    /// unlike a small ping.
    ///
    /// `-D`: sets the IP Don't-Fragment bit. Confirmed directly (not
    /// assumed) that on BSD/macOS `ping` this does **not** add
    /// timestamps to the output — that's a different flag on
    /// Linux/iputils `ping`. Its actual effect here: an oversized packet
    /// fails loudly (`sendto: Message too long`) instead of silently
    /// fragmenting, which is the property this test actually wants.
    ///
    /// `-c count`: computed from `duration / Self.pingInterval` so the
    /// process exits on its own once its budget is sent, rather than
    /// needing to be killed after a wall-clock deadline the way a truly
    /// open-ended stream would.
    private func pingStream(host: String, count: Int) -> StreamOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-i", String(Self.pingInterval), "-c", String(count), "-s", "1472", "-D", host]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let trace = SubprocessTracer.begin(process.executableURL!.path, process.arguments ?? [])
        do {
            try process.run()
        } catch {
            SubprocessTracer.end(trace, exitCode: nil, byteCount: 0)
            return StreamOutcome(attempted: 0, rttsMs: [])
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: data.count)

        let output = String(data: data, encoding: .utf8) ?? ""
        return StreamOutcome(attempted: Self.parseAttempted(output), rttsMs: Self.parseLatencies(output))
    }

    /// One child task's own contribution to the burst — either a
    /// stream's full `StreamOutcome`, or the CPU sampler's readings. A
    /// single `withTaskGroup` needs one result type for every child
    /// task, so this enum is that shared type; `runBurst` below
    /// separates the two kinds back out once every task has finished.
    private enum StreamResult {
        case stream(StreamOutcome)
        case cpuSamples([Double])
    }

    /// Fires `streamCount` independent concurrent long-lived ping
    /// streams at `host`, plus one more concurrent task sampling this
    /// Mac's own CPU load throughout, then reduces everything to summary
    /// stats. Each stream is a single `Process` for the whole burst (see
    /// this type's own doc comment for why that replaced the original
    /// one-spawn-per-packet design) — completely independent of every
    /// other stream, which is what actually generates concurrent load
    /// rather than N streams that happen to run one after another.
    /// Uses `BlockingWork`/`withTaskGroup`, the same pattern
    /// `ConnectivityService.check(targets:)` already established for
    /// fanning out concurrent blocking `ping` subprocesses — deliberately
    /// not `DispatchGroup`, see that type's own doc comment for why.
    func runBurst(host: String, streamCount: Int, duration: TimeInterval) async -> WiFiStressTestStats {
        let count = max(1, Int((duration / Self.pingInterval).rounded()))

        let results = await withTaskGroup(of: StreamResult.self) { group in
            for _ in 0..<streamCount {
                group.addTask {
                    .stream(await BlockingWork.run { self.pingStream(host: host, count: count) })
                }
            }
            group.addTask {
                let sampler = CPULoadSampler()
                var samples: [Double] = []
                let deadline = Date().addingTimeInterval(duration)
                while Date() < deadline {
                    if let sample = sampler.sampleBusyPercent() {
                        samples.append(sample)
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                return .cpuSamples(samples)
            }

            var totalAttempted = 0
            var allRTTs: [Double] = []
            var allCPUSamples: [Double] = []
            for await result in group {
                switch result {
                case let .stream(outcome):
                    totalAttempted += outcome.attempted
                    allRTTs.append(contentsOf: outcome.rttsMs)
                case let .cpuSamples(samples):
                    allCPUSamples.append(contentsOf: samples)
                }
            }
            return (totalAttempted, allRTTs, allCPUSamples)
        }

        let (attempted, rttsMs, cpuSamples) = results
        return WiFiStressTestAggregator.aggregate(packetsSent: attempted, rttsMs: rttsMs, cpuSamples: cpuSamples, duration: duration)
    }

    private static let latencyRegex = try! NSRegularExpression(pattern: #"time=([0-9.]+) ms"#)
    private static let transmittedRegex = try! NSRegularExpression(pattern: #"(\d+) packets transmitted"#)

    private static func parseLatencies(_ output: String) -> [Double] {
        let ns = output as NSString
        let matches = latencyRegex.matches(in: output, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { Double(ns.substring(with: $0.range(at: 1))) }
    }

    /// Reads ping's own "N packets transmitted, ..." summary line rather
    /// than counting `time=` matches — authoritative even when a stream
    /// exits with zero successful replies (a rejected `-i` interval on
    /// some other machine, or the host being entirely unreachable),
    /// where a `time=`-based count would silently read zero instead of
    /// surfacing that nothing was actually attempted.
    private static func parseAttempted(_ output: String) -> Int {
        let ns = output as NSString
        guard let match = transmittedRegex.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) else {
            return 0
        }
        return Int(ns.substring(with: match.range(at: 1))) ?? 0
    }
}
