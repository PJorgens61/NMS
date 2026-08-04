import SwiftUI

/// One summary row for however many DDNS hostnames are configured — not
/// one row per hostname, to keep this from growing the tile unboundedly
/// the way `FeatureFlags.UserAddedSaaSSite` deliberately stays out of the
/// curated SaaS table for the same reason. Per-hostname detail lives in
/// the tooltip and, for a genuine transition, the Events list. Renders
/// nothing at all until a hostname is configured.
///
/// Pulled out of `NetworkTile` into its own `View` type (see
/// `PUNCHLIST.md`'s view-structure factoring entry) — holds only `ddns`,
/// so a change to any of `NetworkTile`'s other eight view models no
/// longer re-renders this row.
struct DDNSRow: View {
    var ddns: DDNSViewModel

    var body: some View {
        if !ddns.statuses.isEmpty {
            HStack {
                Text("DDNS")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    ddns.checkAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(ddns.isChecking)
                .accessibilityLabel("Check DDNS hostnames now")
                .accessibilityIdentifier("info.ddns.checkNow")
                .help("Resolves every configured DDNS hostname now, rather than waiting for the next scheduled check.")
                Circle()
                    .fill(summaryColor)
                    .frame(width: 8, height: 8)
                Text(summaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
            .help(tooltipText)
        }
    }

    /// Worst state wins — a single red dot for one stale hostname among
    /// several shouldn't be averaged away by the others being fine.
    /// `.blockedByCGNAT` renders distinctly from both: not a failure
    /// (green would be dishonest) and not "something broke" (red would
    /// overstate it) — a structural fact about this connection, same
    /// `.orange` tier the "possibly related to a recent network change"
    /// annotation elsewhere in `NetworkTile` already uses for "worth
    /// noting, not a failure."
    private var summaryColor: Color {
        let states = ddns.statuses.compactMap(\.syncState)
        if states.contains(.stale) { return .red }
        if states.contains(.blockedByCGNAT) { return .orange }
        if states.count == ddns.statuses.count, states.allSatisfy({ $0 == .current }) { return .green }
        return .secondary
    }

    private var summaryText: String {
        let name = ddns.statuses.count == 1 ? ddns.statuses[0].hostname : "\(ddns.statuses.count) hostnames"
        let minutes = Int(FeatureFlags.ddnsCheckInterval / 60)
        return "\(name) · every \(minutes)m"
    }

    private var tooltipText: String {
        ddns.statuses.map { status in
            let state: String
            switch status.syncState {
            case .current: state = "in sync"
            case .stale: state = "stale — check your DDNS client"
            case .blockedByCGNAT: state = "blocked by CGNAT"
            case nil: state = status.lastError ?? "checking…"
            }
            return "\(status.hostname): \(state)"
        }.joined(separator: "\n")
    }
}
