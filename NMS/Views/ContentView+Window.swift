import SwiftUI

/// Every section that only ever renders in the comparison window —
/// `SectionLayout.surfaces` returns `[.window]` for all of these as of
/// the audience split, so on the popover none of this file contributes
/// anything at all.
///
/// Split out from `ContentView.swift` for the same reason `SectionLayout`
/// exists: since the audience split, Network Health and Info are the
/// *only* content the popover and window still share — everything below
/// used to sit in the same 1874-line file behind `if SectionLayout.X
/// .appears(on: surface)` checks that are permanently `false` on the
/// popover, which meant reading that file to understand "what does the
/// popover actually show" meant first mentally filtering out most of it.
/// One type, one set of view models (no duplication, no risk of the two
/// surfaces' `tile()`/`scrollBox()` usage drifting apart) — just the
/// window-only implementation physically separated from the always-shared
/// core, the same decoupling `SectionLayout` already does for layout data.
///
/// A few members here (`pathAndSpeedRow`, `wifiSection`, `eventList`,
/// `infrastructureList`, `dhcpHistoryList`, `printerAlertsList`) are
/// called directly from `ContentView.swift`'s `scrollableContent`. Swift's
/// `private` only covers same-file access even across extensions of the
/// same type, so those six have to be at least `internal` here for that
/// cross-file call to compile. Everything else stays `private` to this
/// file, same encapsulation as before — this file's own members freely
/// call each other privately, same as if it were all one file.
extension ContentView {
    // MARK: - Path to Internet + Speed Test

    /// The tile-grid's second row. Both tiles are window-only and always
    /// appear together (`SectionLayout.pathToInternet`/`.speedTest` are
    /// both `[.window]`), so there's no partial-row case — on the popover
    /// this whole `HStack` is simply never called.
    ///
    /// Fixed to `ContentView.tileHeight`, same as Network Health/Info —
    /// no longer deliberately independent. That independence used to be
    /// load-bearing: syncing this pair's height risked the "Speed Test's
    /// unbounded history forces Path to Internet's box to match it"
    /// failure mode a `LazyVGrid` was rejected for once already. A fixed
    /// height with internal scrolling (`tile(fixedHeight:)`) removes that
    /// risk at the root — Speed Test's history now scrolls *within* its
    /// own fixed box instead of growing it, so there's no longer anything
    /// for Path to Internet to be forced to match.
    var pathAndSpeedRow: some View {
        HStack(alignment: .top, spacing: 12) {
            if SectionLayout.pathToInternet.appears(on: surface) {
                tile(title: "Path to Internet", fixedHeight: ContentView.tileHeight, trailing: {
                    Button("Trace Now") {
                        traceroute.run()
                    }
                    .disabled(traceroute.isRunning)
                    .accessibilityLabel("Trace Now")
                    .accessibilityHint("Runs a traceroute to find the path to the internet")
                }) {
                    tracerouteSection
                }
            }
            if SectionLayout.speedTest.appears(on: surface) {
                tile(title: "Speed Test", fixedHeight: ContentView.tileHeight, trailing: {
                    Button(networkQuality.isRunning ? "Testing…" : "Run Speed Test") {
                        networkQuality.run()
                    }
                    .disabled(networkQuality.isRunning)
                    .accessibilityLabel(networkQuality.isRunning ? "Testing" : "Run Speed Test")
                    .accessibilityHint("Measures download and upload throughput using Cloudflare's public speed-test endpoint. Uses your data plan, up to roughly 50MB total, less on a slow connection.")
                }) {
                    speedTestTileContent
                }
            }
        }
    }

