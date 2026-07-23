import Foundation

/// The result of a single reachability check against one target.
struct ConnectivityCheck: Equatable, Codable, Identifiable {
    var id: String { label }

    /// Human-readable target name, e.g. "Router" or "rock.local".
    let label: String
    /// The host or IP actually pinged.
    let target: String
    let success: Bool
    let latencyMs: Double?
    let checkedAt: Date
    /// Whether this failure landed near a topology change (see
    /// `CorrelationService`). Always `false` for successful checks, and
    /// `false` until `SnapshotStore.saveConnectivityChecks` computes it.
    var correlatedWithChange: Bool = false
}
