import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @ObservedObject var lanDiscovery: LANDiscoveryViewModel
    @ObservedObject var connectivity: ConnectivityViewModel
    @ObservedObject var networkIdentity: NetworkIdentityViewModel
    @ObservedObject var publicIP: PublicIPViewModel
    @ObservedObject var dhcpLease: DHCPLeaseViewModel
    @ObservedObject var wifiSSID: WiFiSSIDViewModel
    @ObservedObject var eventLog: EventLogViewModel
    @ObservedObject var traceroute: TracerouteViewModel
    @ObservedObject var bonjourDiscovery: BonjourDiscoveryViewModel
    @ObservedObject var snmp: SNMPViewModel
    /// Not `@ObservedObject` — a plain value computed once at launch (see
    /// `NMSApp`), not something that changes while the popover is open.
    let buildInfo: BuildInfoService.Info?

    @State private var communityDraft: String = ""
    @State private var isEditingCommunity = false

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
                    Spacer()
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
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(snmp.devices) { device in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Circle()
                                    .fill(deviceStatusColor(deviceReachability(device)))
                                    .frame(width: 8, height: 8)
                                Text(device.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(device.uptimeDescription)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            // No lineLimit here, deliberately — sysDescr
                            // (a raw SNMP-provided string, no length
                            // guarantee) wraps to as many lines as it
                            // needs instead of truncating, unlike the
                            // single-line convention used elsewhere in
                            // this popover.
                            // Addresses shown only when there's more than
                            // one — a single address is already implied by
                            // the row and would just cost a line.
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
        } else if dhcpLease.history.count > 2 {
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
            }
        }
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
                .frame(height: 170, alignment: .top)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(eventLog.events) { event in
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A fixed (not max) height — `maxHeight` alone lets the
            // ScrollView shrink to fit however few rows currently exist,
            // which is why a single event looked identical to before.
            // Message and timestamp now share one row instead of two, so
            // this is sized for ~10 single-line rows, not ~10 two-line ones.
            .frame(height: 170)
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
            if displayedHops.count > 3 {
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