    /// Path to Internet's full content: current-trace status, then (once
    /// there's a real path) the hop list. Flat content, not its own scroll
    /// box — the outer `tile(fixedHeight:)` call this feeds already wraps
    /// all of it in one `NoBounceScrollView` (see `ContentView.tileHeight`),
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
                    .appKitToolTip(Self.suggestedEdgeHopHelp, enabled: !isCapturingScreenshot)
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
    @ViewBuilder
    var speedTestTileContent: some View {
        HStack {
            Text("up to ~50MB per run")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            // Secondary, plain-styled — this tile already has one
            // first-class action (the header's "Run Speed Test"); a
            // second prominent button competing for the same slot would
            // suggest a choice that doesn't need to be made every time.
            // Shares `isRunning`/`recentRuns` with the Cloudflare path
            // rather than getting its own tile: both are answers to
            // "how's my connection right now," just at different costs
            // (~1s vs ~30s) and depths (throughput vs. throughput +
            // responsiveness under load) — one history, one place to
            // compare them, matching how this was originally scoped in
            // DESIGN-NOTES.md before the RPM half was deferred.
            if networkQuality.isAppleTestAvailable {
                Button(networkQuality.isRunning ? "Testing…" : "Run Network Quality") {
                    networkQuality.runAppleTest(interfaceName: viewModel.currentInterface?.interfaceName)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .disabled(networkQuality.isRunning)
                .accessibilityLabel(networkQuality.isRunning ? "Testing" : "Run Network Quality")
                .accessibilityHint("Runs Apple's own network quality test: throughput plus responsiveness under load. Uses your data plan and takes about 30 seconds.")
            }
        }
        speedTestList
        if let error = networkQuality.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }

    /// Every real speed-test run, newest first — a genuine time series
    /// (see `NetworkQualityResult`), not a change-log, so unlike DHCP
    /// History every run gets a row regardless of whether the numbers
    /// differ from the last one. Flat content, not its own scroll box —
    /// the outer `tile(fixedHeight:)` call this feeds already wraps all
    /// of `speedTestTileContent` in one `NoBounceScrollView` (see
    /// `ContentView.tileHeight`), so a second, inner box here would just
    /// nest redundantly.
    @ViewBuilder
    private var speedTestList: some View {
        if networkQuality.recentRuns.isEmpty {
            Text(networkQuality.isRunning ? "Testing…" : "No speed test run yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            speedTestRows
        }
    }

    /// One line per run for the throughput/timestamp row: unlike DHCP
    /// History's secondary line, "↓ 765 Mbps  ↑ 173 Mbps" plus a
    /// time-only (no date) timestamp is short enough to fit this tile's
    /// half-width comfortably — confirmed directly against a real
    /// screenshot rather than assumed from the two-line version tried
    /// first. An Apple-sourced run adds a second line for RPM/base
    /// latency, the data a Cloudflare-endpoint run simply doesn't have —
    /// every Cloudflare row keeps looking exactly as it always has.
    private var speedTestRows: some View {
        ForEach(networkQuality.recentRuns) { run in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("↓ \(Self.mbpsText(run.downloadMbps))  ↑ \(Self.mbpsText(run.uploadMbps))")
                    Spacer()
                    Text(run.testedAt, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                if run.source == NetworkQualityResult.Source.appleNetworkQuality.rawValue {
                    Text(Self.appleQualityDetail(run))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// RPM under load, split by direction — the signal this whole second
    /// source exists for — plus idle base latency, the one other figure
    /// `networkQuality` measures that Cloudflare's plain file transfer
    /// has no equivalent of.
    private static func appleQualityDetail(_ run: NetworkQualityRecord) -> String {
        var parts = ["Apple"]
        if let dl = run.downloadResponsivenessRPM, let ul = run.uploadResponsivenessRPM {
            parts.append("RPM \(dl)↓/\(ul)↑")
        }
        if let rtt = run.baseRTTMs {
            parts.append(String(format: "base %.0fms", rtt))
        }
        return parts.joined(separator: " · ")
    }

    private static func mbpsText(_ value: Double) -> String {
        String(format: "%.0f Mbps", value)
    }

    // MARK: - Wi-Fi

    /// Current signal/link characteristics — window-only, read-at-a-glance
    /// current state rather than scrollable history, so it has no box of
    /// its own the way the sections below it do.
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
                // Holds the same height the populated list would occupy,
                // so a first event appearing doesn't make the whole
                // popover jump.
                .frame(height: SectionLayout.events.boxHeight(on: surface), alignment: .top)
        } else {
            scrollBox(.events) {
                eventRows
            }
        }
    }

    /// Capped when capturing, uncapped on screen — the opposite of every
    /// other section here, and deliberate. On screen the list scrolls, so
    /// depth is free; in a capture every row is rendered unclipped, so
    /// depth is *height*, and height is legibility: a 39-event capture is
    /// already ~3300px tall, and the full 200-event fetch would run
    /// ~10,000px, which downscales to unreadable in any viewer. Since
    /// being readable is the entire reason the capture exists (see
    /// `ScreenshotService`), a legible window onto recent history beats a
    /// complete but illegible one. 50 keeps captures at roughly the size
    /// already confirmed readable.
    private var eventRows: some View {
        ForEach(isCapturingScreenshot ? Array(eventLog.events.prefix(50)) : eventLog.events) { event in
            HStack {
                Text(event.message)
                    .font(.system(size: 12))
                    .foregroundStyle(eventColor(for: event))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
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
            scrollBox(.snmpDevices) {
                infrastructureRows
            }
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
                        .appKitToolTip(
                            Self.reachabilityHelp(deviceReachability(device)),
                            enabled: !isCapturingScreenshot
                        )
                    Text(device.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(device.uptimeDescription)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                // No lineLimit here, deliberately — sysDescr (a raw
                // SNMP-provided string, no length guarantee) wraps to as
                // many lines as it needs instead of truncating, unlike
                // the single-line convention used elsewhere in this
                // popover.
                // Addresses shown only when there's more than one — a
                // single address is already implied by the row and would
                // just cost a line.
                if !device.aliasAddresses.isEmpty {
                    Text(device.addressDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(device.sysDescr)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
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
                    captureSafeTextField("public, private", text: $communityDraft) {
                        commitCommunity()
                    }
                    Button("Set") { commitCommunity() }
                        .accessibilityLabel("Set community strings")
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
            scrollBox(.dhcpHistory, spacing: 4) {
                dhcpHistoryRows
            }
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
                    .appKitToolTip(DHCPLeaseRecord.transactionHelpText, enabled: !isCapturingScreenshot)
            }
        }
    }

    // MARK: - Printer Alerts

    /// Sized to comfortably show 2 printers before scrolling — see
    /// `SectionLayout.printerAlerts` for how that height was arrived at
    /// and why it carries a row of headroom rather than sitting exactly
    /// on the 2-row boundary.
    @ViewBuilder
    var printerAlertsList: some View {
        scrollBox(.printerAlerts, spacing: 0) {
            printerAlertRows
        }
    }

    /// One row per CUPS-configured printer — a colored dot (green: no
    /// alerts, red: `reasons` non-empty) plus the reasons themselves when
    /// present. `PrinterDiscoveryService.PrinterAlert` has no reachability
    /// concept of its own, so unlike `infrastructureRows` there's no
    /// "unknown/gray" state here — CUPS always reports *something*
    /// (`none`, if nothing's wrong).
    private var printerAlertRows: some View {
        ForEach(connectivity.printerStatuses) { printer in
            HStack {
                Circle()
                    .fill(printer.reasons.isEmpty ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(printer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(printer.reasons.isEmpty ? "OK" : printer.reasons.joined(separator: ", "))
                    .foregroundStyle(printer.reasons.isEmpty ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
        }
    }

    // MARK: - SaaS Monitoring

    /// Business SaaS status — window-only, read-at-a-glance current state
    /// rather than scrollable history, same reasoning `wifiSection` above
    /// gives: a short, user-configurable list (`PreferencesView`'s
    /// service picker), no box of its own. See `SaaSMonitoringViewModel`
    /// and DESIGN-NOTES.md's "Business SaaS monitoring".
    // Not `private` — called from `ContentView.swift`'s `scrollableContent`.
    @ViewBuilder
    var saasMonitoringSection: some View {
        ForEach(saasMonitoring.statuses) { status in
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
        }
    }

    private func saasIndicatorColor(_ indicator: SaaSStatusService.Indicator) -> Color {
        switch indicator {
        case .none: return .green
        case .minor: return .yellow
        case .major, .critical: return .red
        case .unknown: return .gray
        }
    }
}
