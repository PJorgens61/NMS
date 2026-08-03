import Foundation

/// One stress-test burst's result. Like `NetworkQualityResult`, never
/// deduplicated against the previous run — every run is an intentional,
/// standalone data point to compare against past ones, not a change to
/// detect. See `WiFiStressTestService.runBurst`, the one producer.
struct WiFiStressTestResult: Equatable, Codable {
    /// How many concurrent streams this run actually used —
    /// `WiFiStressTestViewModel.wifiStreamCount`/`ethernetStreamCount`,
    /// whichever `isWiFi` selected. Persisted so history can show which
    /// tier a given run was, since the two aren't directly comparable.
    let streamCount: Int
    let packetsSent: Int
    let packetsReceived: Int
    let packetLossPercent: Double
    let minRTTMs: Double?
    let avgRTTMs: Double?
    let maxRTTMs: Double?
    let stddevRTTMs: Double?
    /// This Mac's own system-wide CPU load during the burst — see
    /// `CPULoadSampler`. Distinguishes "the network is the bottleneck"
    /// from "this Mac's own fork/exec rate is."
    let peakCPUPercent: Double?
    let avgCPUPercent: Double?
    let routerAddress: String
    let isWiFi: Bool
    let testedAt: Date
}
