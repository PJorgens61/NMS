import Foundation

/// Loads the local hop (Wi-Fi or Ethernet, whichever this Mac is on) to
/// expose weaknesses an idle-latency ping can't — a marginal Wi-Fi signal
/// or a flaky switch port often handles small pings fine while dropping
/// or retransmitting under sustained large-frame load. See
/// `PUNCHLIST.md`'s "local Wi-Fi stress test" entry for the full
/// reasoning behind the mechanism below.
///
/// **Not `ping -f` flood mode** — that needs root, which this app has
/// none of and shouldn't ask for. Instead: N independent concurrent
/// streams, each a serial loop of single-shot, MTU-sized pings, firing
/// its next packet the instant its own previous reply lands. No stream
/// waits on any other, and no elevated privileges are needed at any
/// concurrency.
nonisolated struct WiFiStressTestService {
    struct PingOutcome {
        let success: Bool
        let latencyMs: Double?
    }

    /// One MTU-sized, `-D` (Don't Fragment), 1-second-bounded ping.
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
    /// `-t 1`: bounds the whole process to ~1 wall-clock second.
    /// Confirmed necessary directly: a plain `-c 1` against a silent
    /// host takes ~1.3s to give up (BSD ping's own default deadline),
    /// and `-W <ms>` does **not** bound this for a `-c 1` run (tested,
    /// still ~1.3s with `-W 300`) — only `-t` does. Without this, one
    /// lost packet late in the burst could stall its stream well past
    /// the intended window.
    private func pingOnce(host: String) -> PingOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-s", "1472", "-D", "-t", "1", host]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let trace = SubprocessTracer.begin(process.executableURL!.path, process.arguments ?? [])
        do {
            try process.run()
        } catch {
            SubprocessTracer.end(trace, exitCode: nil, byteCount: 0)
            return PingOutcome(success: false, latencyMs: nil)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: data.count)

        let output = String(data: data, encoding: .utf8) ?? ""
        let latencyMs = Self.parseLatency(output)
        return PingOutcome(success: process.terminationStatus == 0 && latencyMs != nil, latencyMs: latencyMs)
    }

    /// One child task's own contribution to the burst — either a stream's
    /// full run of `PingOutcome`s, or the CPU sampler's readings. A single
    /// `withTaskGroup` needs one result type for every child task, so
    /// this enum is that shared type; `runBurst` below separates the two
    /// kinds back out once every task has finished.
    private enum StreamResult {
        case pings([PingOutcome])
        case cpuSamples([Double])
    }

    /// Fires `streamCount` independent concurrent ping streams at `host`
    /// for `duration`, plus one more concurrent task sampling this Mac's
    /// own CPU load throughout, then reduces everything to summary stats.
    ///
    /// Each stream is its own serial loop — `while Date() < deadline`,
    /// fire, wait for that reply, fire again — completely independent of
    /// every other stream, which is what actually generates concurrent
    /// load rather than N pings that happen to run one after another.
    /// Uses `BlockingWork`/`withTaskGroup`, the same pattern
    /// `ConnectivityService.check(targets:)` already established for
    /// fanning out concurrent blocking `ping` subprocesses — deliberately
    /// not `DispatchGroup`, see that type's own doc comment for why.
    func runBurst(host: String, streamCount: Int, duration: TimeInterval) async -> WiFiStressTestStats {
        let deadline = Date().addingTimeInterval(duration)

        let results = await withTaskGroup(of: StreamResult.self) { group in
            for _ in 0..<streamCount {
                group.addTask {
                    var outcomes: [PingOutcome] = []
                    while Date() < deadline {
                        outcomes.append(await BlockingWork.run { self.pingOnce(host: host) })
                    }
                    return .pings(outcomes)
                }
            }
            group.addTask {
                let sampler = CPULoadSampler()
                var samples: [Double] = []
                while Date() < deadline {
                    if let sample = sampler.sampleBusyPercent() {
                        samples.append(sample)
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                return .cpuSamples(samples)
            }

            var allOutcomes: [PingOutcome] = []
            var allCPUSamples: [Double] = []
            for await result in group {
                switch result {
                case let .pings(outcomes):
                    allOutcomes.append(contentsOf: outcomes)
                case let .cpuSamples(samples):
                    allCPUSamples.append(contentsOf: samples)
                }
            }
            return (allOutcomes, allCPUSamples)
        }

        let (outcomes, cpuSamples) = results
        let rttsMs = outcomes.compactMap(\.latencyMs)
        return WiFiStressTestAggregator.aggregate(packetsSent: outcomes.count, rttsMs: rttsMs, cpuSamples: cpuSamples)
    }

    private static let latencyRegex = try! NSRegularExpression(pattern: #"time=([0-9.]+) ms"#)

    private static func parseLatency(_ output: String) -> Double? {
        let ns = output as NSString
        guard let match = latencyRegex.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Double(ns.substring(with: match.range(at: 1)))
    }
}
