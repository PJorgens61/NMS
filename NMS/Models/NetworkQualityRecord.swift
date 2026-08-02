import Foundation
import SwiftData

/// One row per speed-test run — inserted unconditionally
/// (`SnapshotStore.recordNetworkQualityResult`), never deduplicated like
/// `PublicIPRecord`/`DHCPLeaseRecord`. A genuine time series: every run
/// the user asks for is a data point worth keeping, not a change-log
/// entry.
@Model
final class NetworkQualityRecord {
    var downloadMbps: Double
    var uploadMbps: Double
    var testedAt: Date
    /// Added alongside `AppleNetworkQualityService`. All four new fields
    /// are optional with a default, so this stays a lightweight migration
    /// on an existing on-disk store — rows written before this existed
    /// read back as `nil`/`cloudflareEndpoint`, which is correct: every
    /// run before today genuinely came from that source and genuinely has
    /// no RPM measurement, not missing data.
    var downloadResponsivenessRPM: Int? = nil
    var uploadResponsivenessRPM: Int? = nil
    var baseRTTMs: Double? = nil
    var source: String = NetworkQualityResult.Source.cloudflareEndpoint.rawValue
    /// See `AppEventRecord.networkFingerprint` — same scoping, same `nil`
    /// meaning. Added after offsite testing reported a previous network's
    /// speed-test runs showing up in a new network's history; plain
    /// optional, same no-migration-risk shape as `downloadResponsivenessRPM`
    /// above, so an existing on-disk store's older rows just read back as
    /// `nil` (correct — they predate per-network scoping and were never
    /// attributed to one).
    var networkFingerprint: String? = nil

    init(from result: NetworkQualityResult, networkFingerprint: String? = nil) {
        downloadMbps = result.downloadMbps
        uploadMbps = result.uploadMbps
        testedAt = result.testedAt
        downloadResponsivenessRPM = result.downloadResponsivenessRPM
        uploadResponsivenessRPM = result.uploadResponsivenessRPM
        baseRTTMs = result.baseRTTMs
        source = result.source.rawValue
        self.networkFingerprint = networkFingerprint
    }
}
