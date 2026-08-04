import SwiftUI

/// The merged "Network" tile — Network Health and Info merged into one,
/// real content overlap (Router/Network/DNS/Public IP/ISP each showed up
/// in both, just as two different facets of the same concept), see
/// `PUNCHLIST.md`'s "Network Health and Info tiles" item for the full
/// row-ordering reasoning this was built from.
///
/// The most aggregate, most-dependent-on-everything-else tile in the
/// app — its `Grid` reads top-to-bottom as most-dependent to most-
/// fundamental. Last, and by far the largest, of the ten window tiles
/// pulled out of `ContentView`'s single body into its own `View` type
/// (see `PUNCHLIST.md`'s `ContentView` fan-in entry) — reads more view
/// models than any other extracted tile (nine, versus `ContentView`'s
/// original seventeen) simply because this tile
/// genuinely synthesizes signal from that much of the app's state; even
/// so, a change to (say) `snmp` or `saasMonitoring` no longer
/// re-evaluates this tile's body at all, which it would have as part of
/// `ContentView` itself. The latency-history `@State` moved here too —
/// purely local UI state with no reason to live on `ContentView` once
/// this section is its own type.
struct NetworkTile: View {
    var viewModel: NetworkMonitorViewModel
    var connectivity: ConnectivityViewModel
    var wifiSSID: WiFiSSIDViewModel
    var networkIdentity: NetworkIdentityViewModel
    var publicIP: PublicIPViewModel
    var ispIdentity: ISPIdentityViewModel
    var traceroute: TracerouteViewModel
    var dhcpLease: DHCPLeaseViewModel
    var networkQuality: NetworkQualityViewModel
    var ddns: DDNSViewModel

    /// Keyed by `ConnectionLayer.id`. Populated by this tile's own
    /// `.task`; empty until then, which simply renders no sparklines
    /// rather than empty boxes.
    @State private var latencyHistory: [String: [LatencySample]] = [:]

    var body: some View {
        tile(title: "Network", fixedHeight: ContentView.tileHeight) {
            connectionHealthSection
        }
    }

    /// **`Grid` clipping, found and fixed, worth remembering why.** `Grid`
    /// once correctly aligned every row's icons but rendered every label
    /// with its first character clipped, when this tile's content lived
    /// inside `NoBounceScrollView` — a custom `NSHostingView`/`NSScrollView`
    /// bridge with a documented history of not perfectly tracking
    /// SwiftUI's intrinsic sizing for certain content. Root-caused to that
    /// AppKit bridge specifically, not `Grid` itself: dropping down to a
    /// plain SwiftUI `ScrollView` (see `NoBounceScrollView`'s removal)
    /// made the bug stop reproducing entirely, confirmed live — no
    /// special-casing needed here anymore.
    @ViewBuilder
    private var connectionHealthSection: some View {
        let layers = connectionLayersLowToHigh
        // Split so `dhcpGridRow` can sit between Router and Network
        // rather than only ever at the very top or bottom — DHCP
        // supplies the addressing Router/Public IP/etc. depend on, but
        // is itself more fundamental than Network's own Wi-Fi/Ethernet
        // association (raised directly: "I think that is the right
        // place in the hierarchy"). `layers` is already low-to-high
        // with Network first (see `connectionLayersLowToHigh`'s own doc
        // comment), so reversed-and-dropped-last is everything except
        // Network, in the same most-dependent-to-most-fundamental
        // display order the Grid already reads top to bottom.
        let reversedLayers = Array(layers.reversed())
        let aboveNetwork = reversedLayers.dropLast()
        let networkLayer = reversedLayers.last
        VStack(alignment: .leading, spacing: 2) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                // At the top, not the bottom — the most aggregate,
                // most-dependent-on-everything-else signal of the set
                // (see `PUNCHLIST.md`'s "Network Health and Info tiles"
                // item for the full row-ordering reasoning: this Grid
                // reads top-to-bottom as most-dependent to most-
                // fundamental, matching `layers.reversed()` below).
                quickCheckGridRow
                ForEach(aboveNetwork) { layer in
                    layerGridRow(layer)
                }
                // Between Router and Network, not slotted into
                // `connectionLayersLowToHigh` itself — DHCP isn't a
                // `ConnectivityCheck`-backed reachability signal like
                // every other row here, it's a three-state identity
                // check (normal/changed/abnormal), which `LayerStatus`
                // has no clean case for (`.unknown` already means "gray,
                // nothing to judge yet," not "yellow, something changed
                // recently"). See `dhcpStatusColor`'s own doc comment
                // for what each color means.
                dhcpGridRow
                if let networkLayer {
                    layerGridRow(networkLayer)
                }
            }
            .font(.system(size: 12))

