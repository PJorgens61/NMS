import Foundation

/// Turns one stress-test burst's raw per-packet RTTs and periodic CPU
/// samples into the summary stats actually worth showing — pure and
/// directly testable, no `Process`/subprocess/async involved at all. See
/// `WiFiStressTestService.runBurst`, the one caller.
enum WiFiStressTestAggregator {
    /// 1472-byte ICMP payload + 8-byte ICMP header + 20-byte IP header —
    /// the actual on-wire size of each MTU-sized packet this test sends,
    /// used to turn a packet rate into a bandwidth figure below.
    static let onWireBytesPerPacket = 1500

    static func aggregate(packetsSent: Int, rttsMs: [Double], cpuSamples: [Double], duration: TimeInterval) -> WiFiStressTestStats {
        let received = rttsMs.count
        let lossPercent = packetsSent > 0
            ? Double(packetsSent - received) / Double(packetsSent) * 100
            : 0

        let peakCPU = cpuSamples.max()
        let avgCPU = cpuSamples.isEmpty ? nil : cpuSamples.reduce(0, +) / Double(cpuSamples.count)

        // Attempted-send rate/bandwidth, not received -- this is "how hard
        // are we actually driving the link," the figure worth watching
        // live on a field test to judge whether a run is pushing enough
        // load to be a meaningful test of the network in front of it.
        let packetsPerSecond = duration > 0 ? Double(packetsSent) / duration : 0
        let megabitsPerSecond = packetsPerSecond * Double(onWireBytesPerPacket) * 8 / 1_000_000

        guard !rttsMs.isEmpty else {
            return WiFiStressTestStats(
                packetsSent: packetsSent,
                packetsReceived: received,
                packetLossPercent: lossPercent,
                minRTTMs: nil,
                avgRTTMs: nil,
                maxRTTMs: nil,
                stddevRTTMs: nil,
                peakCPUPercent: peakCPU,
                avgCPUPercent: avgCPU,
                packetsPerSecond: packetsPerSecond,
                megabitsPerSecond: megabitsPerSecond
            )
        }

        let avg = rttsMs.reduce(0, +) / Double(rttsMs.count)
        // Population stddev (÷N, not ÷N-1), deliberately — matches BSD
        // ping's own "round-trip min/avg/max/stddev" summary line
        // convention, so this number is directly comparable to a manual
        // terminal run of the same tool.
        let variance = rttsMs.reduce(0) { $0 + pow($1 - avg, 2) } / Double(rttsMs.count)

        return WiFiStressTestStats(
            packetsSent: packetsSent,
            packetsReceived: received,
            packetLossPercent: lossPercent,
            minRTTMs: rttsMs.min(),
            avgRTTMs: avg,
            maxRTTMs: rttsMs.max(),
            stddevRTTMs: sqrt(variance),
            peakCPUPercent: peakCPU,
            avgCPUPercent: avgCPU,
            packetsPerSecond: packetsPerSecond,
            megabitsPerSecond: megabitsPerSecond
        )
    }
}

struct WiFiStressTestStats: Equatable {
    let packetsSent: Int
    let packetsReceived: Int
    let packetLossPercent: Double
    let minRTTMs: Double?
    let avgRTTMs: Double?
    let maxRTTMs: Double?
    let stddevRTTMs: Double?
    let peakCPUPercent: Double?
    let avgCPUPercent: Double?
    /// Attempted send rate/bandwidth -- see `aggregate`'s own comment on
    /// why attempted rather than received.
    let packetsPerSecond: Double
    let megabitsPerSecond: Double
}
