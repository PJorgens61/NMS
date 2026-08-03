import Foundation
import SwiftData

/// One row per stress-test run — inserted unconditionally
/// (`SnapshotStore.recordWiFiStressTestResult`), never deduplicated,
/// same reasoning as `NetworkQualityRecord`: every run is a deliberate
/// data point worth keeping, not a change-log entry.
@Model
final class WiFiStressTestRecord {
    var streamCount: Int
    var packetsSent: Int
    var packetsReceived: Int
    var packetLossPercent: Double
    var minRTTMs: Double?
    var avgRTTMs: Double?
    var maxRTTMs: Double?
    var stddevRTTMs: Double?
    var peakCPUPercent: Double?
    var avgCPUPercent: Double?
    var routerAddress: String
    var isWiFi: Bool
    var testedAt: Date
    /// See `AppEventRecord.networkFingerprint` — same scoping, same
    /// `nil` meaning (a run recorded before this network was recognized,
    /// or before per-network scoping existed at all).
    var networkFingerprint: String? = nil

    init(from result: WiFiStressTestResult, networkFingerprint: String? = nil) {
        streamCount = result.streamCount
        packetsSent = result.packetsSent
        packetsReceived = result.packetsReceived
        packetLossPercent = result.packetLossPercent
        minRTTMs = result.minRTTMs
        avgRTTMs = result.avgRTTMs
        maxRTTMs = result.maxRTTMs
        stddevRTTMs = result.stddevRTTMs
        peakCPUPercent = result.peakCPUPercent
        avgCPUPercent = result.avgCPUPercent
        routerAddress = result.routerAddress
        isWiFi = result.isWiFi
        testedAt = result.testedAt
        self.networkFingerprint = networkFingerprint
    }
}
