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

    init(from result: NetworkQualityResult) {
        downloadMbps = result.downloadMbps
        uploadMbps = result.uploadMbps
        testedAt = result.testedAt
    }
}
