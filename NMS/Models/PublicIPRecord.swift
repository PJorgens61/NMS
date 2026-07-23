import Foundation
import SwiftData

/// Persisted history of public-IP changes. Like `NetworkSnapshot`, only
/// real changes get a row (see `SnapshotStore.recordPublicIPIfChanged`) —
/// this is a timeline of "your public IP changed to X at time T", not a
/// per-check log.
@Model
final class PublicIPRecord {
    var ipAddress: String
    var observedAt: Date

    init(from info: PublicIPInfo) {
        ipAddress = info.ipAddress
        observedAt = info.checkedAt
    }
}
