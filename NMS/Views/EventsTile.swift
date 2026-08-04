import SwiftUI

/// The Events tile — a running log of things that changed (outages,
/// recoveries, DHCP renewals, and the like). See `AppEventRecord`/
/// `EventLogViewModel`.
///
/// Fourth of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry) — holds only the one `@ObservedObject` it actually
/// reads.
struct EventsTile: View {
    @ObservedObject var eventLog: EventLogViewModel

    var body: some View {
        tile(title: "Events", fixedHeight: SectionLayout.events.boxHeight) {
            if eventLog.events.isEmpty {
                // Explains *why* it's empty rather than just stating that
                // it is — a bare "No events yet" on a fresh install (with
                // a perfectly healthy network) reads as "is this
                // broken?" to a new user. Deliberately not backfilled
                // with synthetic "everything came up fine" events
                // instead: this log is meant to be a trustworthy record
                // of things that actually happened, and fabricated
                // entries at install would be indistinguishable from
                // real ones later.
                Text("No events yet — everything's healthy. Entries appear here when something changes (an outage or a recovery).")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                ForEach(eventLog.events) { event in
                    // `.top`, not the default `.center` — once `message`
                    // can wrap to more than one line, centering would
                    // float the timestamp/link partway down a tall row
                    // instead of pinning it level with the message's
                    // first line.
                    HStack(alignment: .top) {
                        // No `lineLimit`/`truncationMode` — Events is a
                        // generous, independently scrolling 350pt area
                        // (`SectionLayout.events`), so a long message
                        // just wraps and takes more of that scroll, the
                        // same way any other section's overflow already
                        // works. `fixedSize` forces the wrap to actually
                        // happen instead of `Text` compressing to fit the
                        // `HStack`'s available width the way a flexible
                        // sibling next to `Spacer()` normally would.
                        Text(event.message)
                            .font(.system(size: 12))
                            .foregroundStyle(color(for: event))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        // `AppEventRecord.url` carries a related link;
                        // only `.saasServiceDown` sets one today, so this
                        // is absent for every other event kind.
                        if let url = event.url {
                            externalLinkIcon(
                                url: url,
                                accessibilityLabel: "Related link",
                                accessibilityHint: "Opens this event's related link in your browser"
                            )
                        }
                        Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func color(for event: AppEventRecord) -> Color {
        guard let kind = AppEventKind(rawValue: event.kind) else { return .primary }
        switch kind.polarity {
        case .positive: return .green
        case .negative: return .red
        case .neutral: return .primary
        }
    }
}
