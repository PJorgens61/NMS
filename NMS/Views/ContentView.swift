import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @ObservedObject var lanDiscovery: LANDiscoveryViewModel
    @ObservedObject var connectivity: ConnectivityViewModel
    @ObservedObject var networkIdentity: NetworkIdentityViewModel
    @ObservedObject var publicIP: PublicIPViewModel
    @ObservedObject var dhcpLease: DHCPLeaseViewModel
    @ObservedObject var networkQuality: NetworkQualityViewModel
    @ObservedObject var screenshot: ScreenshotViewModel
    @ObservedObject var wifiSSID: WiFiSSIDViewModel
    @ObservedObject var eventLog: EventLogViewModel
    @ObservedObject var traceroute: TracerouteViewModel
    @ObservedObject var bonjourDiscovery: BonjourDiscoveryViewModel
    @ObservedObject var snmp: SNMPViewModel
    /// Not `@ObservedObject` — a plain value computed once at launch (see
    /// `NMSApp`), not something that changes while the popover is open.
    let buildInfo: BuildInfoService.Info?

    /// True only on the throwaway copy handed to `ImageRenderer` (see the
    /// camera button's action), never on the live popover. Makes the
    /// scrollable sections render as plain, unclipped lists of every row.
    ///
    /// Deliberately a plain stored property, not `@Environment` or
    /// `@State`. An `@Environment` version of exactly this was built
    /// first and confirmed not to work — the value never reached the
    /// view during `ImageRenderer`'s pass (logged from inside `eventList`
    /// during a real capture: `false` every time). A plain `var` on a
    /// struct has no propagation machinery to fail; `var copy = self;
    /// copy.isCapturingScreenshot = true` is just a value copy, read
    /// directly during `body`.
    ///
    /// Two independent reasons this matters, not one: `ImageRenderer`
    /// doesn't render `ScrollView` content *at all* off-screen (not
    /// clipped — absent, confirmed by a side-by-side against a real
    /// screen capture where every plain-`VStack` section rendered and
    /// every `ScrollView` section came out blank, 5 for 5); and a
    /// screenshot meant to be read later is more useful showing full
    /// history than whatever happened to fit an 8-row scroll window.
    var isCapturingScreenshot = false

    @State private var communityDraft: String = ""
    @State private var isEditingCommunity = false
    /// Keyed by `ConnectionLayer.id`. Populated by the Network Health
    /// section's `.task`; empty until then, which simply renders no
    /// sparklines rather than empty boxes.
    @State private var latencyHistory: [String: [LatencySample]] = [:]

    /// Two equal-width, flexible columns — half the popover's width each
    /// at this width, but "flexible" (not a fixed pixel size) so this
    /// keeps working if the popover width changes later. `LazyVGrid`
    /// simply flows tiles left-to-right, top-to-bottom, so a third tile
    /// (an odd count) leaves the second cell of its row empty rather than
    /// erroring — the expected, ready-made slot for the next tile added
    /// here.
    private static let tileColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Network Health, Info, and Path to Internet are short
            // label/value lists that looked sparse and hard to read once
            // the popover doubled in width for the DHCP History section —
            // wide gaps between a label and its value with nothing else
            // to fill the space. Tiled side by side instead, each sized to
            // its own half, not the whole popover.
            LazyVGrid(columns: Self.tileColumns, alignment: .leading, spacing: 12) {
                tile(title: "Network Health") {
                    connectionHealthSection
                }
                tile(title: "Info") {
                    infoSection
                }
                tile(title: "Path to Internet", trailing: {
                    Button("Trace Now") {
                        traceroute.run()
                    }
                    .disabled(traceroute.isRunning)
                    .accessibilityLabel("Trace Now")
                    .accessibilityHint("Runs a traceroute to find the path to the internet")
                }) {
                    tracerouteSection
                }
                // Fills the empty second cell Path to Internet leaves
                // behind in a 3-tile, 2-column grid — the exact "ready-
                // made slot for the next tile" the grid comment above
                // anticipated.
                tile(title: "Speed Test", trailing: {
                    Button(networkQuality.isRunning ? "Testing…" : "Run Speed Test") {
                        networkQuality.run()
                    }
                    .disabled(networkQuality.isRunning)
                    .accessibilityLabel(networkQuality.isRunning ? "Testing" : "Run Speed Test")
                    .accessibilityHint("Measures download and upload throughput using Cloudflare's public speed-test endpoint. Uses your data plan, roughly 50MB total.")
                }) {
                    speedTestTileContent
                }
            }

            Divider()

            Text("DHCP History")
                .font(.headline)

            dhcpHistoryList

            Divider()

            Text("Events")
                .font(.headline)

            eventList

            Divider()

            HStack {
                Text("SNMP Devices")
                    .font(.headline)
                Spacer()
                Button(snmp.isScanning ? "Scanning…" : "Scan") {
                    snmp.scan()
                }
                .disabled(snmp.isScanning || !snmp.isAvailable)
                .accessibilityLabel(snmp.isScanning ? "Scanning" : "Scan")
                .accessibilityHint("Clears the SNMP device list and sweeps the subnet again")
            }

            infrastructureList

            // LAN Devices and Bonjour Devices sections are hidden — the
            // popover was too tall for a 13" MacBook screen. The
            // underlying scans aren't both still running for their own
            // sake: see `LANDiscoveryViewModel`/`BonjourDiscoveryViewModel`
            // for what each still feeds now that neither has a UI list.

            Divider()

            HStack {
                Button("Refresh") {
                    viewModel.refresh()
                    publicIP.check()
                    wifiSSID.refresh(isWiFi: viewModel.currentInterface?.isWiFi ?? false)
                }
                .accessibilityLabel("Refresh")
                .accessibilityHint("Re-reads network state, public IP and Wi-Fi network")
                // Icon-only so it adds no new row — this whole feature
                // exists to save a manual screenshot-and-hand-it-over
                // step, so it needs to cost as little popover space as
                // the thing it replaces cost none.
                Button {
                    // A copy, not `self` — see `isCapturingScreenshot`.
                    // `ContentView` is a struct, so this is a plain value
                    // copy that leaves the live popover untouched.
                    var capturing = self
                    capturing.isCapturingScreenshot = true
                    screenshot.capture(capturing)
                } label: {
                    Image(systemName: "camera")
                }
                .accessibilityLabel("Screenshot")
                .accessibilityHint("Saves an image of this popover and logs an event naming the file, so it can be found without guessing")
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .accessibilityLabel("Quit")
                .accessibilityHint("Quits NMS")
            }

            if let buildInfo {
                // Secondary, unobtrusive — this answers "which commit am I
                // running" (for a single-developer tool, easy to lose track
                // of after a few Cmd+R's), not a feature anyone needs to
                // look at day to day.
                Text("Build \(buildInfo.shortHash)\(buildInfo.isDirty ? "+" : "")")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(
                        "Build \(buildInfo.shortHash)\(buildInfo.isDirty ? ", with uncommitted changes" : "")"
                    )
            }

            // Deliberately loud (unlike the build line above) and placed
            // last, so it's the final thing read top-to-bottom. Exists to
            // catch a mistake with real history in this project: a test's
            // `defaults` key left set after the test ended, otherwise only
            // discoverable by grepping the plist by hand. No `#if DEBUG`
            // needed here — `activeOverridesSummary()` is already `nil`
            // unconditionally in a release build, so this is inert there
            // without a second guard to keep in sync.
            //
            // No dedicated refresh timer: this is computed directly in
            // `body`, so it goes stale for at most as long as the popover
            // sits open with nothing else re-rendering it — in practice
            // at most one connectivity round (30s, 5s if anything's
            // already unhealthy), since that's `@Published` and already
            // drives a re-render on its own.
            if let overrides = FailureInjector.activeOverridesSummary() {
                Text("⚠ DEBUG: \(overrides)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityLabel("Debug overrides active: \(overrides)")
            }
        }
        .padding(12)
        // Widened from the original 335pt for the DHCP History section,
        // then brought back down from a first attempt at 670pt (a single
        // *unbroken* line of full lease detail) once that line wrapped to
        // two instead — 670pt then just left every section with wide,
        // pointless gaps between labels and values, confirmed directly:
        // the widest wrapped DHCP line (bcast/gateway/DNS/domain/lease-
        // T1-T2/xid) measured to ~440pt of actual text, against a screenshot
        // of a real lease. 560pt covers that with headroom for a slightly
        // longer domain or an extra DNS server, without carrying 670pt's
        // dead space. Every section still has `.lineLimit(1)` truncation
        // as its fallback regardless.
        .frame(width: 560)
    }

    /// A bordered box with a header row (title, plus an optional trailing
    /// accessory like "Trace Now") — the visual unit tiles in the grid
    /// above are built from. A plain `Divider()` no longer reads as a
    /// separator once two tiles sit side by side rather than stacked full
    /// width, so each tile draws its own border instead.
    @ViewBuilder
    private func tile(title: String, @ViewBuilder content: () -> some View) -> some View {
        tile(title: title, trailing: { EmptyView() }, content: content)
    }

    @ViewBuilder
    private func tile(
        title: String,
        @ViewBuilder trailing: () -> some View,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }

    /// Everything the "Info" tile shows: the current interface's
    /// identifying details, a public-IP error if there is one, and the
    /// network-recognition status — previously inlined directly in `body`
    /// before Info became its own tile.
    @ViewBuilder
    private var infoSection: some View {
        if let info = viewModel.currentInterface {
            VStack(alignment: .leading, spacing: 2) {
                row("Network", networkDisplay(info))
                if info.isWiFi, let bssid = wifiSSID.currentBSSID {
                    row("BSSID", bssid)
                }
                row("IP Address", ipAddressDisplay(info))
                row("Router", routerDisplay(info))
                row("DNS Server", info.dnsServer ?? "—")
                row("Public IP", publicIP.currentIP ?? (publicIP.isChecking ? "Checking…" : "—"))
            }
        } else {
            Text("No active network connection")
                .foregroundStyle(.secondary)
        }

        if let error = publicIP.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }

        networkIdentityStatus
    }

    /// The label-entry input is hidden entirely now — this is read-only
    /// recognition status. A label, once set, still shows via the "Network"
    /// row in Info; there's just no in-popover way to enter/change one
    /// anymore.
    @ViewBuilder
    private var networkIdentityStatus: some View {
        if let network = networkIdentity.currentNetwork {
            HStack {
                Text(networkIdentity.isNewNetwork ? "New network" : "Known network")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("seen \(network.timesSeen)×")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
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
            let detail = networkDisplay(info)
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

        let routerCheck = connectivity.checks.first { $0.label == OverallStatus.routerLabel }
        let localRouterLayer: ConnectionLayer
        if info == nil {
            // Same reasoning as Network above: no interface means no
            // router address was ever known to check, but that's a
            // certain consequence of the root cause, not genuine
            // uncertainty — cascade as unhealthy instead of `.unknown`.
            localRouterLayer = ConnectionLayer(id: "localRouter", label: "Local Router", detail: "—", status: .unhealthy)
        } else {
            localRouterLayer = ConnectionLayer(
                id: "localRouter",
                label: "Local Router",
                detail: routerCheck.map(checkDetail) ?? "Not checked",
                status: routerCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: routerCheck?.correlatedWithChange ?? false
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
            publicIPLayer = ConnectionLayer(id: "publicIP", label: "Public IP", detail: "—", status: .unhealthy)
        } else if publicIP.currentIP == nil {
            // Not a failure — `PublicIPViewModel`'s own (much slower,
            // 5-minute-cadence) lookup just hasn't completed yet, most
            // likely right after launch.
            publicIPLayer = ConnectionLayer(id: "publicIP", label: "Public IP", detail: "Not checked", status: .unknown)
        } else {
            publicIPLayer = ConnectionLayer(
                id: "publicIP",
                label: "Public IP",
                detail: publicIPCheck.map(checkDetail) ?? "Not checked",
                status: publicIPCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: publicIPCheck?.correlatedWithChange ?? false
            )
        }

        // Discovery (which hop is the ISP edge) and monitoring (is it still
        // reachable) are deliberately separate: `TracerouteViewModel` only
        // owns confirming *which* hop this is; `ConnectivityViewModel`
        // pings that hop's address on the same fast/reactive cadence as
        // Router/Internet/DNS/HTTP, so this reads like every other layer
        // here (a response time, not a re-trace's resolved hostname).
        let peRouterLayer: ConnectionLayer
        if traceroute.monitoredHop == nil {
            // Not a failure — you haven't confirmed which traceroute hop is
            // the ISP's edge yet (see the Path to Internet section).
            peRouterLayer = ConnectionLayer(id: "peRouter", label: "ISP Edge Router", detail: "Not confirmed", status: .unknown)
        } else {
            let peRouterCheck = connectivity.checks.first { $0.label == OverallStatus.peRouterLabel }
            peRouterLayer = ConnectionLayer(
                id: "peRouter",
                label: "ISP Edge Router",
                detail: peRouterCheck.map(checkDetail) ?? "Not checked",
                status: peRouterCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: peRouterCheck?.correlatedWithChange ?? false
            )
        }

        let internetCheck = connectivity.checks.first { $0.label == OverallStatus.internetLabel }
        let internetLayer = ConnectionLayer(
            id: "internet",
            label: "Internet Ping by address",
            detail: internetCheck.map(checkDetail) ?? "Not checked",
            status: internetCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: internetCheck?.correlatedWithChange ?? false
        )

        let dnsCheck = connectivity.checks.first { $0.label == OverallStatus.dnsLabel }
        let dnsLayer = ConnectionLayer(
            id: "dns",
            label: "DNS",
            detail: dnsCheck.map(checkDetail) ?? "Not checked",
            status: dnsCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: dnsCheck?.correlatedWithChange ?? false
        )

        let httpCheck = connectivity.checks.first { $0.label == OverallStatus.httpLabel }
        let httpLayer = ConnectionLayer(
            id: "http",
            label: "HTTP",
            detail: httpCheck.map(checkDetail) ?? "Not checked",
            status: httpCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: httpCheck?.correlatedWithChange ?? false
        )

        return [networkLayer, localRouterLayer, publicIPLayer, peRouterLayer, internetLayer, dnsLayer, httpLayer]
    }

    /// The lowest (most fundamental) unhealthy layer — everything failing
    /// *above* this one is presumed to be a consequence of this, not an
    /// independent problem, since each layer depends on the ones below it.
    private var rootCauseLayerID: String? {
        connectionLayersLowToHigh.first { $0.status == .unhealthy }?.id
    }

    @ViewBuilder
    private var connectionHealthSection: some View {
        let layers = connectionLayersLowToHigh
        VStack(alignment: .leading, spacing: 2) {
            ForEach(layers.reversed()) { layer in
                HStack {
                    Circle()
                        .fill(layerColor(for: layer))
                        .frame(width: 8, height: 8)
                    Text(layer.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    // Inline rather than on its own row: sized to one
                    // line of text, so it costs width but no height —
                    // the popover fits a 13" MacBook Air exactly.
                    // Absent for Network/Interface, which have no
                    // latency concept.
                    if let samples = latencyHistory[layer.id] {
                        Sparkline(samples: samples)
                    }
                    Text(layer.detail + (layer.status == .unhealthy && layer.correlatedWithChange ? " *" : ""))
                        .foregroundStyle(layer.status == .unhealthy ? layerColor(for: layer) : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12))
            }

            if layers.contains(where: { $0.status == .unhealthy && $0.correlatedWithChange }) {
                Text("* possibly related to a recent network change")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
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

    /// Live reachability for one SNMP device, straight from this round's
    /// `ConnectivityViewModel.checks` rather than anything SNMP itself
    /// reports — `poll()` only runs every 60s and answers a different
    /// question (did the descriptor/uptime change), so it lags well behind
    /// the 5s-capable ping check during and right after an outage. Matched
    /// by `displayName`, the same label `ConnectivityViewModel.buildTargets`
    /// files the ping result under — except the router: `buildTargets`
    /// deliberately excludes the router's own SNMP entry from the
    /// "infrastructure" targets (to avoid pinging it twice) and instead
    /// checks it once under the fixed `OverallStatus.routerLabel` ("Router"),
    /// which never equals its SNMP `displayName` (its `sysName`, e.g.
    /// "router"). Recognized by IP against the current interface's router
    /// address instead. `nil` (not yet checked this session, e.g. right
    /// after a fresh scan) reads as unknown/gray, not down.
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
    private var infrastructureList: some View {
        if !snmp.isAvailable {
            Text("snmpget unavailable on this macOS version")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if snmp.devices.isEmpty {
            Text(snmp.isScanning ? "Sweeping subnet…" : (snmp.lastScanAt == nil ? "Not scanned yet" : "No SNMP devices found"))
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if isCapturingScreenshot {
            VStack(alignment: .leading, spacing: 2) {
                infrastructureRows
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    infrastructureRows
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Same fixed-height ScrollView pattern used throughout this
            // popover — `.frame(maxHeight:)` alone can collapse to zero
            // visible height even with real content in this MenuBarExtra
            // context (confirmed directly earlier in this app's history).
            // Taller than the 90px other lists use, since sysDescr now
            // wraps instead of truncating and needs the extra room.
            .frame(height: 140)
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
    private var dhcpHistoryList: some View {
        if !DHCPLeaseService.isAvailable {
            Text("ipconfig unavailable on this macOS version")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if dhcpLease.history.isEmpty {
            Text("No DHCP lease observed yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if dhcpLease.history.count > 2 && !isCapturingScreenshot {
            // A fixed-height ScrollView only earns its keep once there are
            // actually more rows than fit — same reasoning as
            // `tracerouteSection`'s `displayedHops.count > 3` check. Below
            // that, it left visible blank space under 1-2 real entries.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    dhcpHistoryRows
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                dhcpHistoryRows
            }
        }
    }

    private var dhcpHistoryRows: some View {
        ForEach(dhcpLease.history) { record in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(dhcpPrimaryDetail(record))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(record.observedAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                Text(dhcpSecondaryDetail(record))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The densest jargon in the app, and the reason
                    // tooltips were built at all. Explains only the
                    // genuinely opaque parts — bcast/gw/dns need no
                    // gloss for this app's audience, while T1/T2 and a
                    // bare hex transaction ID do.
                    .appKitToolTip(Self.dhcpLeaseHelp, enabled: !isCapturingScreenshot)
            }
        }
    }

    /// The "Speed Test" tile's full content: the data-cost note (moved
    /// here from the header once the button moved into the tile's
    /// trailing slot, matching Path to Internet's "Trace Now"), any
    /// error, then the recent-runs list.
    @ViewBuilder
    private var speedTestTileContent: some View {
        HStack {
            Text("~50MB per run")
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
    /// differ from the last one. Same size-to-fit-else-scroll threshold
    /// as `dhcpHistoryList`: a fixed-height `ScrollView` only earns its
    /// keep once there are actually more rows than comfortably fit.
    @ViewBuilder
    private var speedTestList: some View {
        if networkQuality.recentRuns.isEmpty {
            Text(networkQuality.isRunning ? "Testing…" : "No speed test run yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if networkQuality.recentRuns.count > 3 && !isCapturingScreenshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    speedTestRows
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                speedTestRows
            }
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

    /// First line: server and assigned address/CIDR — the two fields
    /// that identify *this* lease at a glance, alongside the timestamp.
    private func dhcpPrimaryDetail(_ record: DHCPLeaseRecord) -> String {
        var address = record.assignedAddress
        if let mask = record.subnetMask, let prefix = SubnetCalculator.prefixLength(subnetMask: mask) {
            address += "/\(prefix)"
        }
        return "\(record.serverIdentifier) · \(address)"
    }

    /// Written for this app's stated audience — a network engineer, not
    /// a software developer — so it skips what that reader already knows
    /// (broadcast, gateway, DNS, search domain all read themselves) and
    /// covers only what the line genuinely doesn't explain: which of
    /// T1/T2 is which, and what the trailing hex value even is.
    private static let dhcpLeaseHelp = """
        T1 is the renewal timer (half the lease by default), T2 the \
        rebinding timer (87.5%). The trailing hex value is the DHCP \
        transaction ID — a new one means a genuinely new lease, renewal \
        or rebind, which is what this history keys on.
        """

    /// Second line: every other field `DHCPLeaseService` parses —
    /// deliberately not a curated subset, since the point of this list is
    /// seeing everything about a lease, not a guess at what's most
    /// interesting. `.lineLimit(1)` truncation is still the fallback for
    /// the rare case of several DNS servers or an unusually long domain,
    /// same convention used everywhere else in this popover — it isn't a
    /// promise every field always fits without it.
    private func dhcpSecondaryDetail(_ record: DHCPLeaseRecord) -> String {
        var parts: [String] = []
        if let broadcast = record.broadcastAddress { parts.append("bcast \(broadcast)") }
        if let router = record.router { parts.append("gw \(router)") }
        if !record.dnsServers.isEmpty { parts.append("dns \(record.dnsServers.joined(separator: ","))") }
        if let domain = record.domainName, !domain.isEmpty { parts.append(domain) }
        parts.append("lease \(DHCPLeaseInfo.durationText(record.leaseSeconds))")
        parts.append("T1 \(DHCPLeaseInfo.durationText(record.t1Seconds))")
        parts.append("T2 \(DHCPLeaseInfo.durationText(record.t2Seconds))")
        parts.append(record.transactionID)
        return parts.joined(separator: " · ")
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

    @ViewBuilder
    private var eventList: some View {
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
                .frame(height: 136, alignment: .top)
        } else if isCapturingScreenshot {
            VStack(alignment: .leading, spacing: 2) {
                eventRows
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    eventRows
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A fixed (not max) height — `maxHeight` alone lets the
            // ScrollView shrink to fit however few rows currently exist,
            // which is why a single event looked identical to before.
            // Message and timestamp now share one row instead of two, so
            // this is sized for ~8 single-line rows, not ~10 — trimmed by
            // two rows' worth (~34pt) to fit the popover within an M1
            // MacBook Air's shorter menu bar screen real estate.
            .frame(height: 136)
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

    @ViewBuilder
    private var tracerouteSection: some View {
        if let monitored = traceroute.monitoredHop {
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
            row("Suggested (unconfirmed)", suggested.hostname ?? suggested.address ?? "—")
            Text("Tap ★ next to the real ISP hop below to confirm — the first non-local hop isn't always right on networks with their own public IP space (e.g. campus/enterprise).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if traceroute.isRunning {
            Text("Tracing…")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if traceroute.hops.isEmpty {
            Text("Not traced yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }

        if let error = traceroute.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }

        if !traceroute.hops.isEmpty {
            // A fixed-height ScrollView only earns its keep when there are
            // actually more rows than fit — with a confirmed hop (the
            // common case), `displayedHops` is usually just 1-2 entries,
            // and a `.frame(height: 60)` sized for the worst case (3+ rows,
            // before confirmation) left visible blank space below them. A
            // plain VStack sizes to exactly what's there instead.
            if displayedHops.count > 3 && !isCapturingScreenshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        hopRows
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 60)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    hopRows
                }
            }
        }
    }

    @ViewBuilder
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

    private func eventColor(for event: AppEventRecord) -> Color {
        guard let kind = AppEventKind(rawValue: event.kind) else { return .primary }
        switch kind.polarity {
        case .positive: return .green
        case .negative: return .red
        case .neutral: return .primary
        }
    }

    /// Network name (if any) plus connection type combined into one row
    /// (e.g. "Thistle Wi-Fi", "Thistle Ethernet", or just "Ethernet" with
    /// no known name yet) instead of separate "Network"/"Interface" and
    /// "Type" rows, to save vertical space in the Info section. Prefers a
    /// user-assigned network label over the live Wi-Fi SSID over nothing
    /// at all — the raw interface hardware name (e.g. "USB 10/100/1000
    /// LAN") is dropped entirely here in favor of just the connection
    /// type, since it added little once a name or type is already shown.
    private func networkDisplay(_ info: NetworkInterfaceInfo) -> String {
        let type = info.isWiFi ? "Wi-Fi" : "Ethernet"
        let label = networkIdentity.currentNetwork?.label
        let name = (label?.isEmpty == false ? label : nil) ?? wifiSSID.currentSSID
        guard let name else { return type }
        return "\(name) \(type)"
    }

    /// Appends the router's MAC address (its `KnownNetwork` fingerprint, the
    /// same value used to recognize the network at all) in parentheses when
    /// it's already known, so a router swap or a VRRP failover between two
    /// physical boxes at the same IP is visible without cross-referencing
    /// the SNMP device list. Falls back to the bare IP before the first LAN
    /// scan of this session has recognized the network.
    private func routerDisplay(_ info: NetworkInterfaceInfo) -> String {
        guard let ip = info.routerAddress else { return "—" }
        guard let fingerprint = networkIdentity.currentNetwork?.fingerprint else { return ip }
        return "\(ip) (\(fingerprint))"
    }

    /// IP address and subnet mask combined into one CIDR-notation row
    /// (e.g. "10.0.0.152/24") instead of two separate rows, to save
    /// vertical space in the Info section.
    private func ipAddressDisplay(_ info: NetworkInterfaceInfo) -> String {
        guard let ip = info.ipAddress else { return "—" }
        guard let mask = info.subnetMask, let prefix = SubnetCalculator.prefixLength(subnetMask: mask) else {
            return ip
        }
        return "\(ip)/\(prefix)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
    }
}
