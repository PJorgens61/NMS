import Foundation

/// Flags whether a connectivity failure happened close enough in time to a
/// network topology change to plausibly be caused by it. This is a coarse
/// time-proximity heuristic, not causal proof.
struct CorrelationService {
    /// Failures within this many seconds of a snapshot's `capturedAt`
    /// (before or after) are considered correlated. Connectivity checks run
    /// every ~30s, so this comfortably covers "the check right after a
    /// change landed badly."
    static let defaultWindow: TimeInterval = 90

    func isCorrelated(checkedAt: Date, nearAny snapshots: [NetworkSnapshot], window: TimeInterval = defaultWindow) -> Bool {
        snapshots.contains { abs($0.capturedAt.timeIntervalSince(checkedAt)) <= window }
    }
}
