import Foundation

/// Turns one stress-test burst's raw per-packet RTTs and periodic CPU
/// samples into the summary stats actually worth showing — pure and
/// directly testable, no `Process`/subprocess/async involved at all. See
/// `WiFiStressTestService.runBurst`, the one caller.
enum WiFiStressTestAggregator {
    static func aggregate(packetsSent: Int, rttsMs: [Double], cpuSamples: [Double]) -> WiFiStressTestStats {
        let received = rttsMs.count
        let lossPercent = packetsSent > 0
            ? Double(packetsSent - received) / Double(packetsSent) * 100
            : 0

        let peakCPU = cpuSamples.max()
        let avgCPU = cpuSamples.isEmpty ? nil : cpuSamples.reduce(0, +) / Double(cpuSamples.count)

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
                avgCPUPercent: avgCPU
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
            avgCPUPercent: avgCPU
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
}
