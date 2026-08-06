import SwiftUI

/// The "Path to Internet" tile: current-trace status, then (once there's
/// a real path) the hop list.
///
/// Sixth of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry) — reads three view models: `traceroute` for the
/// hop list itself, `viewModel` for the "is there even an interface"
/// gate, `connectivity` only to trigger a fresh check when the monitored
/// hop changes.
struct PathToInternetTile: View {
    var traceroute: TracerouteViewModel
    var viewModel: NetworkMonitorViewModel
    var connectivity: ConnectivityViewModel

    var body: some View {
        tile(title: "Path to Internet", fixedHeight: ContentView.tileHeight, trailing: {
            Button("Trace Now") {
                traceroute.run()
            }
            .disabled(traceroute.isRunning)
            .accessibilityLabel("Trace Now")
            .accessibilityHint("Runs a traceroute to find the path to the internet")
            .accessibilityIdentifier("pathToInternet.traceNow")
            .help("Runs a traceroute to find the path to the internet")
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
            .help("Stops treating this hop as the ISP edge router")
            #if DEBUG
            // External, independent confirmation from Path Discovery
            // (Debug Tools window) — occasional, on-demand data, shown
            // as context alongside the live outbound trace above, never
            // replacing it. Raised directly ("the info collected should
            // inform the path to internet function").
            if let corroboration = traceroute.externalCorroboration {
                pathDiscoverySummary(corroboration)
            }
            #endif
            if traceroute.accessCircuitReachable == true {
                accessCircuitSummary
            }
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
                #if DEBUG
                // Not a re-check of the CGNAT classification itself —
                // just surfaces, on hover, whether the confirmed edge
                // hop this NAT reading is based on has any external
                // corroboration on record. See `pathDiscoverySummary`'s
                // own doc comment for the same "context, not a new
                // detector" framing.
                .help(optional: traceroute.externalCorroboration.map { corroboration in
                    "The confirmed ISP edge hop below has \(corroboration.corroboratingCount > 0 ? "been" : "not been") externally corroborated via Path Discovery (\(corroboration.corroboratingCount)/\(corroboration.probeCount) probes)."
                })
                #endif
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

    #if DEBUG
    /// Context, not a new detector — corroborates *that the confirmed
    /// edge hop is real, externally-visible infrastructure*, which lends
    /// confidence to whatever this tile already concluded about it (the
    /// PE identity, the NAT-layer reading above), without itself
    /// re-checking the CGNAT classification specifically. Reverse-trace
    /// data is external, occasional, and not guaranteed to reflect the
    /// same path the live outbound trace takes (asymmetric routing) —
    /// worded as corroboration, never as a replacement fact.
    @ViewBuilder
    private func pathDiscoverySummary(_ corroboration: (probeCount: Int, corroboratingCount: Int, corroboratedAt: Date?)) -> some View {
        let text = "Path Discovery: \(corroboration.corroboratingCount)/\(corroboration.probeCount) external probe\(corroboration.probeCount == 1 ? "" : "s") confirmed this hop"
            + (corroboration.corroboratedAt.map { " (last \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? "")
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .help(tooltip(
                "Whether external vantage points, reached via Path Discovery (Debug Tools window), independently saw this same hop as the last one before reaching this Mac. A low or zero count doesn't mean this hop is wrong — it often just means this router replies from a different address than the one seen from outside.",
                technical: "Matches by exact IP address only, so it can under-count: a router commonly exposes a different address on its management/loopback interface than on the physical interface actually carrying traffic, and this can't tell those two addresses belong to the same device (that's alias resolution, a harder, unimplemented problem — see PUNCHLIST.md). Uses Globalping's public probe network, and only reflects whenever Path Discovery last ran, not a live, continuous check the way the trace above is."
            ))
    }
    #endif

    /// Supplementary to the confirmed-hop row above, never a replacement
    /// for it — see `TracerouteViewModel.accessCircuitReachable`'s own
    /// doc comment for the full reasoning (a residential ISP's edge
    /// alternating between two real routers is the motivating case).
    /// Only ever rendered when `true`; `nil`/not-yet-checked shows
    /// nothing at all, matching the property's own "only ever asserts
    /// up" design — there's no "down" state to render here.
    private var accessCircuitSummary: some View {
        Text("Access Circuit: reachable")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .help(tooltip(
                "A broader, supplementary check: pings a few hops near your ISP's edge, not just the one confirmed above. Green here means at least one of them answered recently, which is real evidence your access circuit is up — even if the specific confirmed hop's own address happens to be the quiet one right now.",
                technical: "Checks TracerouteViewModel.accessCircuitCandidateAddresses (up to 3 hops past your router, by position, refreshed on the same 10-minute discovery cadence as the hop list) on ConnectivityViewModel's normal fast check cadence. Deliberately one-directional: any response sets this to reachable, but it never resets to a \"not reachable\" state on its own, since ICMP silence from a few hops doesn't safely prove the circuit is down."
            ))
    }

    private var hopRows: some View {
        ForEach(displayedHops) { hop in
            HStack {
                Text("\(hop.hopNumber)")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
                Text(hopLabel(for: hop))
                    .foregroundStyle(hopColor(for: hop))
                    // Blue here already meant "this is your confirmed
                    // ISP edge router hop" before any tooltip existed —
                    // real, independent selection-state, not just a
                    // hover hint (unlike VRRP suspected's blue, which
                    // had no other meaning). So only the underline is
                    // gated by `FeatureFlags.tooltipHighlights`; the
                    // color itself stays regardless, since it must
                    // survive with the flag off. Raised directly ("the
                    // selected path to internet is already BLUE... it
                    // needs a tooltip also").
                    .underline(traceroute.monitoredHopNumber == hop.hopNumber && FeatureFlags.tooltipHighlights)
                    .help(optional:
                        traceroute.monitoredHopNumber == hop.hopNumber
                            ? "Confirmed as your ISP's edge router — pinged directly to track its health, separate from the rest of the path."
                            : nil
                    )
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
                .help(
                    traceroute.monitoredHopNumber == hop.hopNumber
                        ? "Monitored ISP edge router, hop \(hop.hopNumber)"
                        : "Monitor hop \(hop.hopNumber) as ISP edge router"
                )
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
