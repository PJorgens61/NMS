import SwiftUI

/// The "Path to Internet" tile: current-trace status, then (once there's
/// a real path) the hop list.
///
/// Sixth of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry) — reads three `@ObservedObject`s: `traceroute` for the
/// hop list itself, `viewModel` for the "is there even an interface"
/// gate, `connectivity` only to trigger a fresh check when the monitored
/// hop changes.
struct PathToInternetTile: View {
    @ObservedObject var traceroute: TracerouteViewModel
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @ObservedObject var connectivity: ConnectivityViewModel

    var body: some View {
        tile(title: "Path to Internet", fixedHeight: ContentView.tileHeight, trailing: {
            Button("Trace Now") {
                traceroute.run()
            }
            .disabled(traceroute.isRunning)
            .accessibilityLabel("Trace Now")
            .accessibilityHint("Runs a traceroute to find the path to the internet")
            .accessibilityIdentifier("pathToInternet.traceNow")
        }) {
            currentPathStatus
            if viewModel.currentInterface != nil, !traceroute.hops.isEmpty {
                hopRows
            }
        }
    }

    /// What the latest trace found, or why there's nothing to show yet —
    /// a 5-branch state machine, each branch fixing a real, previously
    /// confusing case rather than accidental complexity:
    @ViewBuilder
    private var currentPathStatus: some View {
        if viewModel.currentInterface == nil {
            // Reported directly: without this, a real outage fell through
            // to stale hop data from before the interface went down (or,
            // if the trace attempt during the outage returned an empty
            // result, to "Not traced yet") — either way, nothing here
            // said the actual, certain cause was "there's no interface to
            // trace from at all." Same reasoning as the Network tile's
            // Network/Local Router/ISP Edge Router rows: this is a
            // certain consequence of the root cause, not something to
            // leave looking like stale-but-plausible data.
            Text("Interface down")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if let monitored = traceroute.monitoredHop {
            // No summary row here for the monitored hop's name/address —
            // that's already shown in the Network tile (as a response
            // time, not a name) and in the starred row in the hops list
            // below, so a third copy was just a spare line.
            Button("Stop monitoring hop \(monitored.hopNumber)") {
                traceroute.monitorHop(nil)
                // Drops the ISP Edge Router ping target on the next round —
                // check right away instead of leaving the Network tile
                // showing its last (now stale) status for up to 30s.
                connectivity.runChecks()
            }
            .font(.system(size: 11))
            .accessibilityLabel("Stop monitoring hop \(monitored.hopNumber)")
            .accessibilityHint("Stops treating this hop as the ISP edge router")
            .accessibilityIdentifier("pathToInternet.stopMonitoringHop")
        } else if let suggested = traceroute.suggestedEdgeHop {
            // A separate wrapped-text row here used to explain this, at a
            // real height cost: every *new* network starts unconfirmed, so
            // this branch — and the extra line — appeared on every network
            // visited for the first time, not just occasionally. Testing
            // on other networks is exactly what surfaced it, since the
            // home network's hop had long since been confirmed and never
            // showed the branch at all. A tooltip on the row itself, same
            // pattern as `dhcpLeaseHelp`/`reachabilityHelp`, keeps the
            // explanation without the line.
            row("Suggested (unconfirmed)", suggested.hostname ?? suggested.address ?? "—")
                .help(Self.suggestedEdgeHopHelp)
        } else if traceroute.isRunning {
            Text("Tracing…")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if traceroute.hops.isEmpty {
            Text("Not traced yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }

        // Independent of the branch above, and would otherwise keep
        // showing a stale pre-outage error underneath "Interface down" —
        // exactly the confusing mix that branch exists to avoid.
        if viewModel.currentInterface != nil, let error = traceroute.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }

        // Also independent of the branches above — surfaces whenever
        // the current trace shows more than one NAT hop before the
        // internet, whatever else this tile is currently showing.
        // `TracerouteViewModel` already computed and logged this (see
        // `logAddressingChangeIfNeeded`), but only as one entry in the
        // Events history, on the one trace where the state actually
        // changed — a real gap raised from offsite testing: nothing
        // showed the *current* state at a glance, so a double-NAT'd
        // network someone joined mid-session (or one that predates
        // this app being installed, so it never logged a "change" at
        // all) had no visible answer to "why is my public IP shared."
        // Not colored red like `lastError` above — an extra NAT layer
        // is often just how a network is built (a home router behind
        // an ISP's own gateway), not a fault.
        if let count = cgnatRowText {
            row("NAT", count)
                .foregroundStyle(.orange)
        }
    }

    /// `nil` when the current trace has at most one NAT hop before the
    /// internet — the normal case, not worth a row. See `currentPathStatus`'s
    /// use of this for why it's shown independently of the trace's other
    /// states.
    private var cgnatRowText: String? {
        let count = TracerouteViewModel.leadingNonInternetHopCount(traceroute.hops)
        guard count > 1 else { return nil }
        return TracerouteViewModel.includesConfirmedCGNAT(traceroute.hops)
            ? "CGNAT — shared public IP"
            : "Multiple layers (\(count) hops)"
    }

    private var hopRows: some View {
        ForEach(displayedHops) { hop in
            HStack {
                Text("\(hop.hopNumber)")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
                Text(hopLabel(for: hop))
                    .foregroundStyle(hopColor(for: hop))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(hopRTT(for: hop))
                    .foregroundStyle(.secondary)
                Button {
                    let isMonitored = traceroute.monitoredHopNumber == hop.hopNumber
                    traceroute.monitorHop(isMonitored ? nil : hop.hopNumber)
                    // New/changed ISP Edge Router ping target — check right
                    // away instead of waiting up to 30s for the next round.
                    connectivity.runChecks()
                } label: {
                    Image(systemName: traceroute.monitoredHopNumber == hop.hopNumber ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .disabled(hop.address == nil)
                // Icon-only, so there is no text for VoiceOver to fall back
                // on — without this it announces only "button".
                .accessibilityLabel(
                    traceroute.monitoredHopNumber == hop.hopNumber
                        ? "Monitored ISP edge router, hop \(hop.hopNumber)"
                        : "Monitor hop \(hop.hopNumber) as ISP edge router"
                )
                .accessibilityIdentifier("pathToInternet.monitorHop.\(hop.hopNumber)")
            }
            .font(.system(size: 11))
        }
    }

    /// Once a hop is confirmed as the one to monitor, hops beyond it (closer
    /// to the actual destination, e.g. `1.1.1.1`) aren't relevant to "the
    /// path to my ISP" and just add noise — so they're hidden. Before
    /// confirmation, the full path still shows, since you need to see hops
    /// beyond the auto-suggested one to pick a different, correct one on
    /// networks where the suggestion doesn't hold (see `suggestedEdgeHop`).
    private var displayedHops: [TracerouteHop] {
        guard let monitoredHopNumber = traceroute.monitoredHopNumber else { return traceroute.hops }
        return traceroute.hops.filter { $0.hopNumber <= monitoredHopNumber }
    }

    private func hopLabel(for hop: TracerouteHop) -> String {
        guard let address = hop.address else { return "* (no response)" }
        return hop.hostname ?? address
    }

    private func hopColor(for hop: TracerouteHop) -> Color {
        if traceroute.monitoredHopNumber == hop.hopNumber {
            return .blue
        }
        switch hop.isLocal {
        case true: return .secondary
        case false: return .primary
        case nil: return .secondary
        }
    }

    private func hopRTT(for hop: TracerouteHop) -> String {
        guard let rtt = hop.roundTripMs else { return "—" }
        return String(format: "%.0f ms", rtt)
    }

    /// Explains why the ISP Edge Router hop shown is only a guess until
    /// confirmed. See `currentPathStatus`'s `suggestedEdgeHop` branch for
    /// why this is a tooltip and not a visible line.
    private static let suggestedEdgeHopHelp = """
        Tap ★ next to the real ISP hop below to confirm — the first \
        non-local hop isn't always right on networks with their own \
        public IP space (e.g. campus/enterprise).
        """
}
