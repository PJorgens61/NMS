import SwiftUI

/// The at-a-glance health signal shown on the menu bar icon. Deliberately
/// three tiers, not a raw pass/fail per check — some problems (the whole
/// interface being down, or the router/internet/DNS/HTTP layers failing)
/// mean the network is actually broken; others (one monitored LAN device
/// being unreachable) are worth noting but don't mean that.
enum OverallStatus {
    case normal
    case marginal
    case critical

    var color: Color {
        switch self {
        case .normal: return .green
        case .marginal: return .yellow
        case .critical: return .red
        }
    }

    // Canonical label names for the four checks that mean "the network is
    // actually broken" if they fail — `ConnectivityViewModel` uses these
    // same constants so the two can never drift out of sync.
    static let routerLabel = "Router"
    static let internetLabel = "Internet"
    static let dnsLabel = "DNS"
    static let httpLabel = "HTTP"

    /// Labels whose failure means the network is actually broken (red), as
    /// opposed to a lesser/marginal problem (yellow) — anything else (e.g.
    /// a monitored LAN device) isn't in this set.
    static let criticalLabels: Set<String> = [routerLabel, internetLabel, dnsLabel, httpLabel]

    /// `interfaceIsDown` overrides everything else — no interface means
    /// nothing else can be meaningfully checked anyway.
    static func compute(interfaceIsDown: Bool, checks: [ConnectivityCheck]) -> OverallStatus {
        if interfaceIsDown {
            return .critical
        }
        if checks.contains(where: { !$0.success && criticalLabels.contains($0.label) }) {
            return .critical
        }
        if checks.contains(where: { !$0.success && !criticalLabels.contains($0.label) }) {
            return .marginal
        }
        return .normal
    }
}
