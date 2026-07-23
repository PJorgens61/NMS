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

    init(from check: ConnectivityCheck) {
        label = check.label
        target = check.target
        success = check.success
        latencyMs = check.latencyMs
        checkedAt = check.checkedAt
        correlatedWithChange = check.correlatedWithChange
    }
}
