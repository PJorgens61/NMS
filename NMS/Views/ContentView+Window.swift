import SwiftUI

/// Most of `ContentView`'s sections, split out here purely to keep
/// `ContentView.swift` itself from growing back into an unwieldy single
/// file — no longer a popover/window audience split (NMS is a single-
/// window app now; see `NMSApp`), just organization.
///
/// A few members here (`pathAndSpeedRow`, `wifiSection`,
/// `ethernetLinkSection`, `eventList`, `infrastructureList`,
/// `dhcpHistoryList`) are called directly from `ContentView.swift`'s
/// `scrollableContent`. Swift's `private` only covers same-file access
/// even across extensions of the same type, so those six have to be at
/// least `internal` here for that cross-file call to compile. Everything
/// else stays `private` to this
/// file, same encapsulation as before — this file's own members freely
/// call each other privately, same as if it were all one file.
extension ContentView {
    // MARK: - Path to Internet + Speed Test

    /// Fixed to `ContentView.tileHeight`, same as Network Health/Info —
    /// no longer deliberately independent. That independence used to be
    /// load-bearing: syncing this pair's height risked the "Speed Test's
    /// unbounded history forces Path to Internet's box to match it"
    /// failure mode a `LazyVGrid` was rejected for once already. A fixed
    /// height with internal scrolling (`tile(fixedHeight:)`) removes that
    /// risk at the root — Speed Test's history now scrolls *within* its
    /// own fixed box instead of growing it, so there's no longer anything
    /// for Path to Internet to be forced to match.
    ///
    /// Stacked vertically, not side by side — see `ContentView
    /// .scrollableContent`'s doc comment for why the whole four-tile
    /// window grid moved to a single full-width column.
    var pathAndSpeedRow: some View {
        VStack(spacing: 12) {
            tile(title: "Path to Internet", fixedHeight: ContentView.tileHeight, trailing: {
                Button("Trace Now") {
                    traceroute.run()
                }
                .disabled(traceroute.isRunning)
                .accessibilityLabel("Trace Now")
                .accessibilityHint("Runs a traceroute to find the path to the internet")
                .accessibilityIdentifier("pathToInternet.traceNow")
            }) {
                tracerouteSection
            }
            tile(title: "Speed Test", fixedHeight: ContentView.tileHeight, trailing: {
                // `runningSource == .cloudflareEndpoint`, not the
                // shared `isRunning` — so this button only claims
                // "Testing…" when *this* tile's own test is the one
                // running, not whenever Apple networkQuality's tile
                // is. `.disabled(isRunning)` still uses the shared
                // flag: the two tests can't run concurrently either
                // way (see `NetworkQualityViewModel.runningSource`'s
                // doc comment), so this button is inert while the
                // other tile's test is in flight too, just without
                // claiming to be the one doing the work.
                Button(networkQuality.runningSource == .cloudflareEndpoint ? "Testing…" : "Run Speed Test") {
                    networkQuality.run()
                }
                .disabled(networkQuality.isRunning)
                .accessibilityLabel(networkQuality.runningSource == .cloudflareEndpoint ? "Testing" : "Run Speed Test")
                .accessibilityHint("Measures download and upload throughput using Cloudflare's public speed-test endpoint. Uses your data plan, up to roughly 50MB total, less on a slow connection.")
                .accessibilityIdentifier("speedTest.runCloudflare")
            }) {
                speedTestTileContent
            }
            if networkQuality.isAppleTestAvailable {
                // A separate tile from Speed Test — see `PUNCHLIST.md`'s
                // "Give Apple's networkQuality its own tile," raised
                // directly out of concern that a genuinely distinct,
                // interesting result (bufferbloat/responsiveness under
                // load, not just raw Mbps) was easy to miss as a small,
                // secondary button buried inside Speed Test's tile.
                // Titled with the literal binary name, capitalized the
                // way Apple ships it — the "this is a macOS built-in
                // feature, not something NMS invented" connection the
                // punchlist item asked to make explicit.
                tile(title: "Apple networkQuality", fixedHeight: ContentView.tileHeight, trailing: {
                    Button(networkQuality.runningSource == .appleNetworkQuality ? "Testing…" : "Run Test") {
                        networkQuality.runAppleTest(interfaceName: viewModel.currentInterface?.interfaceName)
                    }
                    .disabled(networkQuality.isRunning)
                    .accessibilityLabel(networkQuality.runningSource == .appleNetworkQuality ? "Testing" : "Run Apple networkQuality")
                    .accessibilityHint("Runs Apple's own network quality test: throughput plus responsiveness under load. Uses your data plan and takes about 30 seconds.")
                    .accessibilityIdentifier("appleNetworkQuality.run")
                }) {
                    appleNetworkQualityTileContent
                }
            }
            // Not Wi-Fi-exclusive, despite the underlying idea starting
            // there — the mechanism (repeatedly ping the local router
            // under load) is identical over Ethernet, and a wired
            // connection can have its own real problems (a marginal
            // cable, a flaky switch port) worth exposing the same way.
            // Gated only on a known router address; "Local," not
            // "Wi-Fi," in the title so it doesn't mislead on an
            // Ethernet-connected Mac. See `PUNCHLIST.md`'s "local Wi-Fi
            // stress test" entry for the full mechanism reasoning.
            if let routerAddress = viewModel.currentInterface?.routerAddress {
                let isWiFi = viewModel.currentInterface?.isWiFi == true
                tile(title: "Local Stress Test", fixedHeight: ContentView.tileHeight, trailing: {
                    Button(wifiStressTest.isRunning ? "Testing…" : "Run Test") {
                        if wifiStressTest.hasConfirmedBefore {
                            wifiStressTest.run(routerAddress: routerAddress, isWiFi: isWiFi)
                        } else {
                            isShowingWiFiStressTestConfirmation = true
                        }
                    }
                    .disabled(wifiStressTest.isRunning)
                    .accessibilityLabel(wifiStressTest.isRunning ? "Testing" : "Run Local Stress Test")
                    .accessibilityHint("Fires many concurrent ping streams at the local router for about 1-2 seconds to check for packet loss under load. Generates real network traffic.")
                    .accessibilityIdentifier("wifiStressTest.run")
                    // Attached directly to the button, not hoisted to
                    // `body` — same established local-attachment
                    // pattern `.sheet(isPresented:
                    // $isShowingAppleVerboseOutput)` already uses on
                    // the "View Full Report…" button above.
                    .alert("Run Local Stress Test?", isPresented: $isShowingWiFiStressTestConfirmation) {
                        Button("Continue") {
                            wifiStressTest.markConfirmed()
                            wifiStressTest.run(routerAddress: routerAddress, isWiFi: isWiFi)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will generate real network traffic for about 1-2 seconds — continue?")
                    }
                }) {
                    wifiStressTestTileContent
                }
            }
        }
    }

    /// Path to Internet's full content: current-trace status, then (once
    /// there's a real path) the hop list. Flat content, not its own scroll
    /// box — the outer `tile(fixedHeight:)` call this feeds already wraps
    /// all of it in one `ScrollView` (see `ContentView.tileHeight`),
    /// so a second, inner scroll box here would just nest redundantly.
    @ViewBuilder
    var tracerouteSection: some View {
        currentPathStatus
        if viewModel.currentInterface != nil, !traceroute.hops.isEmpty {
            hopRows
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
                // trace from at all." Same reasoning as Network Health's
                // Network/Local Router/ISP Edge Router rows: this is a
                // certain consequence of the root cause, not something to
                // leave looking like stale-but-plausible data.
                Text("Interface down")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else if let monitored = traceroute.monitoredHop {
                // No summary row here for the monitored hop's name/address —
                // that's already shown in Network Health above (as a response
                // time, not a name) and in the starred row in the hops list
                // below, so a third copy was just a spare line.
                Button("Stop monitoring hop \(monitored.hopNumber)") {
                    traceroute.monitorHop(nil)
                    // Drops the ISP Edge Router ping target on the next round —
                    // check right away instead of leaving Network Health
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

    // MARK: - Speed Test

    /// The "Speed Test" tile's full content: the data-cost note (moved
    /// here from the header once the button moved into the tile's
    /// trailing slot, matching Path to Internet's "Trace Now"), any
    /// error, then the recent-runs list.
    ///
    /// Cloudflare-only now — Apple's `networkQuality` moved to its own
    /// tile (`appleNetworkQualityTileContent`) once it stopped sharing
    /// `isRunning`/`lastError` display state that could belong to either
    /// test (see `NetworkQualityViewModel.runningSource`). `lastError` is
    /// still one shared property underneath — the two tests still can't
    /// run concurrently — but since only one can ever be in flight at a
    /// time, showing it under whichever tile's test actually produced it
    /// is unambiguous in practice, not a display bug waiting to happen.
    @ViewBuilder
    var speedTestTileContent: some View {
        Text("up to ~50MB per run")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        speedTestList
        if let error = networkQuality.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }

    /// Every real Cloudflare-endpoint run, newest first — a genuine time
    /// series (see `NetworkQualityResult`), not a change-log, so unlike
    /// DHCP History every run gets a row regardless of whether the
    /// numbers differ from the last one. Flat content, not its own scroll
    /// box — the outer `tile(fixedHeight:)` call this feeds already wraps
    /// all of `speedTestTileContent` in one `ScrollView` (see
    /// `ContentView.tileHeight`), so a second, inner box here would just
    /// nest redundantly.
    @ViewBuilder
    private var speedTestList: some View {
        if networkQuality.cloudflareRuns.isEmpty {
            Text(networkQuality.runningSource == .cloudflareEndpoint ? "Testing…" : "No speed test run yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            speedTestRows
        }
    }

    /// One line per run: "750 Mbps down, 550 Mbps up" plus a time-only
    /// (no date) timestamp. Spelled-out "down"/"up" rather than ↓/↑
    /// arrows — raised directly, for the same non-technical-user
    /// audience `appleQualityDetail` is written for: an arrow glyph asks
    /// a reader to decide what it means (direction of data flow? a
    /// trend, like a stock ticker?) where a plain word doesn't. Every row
    /// here is Cloudflare-sourced by construction (`cloudflareRuns`), so
    /// unlike before the tile split there's no per-row source check
    /// needed — this list never has an Apple-sourced RPM/latency line to
    /// decide whether to show.
    private var speedTestRows: some View {
        ForEach(networkQuality.cloudflareRuns) { run in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(Self.throughputText(run))
                    Spacer()
                    Text(run.testedAt, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                if let dataUsed = Self.dataUsedText(run) {
                    Text(dataUsed)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Only ever called on `cloudflareRuns`/`appleRuns` — both filtered
    /// to a specific `source`, never `.quickCheck` — so `downloadMbps`/
    /// `uploadMbps` being `nil` here would mean that invariant broke,
    /// not a real case to render text for. The fallback is defensive,
    /// not expected to show live.
    private static func throughputText(_ run: NetworkQualityRecord) -> String {
        guard let downloadMbps = run.downloadMbps, let uploadMbps = run.uploadMbps else { return "—" }
        return String(format: "%.0f Mbps down, %.0f Mbps up", downloadMbps, uploadMbps)
    }

    /// Real data used, not an estimate — `NetworkQualityRecord
    /// .downloadBytesTransferred`/`uploadBytesTransferred`'s own doc
    /// comment for why this is exact for both sources, not just Apple's.
    /// Raised directly: showing this per run lets someone judge whether
    /// to run the test again on a metered or limited connection, rather
    /// than guessing from a fixed "~50MB per run"/"~30s" estimate that
    /// doesn't reflect what any specific run actually cost. `nil` only
    /// for a row persisted before this existed — matches
    /// `NetworkQualityRecord`'s own safe-migration shape, not expected
    /// for any run going forward.
    private static func dataUsedText(_ run: NetworkQualityRecord) -> String? {
        guard let down = run.downloadBytesTransferred, let up = run.uploadBytesTransferred else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        let downText = formatter.string(fromByteCount: Int64(down))
        let upText = formatter.string(fromByteCount: Int64(up))
        return "\(downText) down, \(upText) up"
    }

    // MARK: - Apple networkQuality

    /// The "Apple networkQuality" tile's full content — same shape as
    /// `speedTestTileContent`, split out alongside it. See
    /// `PUNCHLIST.md`'s "Give Apple's networkQuality its own tile."
    @ViewBuilder
    var appleNetworkQualityTileContent: some View {
        // "~30s" alone understated this badly — confirmed live via
        // `networkQuality`'s own real byte counts (`dl_bytes_transferred`/
        // `ul_bytes_transferred`, undocumented in the man page but present
        // in every real run): 1-2GB *per direction* on a fast connection,
        // not a rounding error against the Cloudflare test's ~50MB. The
        // test moves as much data as the link can carry in its measurement
        // window (see DESIGN-NOTES.md's "Network Quality" section on why
        // it's time-limited, not data-limited) — the faster the
        // connection, the more it actually costs, which is the opposite
        // of what "~30s" implies. Each completed run shows its own exact
        // figure below (`dataUsedText`); this is the honest heads-up
        // before that first run exists.
        Text("uses your data plan — often 1+ GB on a fast connection, ~30s")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        // Explains RPM's own convention up front, rather than avoiding
        // the term — raised directly, in two parts. First: real
        // confusion reported ("RPMs confused me at first"). Second, the
        // more important correction on top of that: RPM's "higher is
        // better" convention isn't an accident to work around, it's the
        // whole reason RPM exists as its own metric rather than just
        // reporting a latency number — "non-technical users didn't
        // understand latency," and a bigger-is-better number (the same
        // intuition Mbps already trains) reads more clearly to a casual
        // user than "lower is better" ever did. So this doesn't convert
        // RPM into a derived ms figure (tried once, reverted) — it
        // states the convention in words instead, right where a reader
        // will meet the number itself.
        Text("Higher RPM means a more responsive connection under load.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        appleQualityList
        if let error = networkQuality.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
        // Only once a run exists to show — raised directly, for an expert
        // who wants Apple's own full `-v` report rather than this tile's
        // summary. Plain-styled, secondary: same "one first-class action
        // per tile" reasoning `speedTestTileContent`'s now-removed inline
        // Apple button used to follow, just applied to this button
        // instead of a second test trigger.
        if let verboseOutput = networkQuality.latestAppleVerboseOutput, !verboseOutput.isEmpty {
            Button("View Full Report…") {
                isShowingAppleVerboseOutput = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(Color.accentColor)
            .accessibilityHint("Shows Apple's own full networkQuality verbose report for the most recent run")
            .accessibilityIdentifier("appleNetworkQuality.viewFullReport")
            .sheet(isPresented: $isShowingAppleVerboseOutput) {
                AppleNetworkQualityVerboseView(text: verboseOutput)
            }
        }
    }

    /// Every real Apple `networkQuality` run, newest first — see
    /// `speedTestList`'s doc comment for why this doesn't need its own
    /// scroll box either.
    @ViewBuilder
    private var appleQualityList: some View {
        if networkQuality.appleRuns.isEmpty {
            Text(networkQuality.runningSource == .appleNetworkQuality ? "Testing…" : "No test run yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            appleQualityRows
        }
    }

    /// Same throughput/timestamp line `speedTestRows` shows, plus a
    /// second line every row here always has: RPM under load, split by
    /// direction — the signal this whole second source exists for — and
    /// idle base latency, the one other figure `networkQuality` measures
    /// that Cloudflare's plain file transfer has no equivalent of.
    /// Unconditional now (no per-row source check) since every row here
    /// is Apple-sourced by construction (`appleRuns`).
    ///
    /// Built as separate `Text`s in an `HStack`, not one interpolated
    /// string — `.help(_:)` attaches to a specific view, and `Text`
    /// concatenation (`+`) merges into a single `Text` with no per-segment
    /// view identity to attach to, so reaching `rpmThresholdHelp` onto
    /// just the RPM figures (not the idle-latency figure beside them)
    /// needs each to stay its own view.
    private var appleQualityRows: some View {
        ForEach(networkQuality.appleRuns) { run in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(Self.throughputText(run))
                    Spacer()
                    Text(run.testedAt, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                HStack(spacing: 4) {
                    if let dl = run.downloadResponsivenessRPM, let ul = run.uploadResponsivenessRPM {
                        // RPM leads, spelled out with "down"/"up" rather
                        // than ↓/↑ arrows (see `speedTestRows`'s doc
                        // comment for the arrows-vs-words reasoning) —
                        // kept as the actual published metric rather than
                        // converted to a derived latency figure, per
                        // `appleNetworkQualityTileContent`'s own doc
                        // comment on why RPM's convention is explained in
                        // words instead of avoided. No "Apple" prefix on
                        // the string itself (unlike before the tile
                        // split): the tile title already says "Apple
                        // networkQuality," so repeating it on every row
                        // would be redundant.
                        //
                        // Two dots, not one merged verdict — raised
                        // directly: this tile is specifically for a
                        // reader who wants the per-direction detail a
                        // single "worst of the two" dot would erase (a
                        // real bufferbloat problem in only one direction
                        // is a genuinely different diagnosis than one in
                        // both). The popover's quick check collapses to
                        // one dot on purpose, for the opposite audience.
                        Circle()
                            .fill(Self.statusColor(forRPM: dl))
                            .frame(width: 6, height: 6)
                            .help(Self.rpmThresholdHelp)
                        Text("\(dl) RPM down")
                        Circle()
                            .fill(Self.statusColor(forRPM: ul))
                            .frame(width: 6, height: 6)
                            .help(Self.rpmThresholdHelp)
                        Text("\(ul) RPM up")
                        if run.baseRTTMs != nil {
                            Text("·")
                        }
                    }
                    // Idle base latency — a real reported figure, not
                    // derived — stays alongside RPM as a separate
                    // reference point, not folded into the same number.
                    if let rtt = run.baseRTTMs {
                        Text(String(format: "%.0fms idle latency", rtt))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                // Its own line, not folded into the RPM/latency line
                // above — a distinct concern (data cost, not connection
                // quality). See `dataUsedText`'s own doc comment for why
                // this is exact, not a guess — genuinely important here
                // specifically: confirmed live, a single run can use
                // 1-2GB per direction, far more than "uses your data
                // plan, ~30s" alone conveys.
                if let dataUsed = Self.dataUsedText(run) {
                    Text(dataUsed)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Rough reference points for "is this RPM number good or bad,"
    /// raised directly after explaining RPM's own higher-is-better
    /// convention still left "is 620 good?" unanswered. Sourced from how
    /// Apple's own tool is characterized in independent write-ups (not
    /// invented here) — see `DESIGN-NOTES.md`'s "Network Quality" section
    /// for the man-page-level description this supplements. Deliberately
    /// a tooltip, not a permanent caption: this is reference detail for
    /// someone who already sees a number and wants to know if it's good,
    /// not the first-contact explanation (`appleNetworkQualityTileContent`
    /// covers that with a permanent line instead) — a hover tooltip is
    /// the right tool for "more depth, not everyone needs it" versus
    /// "everyone should see this once."
    // Not `private` — reused by `ContentView.swift`'s quick-check dot
    // (`quickCheckGridRow`) so both give the same colored verdict the
    // same explanation. Swift's `private` doesn't cross files even
    // between extensions of the same type.
    static let rpmThresholdHelp = """
        RPM (round trips per minute) measures responsiveness under load — \
        higher is better. Roughly: above 2000 is excellent, under 800 \
        suggests bufferbloat.
        """

    // MARK: - Local Stress Test

    /// The "Local Stress Test" tile's full content — same shape as
    /// `speedTestTileContent`/`appleNetworkQualityTileContent`. Packet
    /// loss is the headline line (the primary metric — see
    /// `PUNCHLIST.md`'s "local Wi-Fi stress test" entry), RTT
    /// min/avg/max/stddev and this Mac's own CPU load during the burst
    /// (see `CPULoadSampler`) are smaller supporting lines underneath.
    @ViewBuilder
    var wifiStressTestTileContent: some View {
        Text("many concurrent MTU-sized pings, ~1-2s, real traffic")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        wifiStressTestList
        if let error = wifiStressTest.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }

    /// Every run, newest first — a genuine time series, not deduplicated
    /// against the previous one, same reasoning as `speedTestList`. Flat
    /// content, not its own scroll box — the outer `tile(fixedHeight:)`
    /// call already wraps all of `wifiStressTestTileContent` in one
    /// `ScrollView`.
    @ViewBuilder
    private var wifiStressTestList: some View {
        if wifiStressTest.recentRuns.isEmpty {
            Text(wifiStressTest.isRunning ? "Testing…" : "No stress test run yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            ForEach(wifiStressTest.recentRuns) { run in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(String(format: "%.1f%% loss", run.packetLossPercent))
                            .foregroundStyle(run.packetLossPercent > 0 ? .red : .primary)
                        Spacer()
                        Text(run.testedAt, format: .dateTime.hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    if let min = run.minRTTMs, let avg = run.avgRTTMs, let max = run.maxRTTMs, let stddev = run.stddevRTTMs {
                        Text(String(format: "%.1f/%.1f/%.1f/%.1f ms (min/avg/max/stddev)", min, avg, max, stddev))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if let peakCPU = run.peakCPUPercent, let avgCPU = run.avgCPUPercent {
                        Text(String(format: "CPU %.0f%% avg, %.0f%% peak · %d streams", avgCPU, peakCPU, run.streamCount))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    // Attempted send rate, not received -- "how hard did
                    // this run actually drive the link," the figure
                    // worth watching live on a field test to judge
                    // whether a run pushed enough load to be meaningful
                    // on the network in front of it. See
                    // `WiFiStressTestAggregator.aggregate`'s own comment.
                    Text(String(format: "%.0f pkt/s · %.1f Mbps attempted", run.packetsPerSecond, run.megabitsPerSecond))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Wi-Fi

    /// Current signal/link characteristics — window-only. Boxed and
    /// scrolling like every other window section, via `scrollBox`; see
    /// `SectionLayout.boxHeight`'s doc comment for why this and
    /// `saasMonitoringSection` stopped being the two exceptions.
    @ViewBuilder
    var wifiSection: some View {
        // Moved from Info — see that section's call site for the
        // discoverability tradeoff. Shown first, before Signal: it
        // identifies *which* access point, which is the natural thing to
        // read before that AP's own signal/link characteristics below —
        // same ordering Info used to have (right after Network).
        if let bssid = wifiSSID.currentBSSID {
            row("BSSID", bssid)
        }
        // Not the plain `row(_:_:)` helper, so the sparkline can sit
        // inline between label and value — same layout Network Health's
        // per-layer rows already use for their own sparklines.
        HStack {
            Text("Signal")
                .foregroundStyle(.secondary)
            Spacer()
            if wifiSSID.recentSamples.count > 1 {
                Sparkline(values: wifiSSID.recentSamples.reversed().map { $0.rssi.map(Double.init) })
            }
            Text(wifiSignalDetail)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        row("Channel", wifiChannelDetail)
        if let rate = wifiSSID.currentPHYRateMbps {
            row("PHY Rate", "\(Int(rate)) Mbps")
        }
        if let security = wifiSSID.currentSecurity {
            row("Security", security)
        }
    }

    /// RSSI plus its trend, with an SNR parenthetical when noise is also
    /// available — "-52 dBm (SNR 38 dB)". Noise isn't always reported (some
    /// adapters/driver states omit it), so the SNR half is conditional
    /// rather than showing a misleading partial calculation.
    private var wifiSignalDetail: String {
        guard let rssi = wifiSSID.currentRSSI else { return "—" }
        if let noise = wifiSSID.currentNoise {
            return "\(rssi) dBm (SNR \(rssi - noise) dB)"
        }
        return "\(rssi) dBm"
    }

    private var wifiChannelDetail: String {
        guard let number = wifiSSID.currentChannelNumber else { return "—" }
        guard let band = wifiSSID.currentChannelBand else { return "\(number)" }
        return "\(number) (\(band))"
    }

    /// Ethernet's counterpart to `wifiSection` — window-only, boxed the
    /// same way via `tile()`. Just two rows: no signal to chart, no
    /// BSSID/channel/security the way a Wi-Fi radio has, since a wired
    /// link has none of those concepts.
    @ViewBuilder
    var ethernetLinkSection: some View {
        if let speed = ethernetLink.currentSpeedMbps {
            row("Speed", "\(Int(speed)) Mbps")
        }
        if let duplex = ethernetLink.currentDuplex {
            row("Duplex", duplex)
        }
    }

    // MARK: - Events

    @ViewBuilder
    var eventList: some View {
        if eventLog.events.isEmpty {
            // Explains *why* it's empty rather than just stating that it
            // is — a bare "No events yet" on a fresh install (with a
            // perfectly healthy network) reads as "is this broken?" to a
            // new user. Deliberately not backfilled with synthetic
            // "everything came up fine" events instead: this log is meant
            // to be a trustworthy record of things that actually
            // happened, and fabricated entries at install would be
            // indistinguishable from real ones later.
            Text("No events yet — everything's healthy. Entries appear here when something changes (an outage or a recovery).")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            eventRows
        }
    }

    private var eventRows: some View {
        ForEach(eventLog.events) { event in
            // `.top`, not the default `.center` — once `message` can wrap
            // to more than one line, centering would float the timestamp/
            // link partway down a tall row instead of pinning it level
            // with the message's first line.
            HStack(alignment: .top) {
                // No `lineLimit`/`truncationMode` — Events moved
                // window-only in the audience split, so it no longer
                // shares the popover's precise 17pt/row height budget
                // this row's single-line truncation used to protect (see
                // `PUNCHLIST.md`'s "DHCP tile → Events as a multi-line
                // message"). The window's Events box (`SectionLayout
                // .events`) is already a generous, independently
                // scrolling 350pt area, so a long message just wraps and
                // takes more of that scroll, the same way any other
                // section's overflow already works — requested directly
                // after a long message got cut off illegibly.
                // `fixedSize` forces the wrap to actually happen instead
                // of `Text` compressing to fit the `HStack`'s available
                // width the way a flexible sibling next to `Spacer()`
                // normally would.
                Text(event.message)
                    .font(.system(size: 12))
                    .foregroundStyle(eventColor(for: event))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                // Requested directly, after noticing a SaaS outage row's
                // URL was there but unusable — baked into `message` as
                // trailing text that `lineLimit(1)`/`truncationMode(.middle)`
                // above routinely cuts off. `AppEventRecord.url` carries
                // it as a real field now; only `.saasServiceDown` sets one
                // today, so this is absent for every other event kind.
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

    private func eventColor(for event: AppEventRecord) -> Color {
        guard let kind = AppEventKind(rawValue: event.kind) else { return .primary }
        switch kind.polarity {
        case .positive: return .green
        case .negative: return .red
        case .neutral: return .primary
        }
    }

    // MARK: - SNMP Devices

    /// SNMP-discovered infrastructure: each row is name + software
    /// descriptor + uptime, since those are what identify the device and
    /// reveal a restart. The leading dot is live reachability (see
    /// `deviceReachability`) — added because a device that restarted and
    /// already recovered could otherwise only be told apart from one that's
    /// still down by reading Events log ordering, which can itself lag (the
    /// slower SNMP-restart detection can log *after* the ping-based
    /// recovery for the same episode). This dot answers "is it up right
    /// now" directly instead.
    @ViewBuilder
    var infrastructureList: some View {
        if !snmp.isAvailable {
            Text("snmpget unavailable on this macOS version")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if snmp.devices.isEmpty {
            Text(snmp.isScanning ? "Sweeping subnet…" : (snmp.lastScanAt == nil ? "Not scanned yet" : "No SNMP devices found"))
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            infrastructureRows
        }

        if let error = snmp.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }

        communityRow
    }

    private var infrastructureRows: some View {
        ForEach(snmp.devices) { device in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Circle()
                        .fill(deviceStatusColor(deviceReachability(device)))
                        .frame(width: 8, height: 8)
                        // Gray is the case this exists for: it means
                        // "no ping result yet," which looks identical to
                        // trouble at a glance and gets misread exactly
                        // when someone is scanning this list during an
                        // outage.
                        .help(Self.reachabilityHelp(deviceReachability(device)))
                    Text(device.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(device.uptimeDescription)
                        .foregroundStyle(.secondary)
                    // After the text, not before — `uptimeDescription`'s
                    // width varies per device ("up 41d 4h" vs "up 4d 0h"),
                    // and this HStack's trailing group is flush-right, so
                    // an icon placed *before* varying-width text shifts
                    // horizontally row to row. Trailing-most keeps it at a
                    // constant position, matching the SaaS section's own
                    // (already correct) icon-after-text order.
                    if let webURL = device.webURL {
                        externalLinkIcon(
                            url: webURL,
                            accessibilityLabel: "\(device.displayName) admin page",
                            accessibilityHint: "Opens \(device.displayName)'s web interface in your browser"
                        )
                    }
                }
                .font(.system(size: 12))
                // No lineLimit here, deliberately — sysDescr (a raw
                // SNMP-provided string, no length guarantee) wraps to as
                // many lines as it needs instead of truncating, unlike
                // the single-line convention used elsewhere in this
                // popover.
                // Always shown, not just when there's more than one
                // address — requested directly ("list the domain name
                // and IP address for each... useful for network
                // engineers"): `displayName` above is often just
                // `sysName`, a short SNMP-configured label ("router"),
                // not the device's actual DNS identity or IP.
                Text(device.addressLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // `aliasAddresses` non-empty means this identity answers
                // at more than one address on the same MAC -- see
                // `SNMPDevice.aliasAddresses`'s own doc comment, which
                // already names VRRP as the case this exists for.
                // "Suspected," not a certainty: ARP evidence alone can't
                // distinguish a VRRP virtual address from other
                // shared-MAC shapes (a router trunking several VLANs,
                // say), so this is a hint pointing at the addresses just
                // shown above, not an assertion.
                if !device.aliasAddresses.isEmpty {
                    Text("VRRP suspected")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                }
                // Split into up to two *fixed-height* lines rather than
                // one auto-wrapping `Text` — deliberately, not the
                // obvious approach. sysDescr is a raw SNMP-provided
                // string with no length guarantee, and a real one
                // (this network's own switch) needs two lines to read in
                // full. An unbounded, wrapping `Text` here reliably
                // truncated to one line with a "…" live, inside this
                // section's `ScrollView` box specifically
                // (confirmed fine in a plain `VStack`) — and every fix
                // tried for *that* (`.fixedSize(vertical: true)` alone,
                // on the whole row, combined with `NSHostingView
                // .sizingOptions`) reliably reintroduced a worse bug
                // instead: this list's first row (`router`) rendering
                // permanently clipped a few points from its own top. See
                // `BUGS.md`'s "SNMP device sysDescr truncates" entry for
                // the full account. Two separate `Text`s, each with its
                // own `lineLimit(1)`, sidesteps that whole class of bug
                // entirely — the same deterministic, single-line sizing
                // `addressLine` above already uses safely in this exact
                // box, just applied twice. Worst case (a single word too
                // long for one line, or a description needing a third
                // line) still degrades to a plain "…", same as before —
                // never worse, often better.
                ForEach(Array(Self.sysDescrLines(device.sysDescr).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// Splits `sysDescr` into at most two lines, breaking at the space
    /// nearest the midpoint so neither line is wildly longer than the
    /// other. Short strings (the common case — most devices' `sysDescr`
    /// fits on one line already) come back unsplit: this only kicks in
    /// past a length that's already overflowing one line at this row's
    /// font/width, mirroring the two lines this exact box's own
    /// `sysDescr` case needs (see the call site's doc comment for why
    /// this exists instead of a wrapping `Text`).
    // Not `private` — `@testable import NMS` in NMSTests.swift can only
    // reach `internal`, same reason `SaaSStatusService`'s parsers and
    // `NMSApp.openStoreWithFallback` are also plain `static func`.
    static func sysDescrLines(_ text: String) -> [String] {
        guard text.count > 70 else { return [text] }
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        var breakIndex: String.Index?
        var offset = 0
        while breakIndex == nil, offset < text.count / 2 {
            if let before = text.index(mid, offsetBy: -offset, limitedBy: text.startIndex),
               text[before] == " " {
                breakIndex = before
            } else if let after = text.index(mid, offsetBy: offset, limitedBy: text.endIndex),
                      after < text.endIndex, text[after] == " " {
                breakIndex = after
            }
            offset += 1
        }
        guard let breakIndex else { return [text] }
        let first = text[text.startIndex..<breakIndex].trimmingCharacters(in: .whitespaces)
        let second = text[breakIndex...].trimmingCharacters(in: .whitespaces)
        return [first, second]
    }

    private func deviceReachability(_ device: SNMPDevice) -> LayerStatus {
        let label = device.ipAddress == viewModel.currentInterface?.routerAddress
            ? OverallStatus.routerLabel
            : device.displayName
        guard let check = connectivity.checks.first(where: { $0.label == label }) else {
            return .unknown
        }
        return check.success ? .healthy : .unhealthy
    }

    /// Only the `.unknown` case really needs explaining — green and red
    /// read themselves — but all three are worded so hovering any dot
    /// answers the same question rather than leaving one silent.
    private static func reachabilityHelp(_ status: LayerStatus) -> String {
        switch status {
        case .healthy:
            return "Reachable — answered the most recent ping."
        case .unhealthy:
            return "Unreachable — did not answer the most recent ping."
        case .unknown:
            return """
                Not checked yet — this device has no ping result in the \
                current round, which is not the same as being down. The \
                router is checked under its own Network Health row, and \
                only the first few discovered devices are pinged each \
                round.
                """
        }
    }

    private func deviceStatusColor(_ status: LayerStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .unknown: return .gray
        case .unhealthy: return .red
        }
    }

    /// Community strings are shared read-only passwords, not per-user
    /// secrets, and "public" is the near-universal default — so they're
    /// editable inline rather than hidden behind a settings window this app
    /// doesn't have. Comma-separated, and the order shown is the order
    /// they're tried in.
    @ViewBuilder
    private var communityRow: some View {
        if isEditingCommunity {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    TextField("public, private", text: $communityDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { commitCommunity() }
                    Button("Set") { commitCommunity() }
                        .accessibilityLabel("Set community strings")
                        .accessibilityIdentifier("snmpDevices.setCommunity")
                        .font(.system(size: 11))
                }
                Text("Comma-separated, tried in order — put the most common first.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        } else if snmp.isAvailable {
            HStack {
                Text("Community: \(snmp.communities.joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change") {
                    communityDraft = snmp.communities.joined(separator: ", ")
                    isEditingCommunity = true
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Change community strings")
                .accessibilityHint("Edits the SNMP community strings used for discovery")
                .accessibilityIdentifier("snmpDevices.changeCommunity")
            }
        }
    }

    private func commitCommunity() {
        snmp.setCommunities(communityDraft)
        isEditingCommunity = false
    }

    // MARK: - DHCP History

    /// Every real DHCP lease change (server, address, or timing actually
    /// differed — see `SnapshotStore.recordDHCPLeaseIfChanged`), newest
    /// first — new rows appear at the top and push earlier ones down into
    /// the scroll. The newest row doubles as "the current lease" — there's
    /// no separate current-lease display now that this list exists.
    /// Two lines per lease, every parsed field included across the two
    /// (see `dhcpPrimaryDetail`/`dhcpSecondaryDetail`) — a single
    /// unbroken line was tried first, but the full field set (server,
    /// address, broadcast, gateway, DNS, domain, lease/T1/T2, transaction
    /// ID) measured out to roughly 950-1000pt to fit without truncating,
    /// confirmed directly against a real lease — too wide for a menu-bar
    /// popover. Wrapping to two lines fits comfortably at this popover's
    /// current (doubled) width instead.
    @ViewBuilder
    var dhcpHistoryList: some View {
        if !DHCPLeaseService.isAvailable {
            Text("ipconfig unavailable on this macOS version")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if dhcpLease.history.isEmpty {
            Text("No DHCP lease observed yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            // Row spacing tightens from scrollBox's old 4pt to tile()'s
            // fixed 2pt (not configurable) -- acceptable, and now
            // consistent with every other tile's row spacing too.
            dhcpHistoryRows
        }
    }

    private var dhcpHistoryRows: some View {
        ForEach(dhcpLease.history) { record in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(record.primaryDetail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(record.observedAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                Text(record.secondaryDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The densest jargon in the app, and the reason
                    // tooltips were built at all. Explains only the
                    // genuinely opaque parts — bcast/gw/dns need no
                    // gloss for this app's audience, while T1/T2 and a
                    // bare hex transaction ID do.
                    .help(DHCPLeaseRecord.transactionHelpText)
            }
        }
    }


    // MARK: - SaaS Monitoring

    /// Business SaaS status — window-only. Boxed and scrolling like every
    /// other window section, via `scrollBox` — a user-configurable list
    /// (`PreferencesView`'s service picker) isn't reliably short once
    /// users can add their own sites to monitor (see `PUNCHLIST.md`). See
    /// `SaaSMonitoringViewModel` and DESIGN-NOTES.md's "Business SaaS
    /// monitoring".
    // Not `private` — called from `ContentView.swift`'s `scrollableContent`.
    @ViewBuilder
    var saasMonitoringSection: some View {
        ForEach(saasMonitoring.statuses) { status in
            saasStatusRow(status)
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
                saasStatusRow(status)
            }
        }
    }

    /// One row, shared by the curated list and the user-added list above
    /// — same visual shape (dot, name, description, link), so the only
    /// thing distinguishing "weaker signal" is the section label, not a
    /// second row style to keep in sync with the first.
    private func saasStatusRow(_ status: SaaSMonitoringViewModel.ServiceStatus) -> some View {
        HStack {
            Circle()
                .fill(saasIndicatorColor(status.indicator))
                .frame(width: 8, height: 8)
            Text(status.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(status.description)
                .foregroundStyle(status.indicator == .none ? Color.secondary : saasIndicatorColor(status.indicator))
                .lineLimit(1)
                .truncationMode(.middle)
            // Always present — `status.url` is always a real link
            // (the specific incident when there is one, the general
            // status page otherwise, see `SaaSStatusService
            // .CheckResult.url`), so "go check for yourself" is one
            // click away regardless of current health. A dedicated
            // icon button rather than making the description itself
            // look clickable — this app's first-ever use of `Link`,
            // now shared via `externalLinkIcon` (`ContentView.swift`).
            externalLinkIcon(
                url: status.url,
                accessibilityLabel: "\(status.name) status page",
                accessibilityHint: "Opens \(status.name)'s status page in your browser"
            )
        }
        .font(.system(size: 12))
        // Same `.contain`-not-`.combine` reasoning as `layerGridRow`'s own
        // rows — keeps this row's status-page link individually reachable
        // while still exposing one frame for `reportFrameForFieldTest`.
        // Caveat: `status.name` isn't guaranteed unique across the curated
        // and user-added SaaS lists (`ContentView.swift`'s
        // `saasMonitoring.statuses`/`.userAddedStatuses`) — a collision
        // would give two on-screen rows the same identifier. Not a problem
        // for anything reading this today; worth knowing before relying on
        // uniqueness elsewhere.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saasStatus.row.\(status.name)")
        .reportFrameForFieldTest("saasStatus.row.\(status.name)")
    }

    private func saasIndicatorColor(_ indicator: SaaSStatusService.Indicator) -> Color {
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
