import Foundation

/// One check's latency, for the Network Health sparklines.
///
/// A value type rather than passing `ConnectivityCheckRecord` (a
/// SwiftData `@Model`) out to the view layer — deliberately, having just
/// fixed a bug where a `@Model` crossed a thread boundary in
/// `LANDiscoveryViewModel`. Models belong to the context that owns them;
/// views should see plain values.
struct LatencySample: Equatable {
    /// `nil` for a failed check, and that distinction is the whole point
    /// of the sparkline. Treating a failure as zero would render an
    /// outage as an unusually *fast* response — see `Sparkline`, which
    /// draws these as separate failure marks rather than points on the
    /// line.
    let latencyMs: Double?
    let checkedAt: Date
}
