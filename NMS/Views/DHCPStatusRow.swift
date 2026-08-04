import SwiftUI

/// A DHCP row for the merged Network tile — "just a colored dot to
/// indicate normal/changed/abnormal status." Same five-cell shape every
/// other `GridRow` in `NetworkTile` uses, no sparkline/link icon
/// (`Color.clear` in both slots, same "always emit every cell" rule the
/// rest of that `Grid` follows).
///
/// Pulled out of `NetworkTile` into its own `View` type (see
/// `PUNCHLIST.md`'s view-structure factoring entry) — holds only
/// `dhcpLease`, so a change to any of `NetworkTile`'s other eight view
/// models no longer re-renders this row.
struct DHCPStatusRow: View {
    var dhcpLease: DHCPLeaseViewModel

    var body: some View {
        statusGridRow(
            color: color,
            label: "DHCP",
            detail: detailText
        ) {
            Color.clear.frame(width: 0, height: 0)
        } chart: {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Three states, not the shared `LayerStatus` every other row here
    /// uses — deliberately: `.unknown` already means "gray, nothing to
    /// judge yet" (see `ConnectionLayerRow`'s own color logic), not
    /// "yellow, something changed recently," so shoehorning DHCP into
    /// that enum would have reused a color for two different meanings.
    /// Red covers both real failure signals `DHCPLeaseViewModel` already
    /// tracks — a link-local (APIPA) fallback, meaning DHCP failed
    /// outright, and a renewal that's run past its expected T2 deadline
    /// — checked first so an abnormal state always wins over a merely-
    /// recent change. Yellow is "the current lease is new" (within
    /// `recentChangeWindow` of its own `firstObservedAt`), not a
    /// separate tracked flag — a real lease change already gets its own
    /// `AppEventKind` pair (`.dhcpLeaseChanged`) for the Events log; this
    /// only needs "is that recent enough to still matter here."
    private var color: Color {
        if dhcpLease.isFallenBackToLinkLocal || dhcpLease.isRenewalOverdue { return .red }
        if let firstObservedAt = dhcpLease.history.first?.firstObservedAt,
           Date().timeIntervalSince(firstObservedAt) < Self.recentChangeWindow {
            return .yellow
        }
        return .green
    }

    private var detailText: String {
        if dhcpLease.isFallenBackToLinkLocal { return "Link-local fallback" }
        if dhcpLease.isRenewalOverdue { return "Renewal overdue" }
        if let firstObservedAt = dhcpLease.history.first?.firstObservedAt,
           Date().timeIntervalSince(firstObservedAt) < Self.recentChangeWindow {
            return "Changed recently"
        }
        // "Nominal," not "Normal" — tried directly, on request, as this
        // app's one trial of NASA mission-control status language for
        // an all-expert audience. Only here so far: this row's green
        // dot supplies the "everything's fine" context the word alone
        // doesn't carry (real risk flagged before trying it — "nominal"
        // collides with its much more common everyday meaning, "a
        // nominal fee," near the opposite of what's meant here), so the
        // word is flavor on top of an unambiguous signal, not the only
        // one.
        return dhcpLease.history.isEmpty ? "Not checked" : "Nominal"
    }

    /// How long a fresh lease (by `firstObservedAt`) still reads as
    /// "changed" rather than settling back to "normal" — a few multiples
    /// of `DHCPLeaseViewModel.checkInterval` (5 minutes), long enough
    /// that the yellow dot is still there for someone who glances at the
    /// tile sometime after the actual renewal, not just in the instant
    /// it happened.
    private static let recentChangeWindow: TimeInterval = 600
}
