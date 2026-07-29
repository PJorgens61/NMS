import Foundation
import SwiftData

/// Persisted history of `ConnectivityCheck` results. Not tied to a
/// `NetworkSnapshot` by relationship — correlation with topology changes
/// happens by comparing `checkedAt` against `NetworkSnapshot.capturedAt`
/// timestamps instead (see the "Correlation" step in the README).
@Model
final class ConnectivityCheckRecord {
    var label: String
    var target: String
    var success: Bool
    var latencyMs: Double?
    var checkedAt: Date
    var correlatedWithChange: Bool = false
    /// Normalized CPU load at the time of the round — see
    /// `SystemLoadService`. Optional with a default so adding it to an
    /// existing on-disk store stays a lightweight migration; rows
    /// written before this existed read back as `nil`, which is honest
    /// (unknown) rather than 0 (idle).
    ///
    /// Worth the ~8 bytes on this table specifically, even though it's
    /// ~90% of the store: this is the table whose failures need
    /// explaining, and "was the Mac pinned when every ping timed out?"
    /// is otherwise unanswerable after the fact.
    var systemLoad: Double? = nil

    init(from check: ConnectivityCheck) {
        label = check.label
        target = check.target
        success = check.success
        latencyMs = check.latencyMs
        checkedAt = check.checkedAt
        correlatedWithChange = check.correlatedWithChange
        systemLoad = check.systemLoad
    }
}