            if layers.contains(where: { $0.status == .unhealthy && $0.correlatedWithChange }) {
                Text("* possibly related to a recent network change")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            // Formerly Info's own trailing content — merged in here
            // rather than dropped, see `PUNCHLIST.md`'s "Network Health
            // and Info tiles" item.
            if let error = publicIP.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            // Confirms the polling is actually active and shows its
            // current state — absent entirely until a hostname is
            // configured (see `ddnsRow`).
            ddnsRow
        }
        // Loaded when the section appears rather than kept continuously
        // up to date — the popover is shut almost all the time. Keyed on
        // `checks` so it also refreshes while the popover is *open* and a
        // new round lands, which is exactly when someone is watching a
        // problem develop.
        .task(id: connectivity.lastCheckedAt) {
            latencyHistory = connectivity.latencyHistory()
        }
    }

    /// The dot/label/icon/chart/detail shape every status row in
    /// `connectionHealthSection`'s `Grid` uses — extracted after the
    /// third near-identical hand-rolled `GridRow` (`layerGridRow`,
    /// `quickCheckGridRow`, `dhcpGridRow` all built this same five-cell
    /// shape by hand) so the next tile's rows are a few lines instead of
    /// copying the whole shape and its column-alignment reasoning again.
    /// `icon`/`chart` are `@ViewBuilder` slots, not optionals — a caller
    /// with nothing real for either passes `Color.clear.frame(width: 0,
    /// height: 0)` explicitly (see that pattern's own reasoning below),
    /// rather than this helper silently defaulting to `EmptyView()`,
    /// which doesn't reliably reserve its `Grid` column.
    @ViewBuilder
    private func statusGridRow<Icon: View, Chart: View>(
        color: Color,
        dotHelp: String? = nil,
        label: String,
        detail: String,
        detailColor: Color = .primary,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder chart: () -> Chart
    ) -> some View {
        GridRow {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .help(optional: dotHelp)
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .gridColumnAlignment(.leading)
            icon()
            chart()
            // `minWidth` protects this column specifically — confirmed
            // necessary again on the second `Grid` attempt: sharing one
            // column width across every row means a long label ("ISP
            // Edge Router") squeezes this column on every row, not just
            // its own. A value truncated in the middle ("Hom...hernet")
            // is unreadable garble; a label truncated at the tail ("ISP
            // Edge…") still starts with its most identifying word — so
            // this column gets the guaranteed room, and the label
            // column absorbs whatever compression is left. 85pt
            // comfortably fits the longest real value seen here ("Home
            // Ethernet"). `maxWidth: .infinity` marks this column
            // flexible so `Grid` gives it the tile's leftover width
            // instead of shrink-wrapping the whole grid to its narrowest
            // fit — without it, a wide window left the grid (and this
            // "trailing"-aligned column) bunched at the tile's left edge
            // instead of flush against its real right edge. Confirmed
            // via user screenshot: looked fine in the narrower popover,
            // misaligned only in the window.
            Text(detail)
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 85, maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
        }
    }

    /// Extracted from `connectionHealthSection`'s own `Grid` content so
    /// `dhcpGridRow` can be inserted between two calls to this rather
    /// than only ever before/after one single `ForEach` over every
    /// layer. Same row every layer in `connectionLayersLowToHigh` has
    /// always used — no behavior change, just made callable twice from
    /// two different slices of `layers.reversed()`.
    @ViewBuilder
    private func layerGridRow(_ layer: ConnectionLayer) -> some View {
        statusGridRow(
            color: layerColor(for: layer),
            label: layer.label,
            detail: layer.detail + (layer.status == .unhealthy && layer.correlatedWithChange ? " *" : ""),
            detailColor: layer.status == .unhealthy ? layerColor(for: layer) : .primary
        ) {
            // Not `EmptyView()` — confirmed by direct testing that a
            // literal `EmptyView()` cell doesn't reliably reserve its
            // `Grid` column, so rows with an empty icon/sparkline
            // silently collapsed a column relative to rows with real
            // content there (Router's icon pushed its sparkline right
            // of every ping row's). `Color.clear` measures as a real
            // zero-color view and keeps every row's cell count *and*
            // column position honest.
            if let url = layer.url {
                externalLinkIcon(
                    url: url,
                    accessibilityLabel: "\(layer.label) admin page",
                    accessibilityHint: "Opens \(layer.label)'s web interface in your browser"
                )
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        } chart: {
            // Network's own sparkline (Wi-Fi only — Ethernet has no
            // signal strength to chart) uses RSSI history from
            // `wifiSSID.recentSamples`, not `latencyHistory`: this row
            // isn't a ping-latency check, so `latencyHistory` has no
            // entry for it at all. Same values/reversal `WiFiTile`'s own
            // Signal row already uses for the identical chart.
            if layer.id == "network", viewModel.currentInterface?.isWiFi == true,
               wifiSSID.recentSamples.count > 1 {
                Sparkline(values: wifiSSID.recentSamples.reversed().map { $0.rssi.map(Double.init) })
            } else if let samples = latencyHistory[layer.id] {
                Sparkline(values: samples.map(\.latencyMs))
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        // `.contain`, not `.combine` — turns this row into one element
        // whose frame spans its children (what both VoiceOver grouping and
        // `reportFrameForFieldTest` below need), while keeping the
        // Router/ISP Edge Router rows' real `externalLinkIcon` link
        // individually reachable. `.combine` would merge everything into
        // one opaque element and silently swallow that link.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("networkHealth.row.\(layer.id)")
        .reportFrameForFieldTest("networkHealth.row.\(layer.id)")
    }

    /// Same five-cell shape every `GridRow` in `connectionHealthSection`
    /// uses (dot, label, icon, sparkline, value) — an icon button styled
    /// identically to `externalLinkIcon`, in the same column position, so
    /// it aligns with the Router row's link icon by construction. The dot
    /// stays gray until a result exists — never claims a verdict it
    /// hasn't earned.
    private var quickCheckGridRow: some View {
        statusGridRow(
            color: quickCheckColor,
            // Same tooltip the Apple networkQuality tile's own RPM
            // figures use (`QuickCheckDisplay.rpmThresholdHelp`) —
            // raised directly, so the two surfaces' colored verdicts
            // explain themselves the same way.
            dotHelp: QuickCheckDisplay.rpmThresholdHelp,
            // "networkQuality" — matches the Apple networkQuality
            // tile's own name for the full test this is a quick preview
            // of, reported directly as clearer than "Call Check". Length
            // is close to the original "Video Call Check" that was
            // shortened for truncation reasons (see
            // `quickCheckDetailText`'s trailing column) — re-verify
            // visually after this rename.
            label: "networkQuality",
            detail: quickCheckDetailText
        ) {
            Button {
                networkQuality.runQuickCheck(interfaceName: viewModel.currentInterface?.interfaceName)
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
            quickCheckHistoryDots
        }
    }

    private var quickCheckColor: Color {
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
    /// sparkline convention here (`wifiSSID.recentSamples.reversed()`/
    /// `samples.map(\.latencyMs)` are both already-reversed-to-
    /// chronological arrays by the time they reach `Sparkline`).
    @ViewBuilder
    private var quickCheckHistoryDots: some View {
        // Filters, doesn't compactMap to just the RPM values -- keeps each
        // `NetworkQualityRecord` around so ForEach below can use its own
        // real (SwiftData-provided) identity instead of array offset. Same
        // pattern already relied on for `dhcpLease.history`/`snmp.devices`
        // elsewhere in this app.
        let records = networkQuality.quickCheckHistory.reversed().filter { $0.combinedResponsivenessRPM != nil }
        if records.isEmpty {
            // Same "always emit every cell" rule the rest of this Grid
            // follows — see the `Color.clear` comment on the layer rows'
            // own sparkline column for why an empty cell still needs a
            // real, zero-sized view rather than being omitted outright.
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

    private var quickCheckDetailText: String {
        if networkQuality.isRunningQuickCheck { return "Checking…" }
        if let error = networkQuality.quickCheckError { return error }
        // Shorter than "\(status.label) — \(status.rpm) RPM" (tried
        // first) — that version truncated in the middle of the RPM
        // number once the label above was long enough to squeeze it.
        if let status = networkQuality.quickCheckStatus { return "\(status.label) (\(status.rpm))" }
        return "Tap to check"
    }

    /// A DHCP row raised directly for the merged Network tile — "just a
    /// colored dot to indicate normal/changed/abnormal status." Same
    /// five-cell shape every other `GridRow` in `connectionHealthSection`
    /// uses, no sparkline/link icon (`Color.clear` in both slots, same
    /// "always emit every cell" rule the rest of this Grid follows).
    private var dhcpGridRow: some View {
        statusGridRow(
            color: dhcpStatusColor,
            label: "DHCP",
            detail: dhcpDetailText
        ) {
            Color.clear.frame(width: 0, height: 0)
        } chart: {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Three states, not the shared `LayerStatus` every other row here
    /// uses — deliberately: `.unknown` already means "gray, nothing to
    /// judge yet" (see `layerColor(for:)`), not "yellow, something
    /// changed recently," so shoehorning DHCP into that enum would have
    /// reused a color for two different meanings. Red covers both real
    /// failure signals `DHCPLeaseViewModel` already tracks — a link-local
    /// (APIPA) fallback, meaning DHCP failed outright, and a renewal
    /// that's run past its expected T2 deadline — checked first so an
    /// abnormal state always wins over a merely-recent change. Yellow is
    /// "the current lease is new" (within `dhcpRecentChangeWindow` of
    /// its own `firstObservedAt`), not a separate tracked flag — a real
    /// lease change already gets its own `AppEventKind` pair
    /// (`.dhcpLeaseChanged`) for the Events log; this only needs "is that
    /// recent enough to still matter here."
    private var dhcpStatusColor: Color {
        if dhcpLease.isFallenBackToLinkLocal || dhcpLease.isRenewalOverdue { return .red }
        if let firstObservedAt = dhcpLease.history.first?.firstObservedAt,
           Date().timeIntervalSince(firstObservedAt) < Self.dhcpRecentChangeWindow {
            return .yellow
        }
        return .green
    }

    private var dhcpDetailText: String {
        if dhcpLease.isFallenBackToLinkLocal { return "Link-local fallback" }
        if dhcpLease.isRenewalOverdue { return "Renewal overdue" }
        if let firstObservedAt = dhcpLease.history.first?.firstObservedAt,
           Date().timeIntervalSince(firstObservedAt) < Self.dhcpRecentChangeWindow {
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
    private static let dhcpRecentChangeWindow: TimeInterval = 600

    private func layerColor(for layer: ConnectionLayer) -> Color {
        switch layer.status {
        case .healthy: return .green
        case .unknown: return .gray
        case .unhealthy:
            // Full red for the actual root cause; a dimmed red for
            // anything failing above it, which is probably just a
            // consequence rather than its own separate problem.
            return layer.id == rootCauseLayerID ? .red : Color.red.opacity(0.4)
        }
    }

    private func checkDetail(for check: ConnectivityCheck) -> String {
        check.success ? String(format: "%.0f ms", check.latencyMs ?? 0) : "unreachable"
    }

    /// Builds a `ConnectionLayer` straight from `connectivity.checks`, no
    /// special-casing beyond "absent means not checked yet." Only fits
    /// layers with no extra states of their own to represent — see
    /// `connectionLayersLowToHigh`'s Internet/DNS/HTTP call sites for why
    /// those three specifically can use this and Network/Local Router/
    /// Public IP/ISP Edge Router can't.
    private func standardLayer(id: String, label: String) -> ConnectionLayer {
        let check = connectivity.checks.first { $0.label == label }
        return ConnectionLayer(
            id: id,
            label: label,
            detail: check.map(checkDetail) ?? "Not checked",
            status: check.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: check?.correlatedWithChange ?? false
        )
    }

    /// Network name (if any) plus connection type combined into one row
    /// (e.g. "<network name> Wi-Fi", "<network name> Ethernet", or just
    /// "Ethernet" with no known name yet) instead of separate "Network"/
    /// "Interface" and "Type" rows, to save vertical space.
    ///
    /// On Wi-Fi, the live SSID wins over a user-assigned `KnownNetwork`
    /// label — reported directly: `KnownNetwork` is keyed by router MAC
    /// + subnet, not SSID (see that type's own doc comment), so the same
    /// physical LAN reached over Ethernet and Wi-Fi shares one label. A
    /// label set from the Ethernet side was silently overriding the
    /// genuinely different, accurate live Wi-Fi SSID instead of just
    /// supplementing it. Off Wi-Fi there's no live-SSID equivalent, so
    /// the label is still the best available name there.
    private func networkDisplay(_ info: NetworkInterfaceInfo) -> String {
        let type = info.isWiFi ? "Wi-Fi" : "Ethernet"
        let label = networkIdentity.currentNetwork?.label
        let name: String? = info.isWiFi
            ? (wifiSSID.currentSSID ?? (label?.isEmpty == false ? label : nil))
            : (label?.isEmpty == false ? label : nil)
        guard let name else { return type }
        return "\(name) \(type)"
    }

    /// IP address and subnet mask combined into one CIDR-notation row
    /// (e.g. "10.0.0.152/24") instead of two separate rows, to save
    /// vertical space.
    private func ipAddressDisplay(_ info: NetworkInterfaceInfo) -> String {
        guard let ip = info.ipAddress else { return "—" }
        guard let mask = info.subnetMask, let prefix = SubnetCalculator.prefixLength(subnetMask: mask) else {
            return ip
        }
        return "\(ip)/\(prefix)"
    }

    /// Ordered low (most fundamental) to high (most dependent on
    /// everything below it working first).
    private var connectionLayersLowToHigh: [ConnectionLayer] {
        let info = viewModel.currentInterface

        // Interface and Network used to be separate rows, but checked
        // almost the same thing: Interface was a pure up/down signal
        // (`info != nil`), and Network's own status matched that exactly
        // except in one case — Wi-Fi with no name resolvable at all (no
        // recognized-network label, no live SSID), where the interface is
        // genuinely up but *which* network it is remains unknown. Combined
        // into one row rather than two nearly-redundant ones, reusing
        // `networkDisplay(_:)` (built for the Info section's equivalent
        // combined row) for the detail text.
        let networkLayer: ConnectionLayer
        if let info {
            let hasName = (networkIdentity.currentNetwork?.label?.isEmpty == false) || wifiSSID.currentSSID != nil
            // On Wi-Fi this row shows a signal-strength sparkline instead
            // of the network's name (see `connectionHealthSection`'s own
            // per-row rendering) — the name still reads via
            // `networkDisplay(_:)` off Wi-Fi. Requested directly: "Name" +
            // "Ethernet" (via `networkDisplay`, unchanged) or a sparkline
            // + "Wi-Fi" (here), not "Name" + "Wi-Fi" as before.
            //
            // This Mac's own IP and the known-network recognition count
            // (formerly Info's separate "IP Address" row and
            // `networkIdentityStatus`) fold in here too — merged-tile
            // work, see `PUNCHLIST.md`'s "Network Health and Info tiles"
            // item. `knownNetworkSuffix` is empty until
            // `NetworkIdentityViewModel` has actually recognized
            // something, same "nothing to show yet" reasoning
            // `networkIdentityStatus` used before it was folded in here.
            let knownNetworkSuffix = networkIdentity.currentNetwork.map { network in
                " · \(networkIdentity.isNewNetwork ? "new" : "seen \(network.timesSeen)×")"
            } ?? ""
            let detail = (info.isWiFi ? "Wi-Fi" : networkDisplay(info)) + " · \(ipAddressDisplay(info))" + knownNetworkSuffix
            if info.isWiFi && !hasName {
                // Not a connectivity failure — just missing information
                // (e.g. Location permission not granted yet) — so this is
                // "unknown," not "unhealthy," even though the interface
                // itself is confirmed up.
                networkLayer = ConnectionLayer(id: "network", label: "Network", detail: detail, status: .unknown)
            } else {
                networkLayer = ConnectionLayer(id: "network", label: "Network", detail: detail, status: .healthy)
            }
        } else {
            // Not genuine uncertainty — with no interface at all, this is
            // *definitely* down, not merely unevaluated.
            networkLayer = ConnectionLayer(id: "network", label: "Network", detail: "Down", status: .unhealthy)
        }

        // Every row below reuses its matching `OverallStatus.*Label`
        // constant for its own display text, rather than a separately
        // hardcoded string that happens to read similarly. Two of them
        // used to diverge for real — "Local Router" here read "Router"
        // in the Events log, and "Internet Ping by address" read
        // "Internet" — since `ConnectivityViewModel.logTransitions`
        // builds every event message straight from `check.label`, which
        // *is* one of these constants. Referencing the same constant here
        // makes that agreement structural instead of two places that
        // happened to match today.
        let routerCheck = connectivity.checks.first { $0.label == OverallStatus.routerLabel }
        let localRouterLayer: ConnectionLayer
        if info == nil {
            // Same reasoning as Network above: no interface means no
            // router address was ever known to check, but that's a
            // certain consequence of the root cause, not genuine
            // uncertainty — cascade as unhealthy instead of `.unknown`.
            localRouterLayer = ConnectionLayer(id: "localRouter", label: OverallStatus.routerLabel, detail: "—", status: .unhealthy)
        } else {
            // The router's own IP (formerly Info's separate "Router"
            // row) leads the detail text — merged-tile work, see
            // `PUNCHLIST.md`'s "Network Health and Info tiles" item.
            let addressPrefix = info?.routerAddress.map { "\($0) · " } ?? ""
            localRouterLayer = ConnectionLayer(
                id: "localRouter",
                label: OverallStatus.routerLabel,
                detail: addressPrefix + (routerCheck.map(checkDetail) ?? "Not checked"),
                status: routerCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: routerCheck?.correlatedWithChange ?? false,
                // Always shown once the address is known, not gated behind
                // a "does this actually serve a web UI" probe — the
                // simpler answer the punchlist item raising this itself
                // suggested, leaving that probe's self-signed-cert
                // complexity to the separate SNMP Devices web-link item.
                url: info?.routerAddress.map { "http://\($0)" }
            )
        }

        // Pinging the router's own public/WAN address, not a remote host —
        // verified directly (TTL 64, sub-millisecond RTT) that this is
        // answered locally by the gateway recognizing its own address, not
        // a real round trip to the internet. Sits between Local Router
        // (LAN-side reachability) and ISP Edge Router (one hop further
        // out) since that's exactly where it tests: whether the gateway's
        // WAN side is alive, catching e.g. an ISP modem/ONT losing power
        // that a LAN-side-only check can't see.
        let publicIPCheck = connectivity.checks.first { $0.label == OverallStatus.publicIPLabel }
        let publicIPLayer: ConnectionLayer
        if info == nil {
            publicIPLayer = ConnectionLayer(id: "publicIP", label: OverallStatus.publicIPLabel, detail: "—", status: .unhealthy)
        } else if let currentPublicIP = publicIP.currentIP {
            // The address itself (formerly Info's separate "Public IP"
            // row) leads the detail text, same merged-tile reasoning as
            // Local Router above.
            publicIPLayer = ConnectionLayer(
                id: "publicIP",
                label: OverallStatus.publicIPLabel,
                detail: "\(currentPublicIP) · " + (publicIPCheck.map(checkDetail) ?? "Not checked"),
                status: publicIPCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: publicIPCheck?.correlatedWithChange ?? false
            )
        } else {
            // Not a failure — `PublicIPViewModel`'s own (much slower,
            // 5-minute-cadence) lookup just hasn't completed yet, most
            // likely right after launch.
            publicIPLayer = ConnectionLayer(id: "publicIP", label: OverallStatus.publicIPLabel, detail: "Not checked", status: .unknown)
        }

        // Discovery (which hop is the ISP edge) and monitoring (is it still
        // reachable) are deliberately separate: `TracerouteViewModel` only
        // owns confirming *which* hop this is; `ConnectivityViewModel`
        // pings that hop's address on the same fast/reactive cadence as
        // Router/Internet/DNS/HTTP, so this reads like every other layer
        // here (a response time, not a re-trace's resolved hostname).
        // The ISP's name (formerly Info's separate "ISP" row) leads the
        // detail text wherever there's room for it, same merged-tile
        // reasoning as Local Router/Public IP above — independent of
        // traceroute hop confirmation, since RDAP identifies the ISP
        // from the public IP directly, not from the hop itself. Absent
        // for an ISP not in the curated status-page table (e.g.
        // Astound — checked live, no public status page exists), same
        // as Info's own row: the name still shows, just with no link.
        let ispPrefix = ispIdentity.organizationName.map { "\($0) · " } ?? ""
        let peRouterLayer: ConnectionLayer
        if info == nil {
            // Same reasoning as Network/Local Router/Public IP above: no
            // interface means no path exists to trace at all, which is a
            // certain consequence of the root cause, not genuine
            // uncertainty. Reported directly: without this branch, a
            // previously-confirmed hop fell through to the
            // `monitoredHop == nil` case below during a real outage and
            // showed "Not confirmed" — misleading, since that text means
            // "you haven't set this up yet," not "this is currently down."
            peRouterLayer = ConnectionLayer(id: "peRouter", label: OverallStatus.peRouterLabel, detail: "—", status: .unhealthy)
        } else if traceroute.monitoredHop == nil {
            // Not a failure — you haven't confirmed which traceroute hop is
            // the ISP's edge yet (see the Path to Internet tile).
            peRouterLayer = ConnectionLayer(
                id: "peRouter",
                label: OverallStatus.peRouterLabel,
                detail: ispPrefix + "Not confirmed",
                status: .unknown,
                url: ispIdentity.statusPageURL
            )
        } else {
            let peRouterCheck = connectivity.checks.first { $0.label == OverallStatus.peRouterLabel }
            peRouterLayer = ConnectionLayer(
                id: "peRouter",
                label: OverallStatus.peRouterLabel,
                detail: ispPrefix + (peRouterCheck.map(checkDetail) ?? "Not checked"),
                status: peRouterCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: peRouterCheck?.correlatedWithChange ?? false,
                url: ispIdentity.statusPageURL
            )
        }

        // Internet/DNS/HTTP need none of Network/Local Router/Public IP/
        // ISP Edge Router's special-cased `info == nil` branches above:
        // `ConnectivityViewModel.runChecks()`'s own no-interface guard
        // already synthesizes `success: false` entries for exactly these
        // three labels unconditionally (unlike Router/PublicIP/PeRouter,
        // which it only covers conditionally or not at all), so the
        // ordinary check-lookup-and-map below already resolves to
        // `.unhealthy` with no interface, correctly, without a local
        // guard of its own — confirmed by reading that guard rather than
        // assumed, before relying on it here.
        let internetLayer = standardLayer(id: "internet", label: OverallStatus.internetLabel)
        // Can't use `standardLayer` — that helper has no way to fold in
        // the DNS server's own address (formerly Info's separate "DNS
        // Server" row), same merged-tile reasoning as Local Router/
        // Public IP/ISP Edge Router above. `info?.dnsServer` is `nil`
        // exactly when `standardLayer`'s own no-interface case already
        // applies, so the prefix is simply empty then rather than
        // needing a matching local guard.
        let dnsCheck = connectivity.checks.first { $0.label == OverallStatus.dnsLabel }
        let dnsAddressPrefix = info?.dnsServer.map { "\($0) · " } ?? ""
        let dnsLayer = ConnectionLayer(
            id: "dns",
            label: OverallStatus.dnsLabel,
            detail: dnsAddressPrefix + (dnsCheck.map(checkDetail) ?? "Not checked"),
            status: dnsCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: dnsCheck?.correlatedWithChange ?? false
        )
        let httpLayer = standardLayer(id: "http", label: OverallStatus.httpLabel)

        return [networkLayer, localRouterLayer, publicIPLayer, peRouterLayer, internetLayer, dnsLayer, httpLayer]
    }

    /// The lowest (most fundamental) unhealthy layer — everything failing
    /// *above* this one is presumed to be a consequence of this, not an
    /// independent problem, since each layer depends on the ones below it.
    private var rootCauseLayerID: String? {
        connectionLayersLowToHigh.first { $0.status == .unhealthy }?.id
    }

    /// One summary row for however many hostnames are configured — not
    /// one row per hostname, to keep this from growing the tile
    /// unboundedly the way `FeatureFlags.UserAddedSaaSSite` deliberately
    /// stays out of the curated SaaS table for the same reason. Per-
    /// hostname detail lives in the tooltip and, for a genuine
    /// transition, the Events list.
    @ViewBuilder
    private var ddnsRow: some View {
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
                    .fill(ddnsSummaryColor)
                    .frame(width: 8, height: 8)
                Text(ddnsSummaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
            .help(ddnsTooltipText)
        }
    }

    /// Worst state wins — a single red dot for one stale hostname among
    /// several shouldn't be averaged away by the others being fine.
    /// `.blockedByCGNAT` renders distinctly from both: not a failure
    /// (green would be dishonest) and not "something broke" (red would
    /// overstate it) — a structural fact about this connection, same
    /// `.orange` tier the "possibly related to a recent network change"
    /// annotation already uses for "worth noting, not a failure."
    private var ddnsSummaryColor: Color {
        let states = ddns.statuses.compactMap(\.syncState)
        if states.contains(.stale) { return .red }
        if states.contains(.blockedByCGNAT) { return .orange }
        if states.count == ddns.statuses.count, states.allSatisfy({ $0 == .current }) { return .green }
        return .secondary
    }

    private var ddnsSummaryText: String {
        let name = ddns.statuses.count == 1 ? ddns.statuses[0].hostname : "\(ddns.statuses.count) hostnames"
        let minutes = Int(FeatureFlags.ddnsCheckInterval / 60)
        return "\(name) · every \(minutes)m"
    }

    private var ddnsTooltipText: String {
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
