import SwiftUI

/// The "networkQuality" quick-check row at the top of `NetworkTile`'s
/// `Grid` — same five-cell shape every other `GridRow` there uses (an
/// icon button styled identically to `externalLinkIcon`, in the same
/// column position, so it aligns with the Router row's link icon by
/// construction). The dot stays gray until a result exists — never
/// claims a verdict it hasn't earned.
///
/// Pulled out of `NetworkTile` into its own `View` type (see
/// `PUNCHLIST.md`'s view-structure factoring entry) — holds only
/// `networkQuality`, so a change to any of `NetworkTile`'s other eight
/// view models no longer re-renders this row (SwiftUI's own struct
/// diffing skips it once its inputs are unchanged, even though
/// `NetworkTile.body` itself still reruns). `interfaceName` is a narrow
/// plain value, not the whole `NetworkMonitorViewModel` reference — this
/// row reads nothing else from it.
struct QuickCheckRow: View {
    var networkQuality: NetworkQualityViewModel
    let interfaceName: String?

    var body: some View {
        statusGridRow(
            color: color,
            // Same tooltip the Apple networkQuality tile's own RPM
            // figures use (`QuickCheckDisplay.rpmThresholdHelp`) —
            // raised directly, so the two surfaces' colored verdicts
            // explain themselves the same way.
            dotHelp: QuickCheckDisplay.rpmThresholdHelp,
            // "networkQuality" — matches the Apple networkQuality
            // tile's own name for the full test this is a quick preview
            // of, reported directly as clearer than "Call Check". Length
            // is close to the original "Video Call Check" that was
            // shortened for truncation reasons (see `detailText`'s
            // trailing column) — re-verify visually after this rename.
            label: "networkQuality",
            detail: detailText
        ) {
            Button {
                networkQuality.runQuickCheck(interfaceName: interfaceName)
            } label: {
                Image(systemName: "play.circle")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(networkQuality.isRunningQuickCheck || networkQuality.isRunning)
            .accessibilityLabel("networkQuality")
            .accessibilityHint("Runs a quick, about 5 second check of your connection's responsiveness under load, useful before a video call. Uses your data plan.")
            .accessibilityIdentifier("networkHealth.quickCheck")
            .help("Runs a quick, about 5 second check of your connection's responsiveness under load, useful before a video call. Uses your data plan.")
        } chart: {
            historyDots
        }
    }

    private var color: Color {
        guard let status = networkQuality.quickCheckStatus else { return .gray }
        return QuickCheckDisplay.color(forRPM: status.rpm)
    }

    /// A verdict trail, not a line chart — each quick check is a discrete
    /// good/fair/poor judgment, not a continuous value, so a sequence of
    /// colored dots reads more honestly than a `Sparkline` interpolating
    /// between them. Packed tightly at a fixed gap rather than stretched
    /// to the same `44pt` width every other row's `Sparkline` occupies —
    /// tried that first (even `Spacer`-based distribution filling a
    /// fixed width, 2pt dots) and confirmed live it was the wrong
    /// trade-off: technically visible, practically unreadable as a
    /// "trail" rather than dust on the screen, especially with few
    /// points spread thin across the full width. Larger, close-packed
    /// dots read clearly; the column simply grows with history instead
    /// of remaining pinned to the same width as the layer rows' own
    /// sparklines. Oldest first (leftmost), matching every other row's
    /// sparkline convention (`ConnectionLayerRow`'s own values are
    /// already-reversed-to-chronological arrays by the time they reach
    /// `Sparkline`).
    @ViewBuilder
    private var historyDots: some View {
        // Filters, doesn't compactMap to just the RPM values -- keeps each
        // `NetworkQualityRecord` around so ForEach below can use its own
        // real (SwiftData-provided) identity instead of array offset. Same
        // pattern already relied on for `dhcpLease.history`/`snmp.devices`
        // elsewhere in this app.
        let records = networkQuality.quickCheckHistory.reversed().filter { $0.combinedResponsivenessRPM != nil }
        if records.isEmpty {
            // Same "always emit every cell" rule the rest of this Grid
            // follows — see `ConnectionLayerRow`'s own sparkline column
            // for why an empty cell still needs a real, zero-sized view
            // rather than being omitted outright.
            Color.clear.frame(width: 0, height: 0)
        } else {
            HStack(spacing: 2) {
                ForEach(records) { record in
                    Circle()
                        .fill(QuickCheckDisplay.color(forRPM: record.combinedResponsivenessRPM ?? 0))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }

    private var detailText: String {
        if networkQuality.isRunningQuickCheck { return "Checking…" }
        if let error = networkQuality.quickCheckError { return error }
        // Shorter than "\(status.label) — \(status.rpm) RPM" (tried
        // first) — that version truncated in the middle of the RPM
        // number once the label above was long enough to squeeze it.
        if let status = networkQuality.quickCheckStatus { return "\(status.label) (\(status.rpm))" }
        return "Tap to check"
    }
}
