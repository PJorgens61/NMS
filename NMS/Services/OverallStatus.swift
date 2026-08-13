import SwiftUI

/// The at-a-glance health signal shown on the menu bar icon. Deliberately
/// three tiers, not a raw pass/fail per check — some problems (the whole
/// interface being down, or the router/internet/DNS/HTTP layers failing)
/// mean the network is actually broken; others (one monitored LAN device
/// being unreachable) are worth noting but don't mean that.
nonisolated enum OverallStatus {
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
    static let internetLabel = "Internet by Address"
    static let dnsLabel = "DNS"
    static let httpLabel = "HTTP"
    static let peRouterLabel = "ISP Edge Router"
    /// Pinging the router's own public/WAN-facing address, not a remote
    /// host — verified directly (ttl=64, sub-millisecond RTT) that this is
    /// answered locally by the gateway recognizing its own address, not a
    /// real round trip to the internet. Distinct from `internetLabel`
    /// (which does leave the network, to `1.1.1.1`) and from `routerLabel`
    /// (the router's LAN-side address) — this specifically tests whether
    /// the gateway's WAN side is alive, catching things like the ISP
    /// modem/ONT losing power that a LAN-side-only check can't see.
    static let publicIPLabel = "Public IP"

    /// Labels whose failure means the network is actually broken (red), as
    /// opposed to a lesser/marginal problem (yellow) — anything else (e.g.
    /// a monitored LAN device) isn't in this set.
    static let criticalLabels: Set<String> = [routerLabel, internetLabel, dnsLabel, httpLabel, peRouterLabel, publicIPLabel]

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

    /// The popover's menu bar icon color — the single, aggregate signal a
    /// glance at the icon needs, so it's `compute` plus the one real
    /// signal `compute` alone can't see: DHCP link-local fallback/
    /// overdue-renewal, which isn't itself a `ConnectivityCheck`. Was
    /// dead code before the popover conversion (only this file's own
    /// tests called `compute` directly) — this is the direct answer to
    /// compressing `NetworkTile`'s whole 9-row grid into one icon color,
    /// not a new aggregation invented for it.
    static func computeForPopover(interfaceIsDown: Bool, checks: [ConnectivityCheck], dhcpIsAbnormal: Bool) -> OverallStatus {
        let base = compute(interfaceIsDown: interfaceIsDown, checks: checks)
        if dhcpIsAbnormal && base == .normal { return .marginal }
        return base
    }

    /// Labels that represent *local* link health — reaching your own
    /// router — as opposed to the internet actually being reachable
    /// beyond it. Split out from `criticalLabels` specifically for the
    /// popover's two separate status lines (Internet, MyWifi), each
    /// needing its own independent signal rather than one merged one.
    static let localLabels: Set<String> = [routerLabel]
    /// The remaining critical labels once `localLabels` is set aside —
    /// "is the internet actually reachable past your own router."
    static let internetOnlyLabels: Set<String> = [internetLabel, dnsLabel, httpLabel, peRouterLabel, publicIPLabel]

    /// The popover's MyWifi/Ethernet status line — local link health
    /// only (interface up, router reachable), plus DHCP abnormality
    /// (link-local fallback or overdue renewal — a local-link problem,
    /// not an internet-reachability one).
    static func computeLocal(interfaceIsDown: Bool, checks: [ConnectivityCheck], dhcpIsAbnormal: Bool) -> OverallStatus {
        if interfaceIsDown { return .critical }
        if checks.contains(where: { !$0.success && localLabels.contains($0.label) }) { return .critical }
        if dhcpIsAbnormal { return .marginal }
        return .normal
    }

    /// The popover's Internet status line — everything downstream of the
    /// local router: the public internet, DNS, HTTP, the confirmed ISP
    /// edge hop, and the gateway's own WAN-side reachability.
    static func computeInternet(checks: [ConnectivityCheck]) -> OverallStatus {
        if checks.contains(where: { !$0.success && internetOnlyLabels.contains($0.label) }) { return .critical }
        return .normal
    }
}
