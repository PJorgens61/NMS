import SwiftUI

/// Business SaaS status — a user-configurable list (`PreferencesView`'s
/// service picker) isn't reliably short once users can add their own
/// sites to monitor (see `PUNCHLIST.md`). See `SaaSMonitoringViewModel`
/// and DESIGN-NOTES.md's "Business SaaS monitoring".
///
/// Third of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry, and `EthernetTile`/`WiFiTile` for the first two) —
/// holds only the one `@ObservedObject` it actually reads.
struct SaaSStatusTile: View {
    @ObservedObject var saasMonitoring: SaaSMonitoringViewModel

    var body: some View {
        tile(title: "SaaS Status", fixedHeight: SectionLayout.saasMonitoring.boxHeight) {
            ForEach(saasMonitoring.statuses) { status in
                statusRow(status)
            }
            // Deliberately a separate group with its own small label, not
            // interleaved into the list above — a plain reachability
            // check to a user's own site is a genuinely weaker signal
            // than a real vendor status page (see `SaaSMonitoringViewModel
            // .checkUserAddedSites`'s doc comment), and showing it
            // identically would overstate that confidence. Absent
            // entirely when the user hasn't added anything, same as
            // every other conditional section in this app.
            if !saasMonitoring.userAddedStatuses.isEmpty {
                Text("Your Own Sites")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(saasMonitoring.userAddedStatuses) { status in
                    statusRow(status)
                }
            }
        }
    }

    /// One row, shared by the curated list and the user-added list above
    /// — same visual shape (dot, name, description, link), so the only
    /// thing distinguishing "weaker signal" is the section label, not a
    /// second row style to keep in sync with the first.
    private func statusRow(_ status: SaaSMonitoringViewModel.ServiceStatus) -> some View {
        HStack {
            Circle()
                .fill(indicatorColor(status.indicator))
                .frame(width: 8, height: 8)
            Text(status.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(status.description)
                .foregroundStyle(status.indicator == .none ? Color.secondary : indicatorColor(status.indicator))
                .lineLimit(1)
                .truncationMode(.middle)
            // Always present — `status.url` is always a real link
            // (the specific incident when there is one, the general
            // status page otherwise, see `SaaSStatusService
            // .CheckResult.url`), so "go check for yourself" is one
            // click away regardless of current health. A dedicated
            // icon button rather than making the description itself
            // look clickable — this app's first-ever use of `Link`,
            // shared via `externalLinkIcon` (`TileHelpers.swift`).
            externalLinkIcon(
                url: status.url,
                accessibilityLabel: "\(status.name) status page",
                accessibilityHint: "Opens \(status.name)'s status page in your browser"
            )
        }
        .font(.system(size: 12))
        // Same `.contain`-not-`.combine` reasoning as `ContentView`'s
        // `layerGridRow`'s own rows — keeps this row's status-page link
        // individually reachable while still exposing one frame for
        // `reportFrameForFieldTest`. Caveat: `status.name` isn't
        // guaranteed unique across the curated and user-added SaaS lists
        // — a collision would give two on-screen rows the same
        // identifier. Not a problem for anything reading this today;
        // worth knowing before relying on uniqueness elsewhere.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saasStatus.row.\(status.name)")
        .reportFrameForFieldTest("saasStatus.row.\(status.name)")
    }

    private func indicatorColor(_ indicator: SaaSStatusService.Indicator) -> Color {
        switch indicator {
        case .none: return .green
        case .minor: return .yellow
        case .major, .critical: return .red
        // Distinct from `.gray` (`.unknown`, below) on purpose — a
        // scheduled maintenance window is a successfully-parsed, planned
        // state, not a parsing gap, and shouldn't look like one.
        case .maintenance: return .blue
        case .unknown: return .gray
        }
    }
}
