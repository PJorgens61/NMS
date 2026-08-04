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
///
/// Every `Grid` row is now its own `View` type too (`QuickCheckRow`,
/// `ConnectionLayerRow`, `DHCPStatusRow`) plus `DDNSRow` below the grid
/// — see `PUNCHLIST.md`'s view-structure factoring entry. This tile
/// itself still reruns its whole `body` on any of its nine view models
/// changing (it has no invalidation boundary of its own beyond what its
/// children provide), but each row is now a separate value-input `View`
/// that SwiftUI's own struct diffing can skip re-rendering when its
/// specific inputs didn't change — narrower than before, where every
/// row's content lived inline in this type's own body and reran
/// together regardless of which view model actually changed.
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
        // Split so `DHCPStatusRow` can sit between Router and Network
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
        // Computed once per `body` evaluation and passed down as a plain
        // value — `ConnectionLayerRow` doesn't need to recompute it (or
        // depend on `connectionLayersLowToHigh` at all) for every row.
        let rootCauseLayerID = self.rootCauseLayerID
        VStack(alignment: .leading, spacing: 2) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                // At the top, not the bottom — the most aggregate,
                // most-dependent-on-everything-else signal of the set
                // (see `PUNCHLIST.md`'s "Network Health and Info tiles"
                // item for the full row-ordering reasoning: this Grid
                // reads top-to-bottom as most-dependent to most-
                // fundamental, matching `layers.reversed()` below).
                QuickCheckRow(networkQuality: networkQuality, interfaceName: viewModel.currentInterface?.interfaceName)
                ForEach(aboveNetwork) { layer in
                    ConnectionLayerRow(layer: layer, rootCauseLayerID: rootCauseLayerID, sparklineValues: sparklineValues(for: layer))
                }
                // Between Router and Network, not slotted into
                // `connectionLayersLowToHigh` itself — DHCP isn't a
                // `ConnectivityCheck`-backed reachability signal like
                // every other row here, it's a three-state identity
                // check (normal/changed/abnormal), which `LayerStatus`
                // has no clean case for (`.unknown` already means "gray,
                // nothing to judge yet," not "yellow, something changed
                // recently"). See `DHCPStatusRow`'s own doc comment for
                // what each color means.
                DHCPStatusRow(dhcpLease: dhcpLease)
                if let networkLayer {
                    ConnectionLayerRow(layer: networkLayer, rootCauseLayerID: rootCauseLayerID, sparklineValues: sparklineValues(for: networkLayer))
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
            // configured (see `DDNSRow`).
            DDNSRow(ddns: ddns)
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

    /// The values `ConnectionLayerRow` should chart for a given layer —
    /// `nil` when there's nothing to chart yet. Network's own sparkline
    /// (Wi-Fi only — Ethernet has no signal strength to chart) uses RSSI
    /// history from `wifiSSID.recentSamples`, not `latencyHistory`: that
    /// row isn't a ping-latency check, so `latencyHistory` has no entry
    /// for it at all. Same values/reversal `WiFiTile`'s own Signal row
    /// already uses for the identical chart.
    private func sparklineValues(for layer: ConnectionLayer) -> [Double?]? {
        if layer.id == "network", viewModel.currentInterface?.isWiFi == true,
           wifiSSID.recentSamples.count > 1 {
            return wifiSSID.recentSamples.reversed().map { $0.rssi.map(Double.init) }
        } else if let samples = latencyHistory[layer.id] {
            return samples.map(\.latencyMs)
        }
        return nil
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
    /// On Wi-Fi, the live SSID is the *only* name used — never the
    /// `KnownNetwork` label, not even as a fallback before the SSID
    /// resolves. Two reasons stack here. First, reported directly:
    /// `KnownNetwork` is keyed by router MAC + subnet, not SSID (see
    /// that type's own doc comment), so the same physical LAN reached
    /// over Ethernet and Wi-Fi shares one label — a label set from the
    /// Ethernet side has no business describing the Wi-Fi radio's own
    /// identity. Second, confirmed live (2026-08-04): network
    /// *recognition* (which sets the label, via the LAN scan matching
    /// the router's MAC) can finish before Wi-Fi *SSID sampling* does —
    /// that one needs Location authorization granted first, then a
    /// radio query — so falling back to the label produced a real,
    /// visible flash at launch: the label appeared briefly, then
    /// flipped to the live SSID moments later once sampling caught up.
    /// A bare "Wi-Fi" placeholder until the SSID itself resolves reads
    /// as "still finding out," which is the truth; a label that's about
    /// to be silently replaced doesn't. Off Wi-Fi there's no live-SSID
    /// equivalent, so the label is still the best available name there.
    private func networkDisplay(_ info: NetworkInterfaceInfo) -> String {
        let type = info.isWiFi ? "Wi-Fi" : "Ethernet"
        let label = networkIdentity.currentNetwork?.label
        let name: String? = info.isWiFi
            ? wifiSSID.currentSSID
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
            // Only ever consulted below inside `info.isWiFi && !hasName`,
            // so this only needs to mean "the live SSID has resolved" —
            // not the `KnownNetwork` label, even if that already has
            // (see `networkDisplay(_:)`'s own doc comment for why the
            // label doesn't count as a Wi-Fi name at all anymore). Keeps
            // the status dot and the detail text agreeing: both read
            // "not yet known" together, rather than the dot claiming
            // `.healthy` while the text still shows a bare "Wi-Fi"
            // placeholder.
            let hasName = wifiSSID.currentSSID != nil
            // On Wi-Fi this row *also* shows a signal-strength sparkline
            // (see `sparklineValues(for:)`), alongside the name via
            // `networkDisplay(_:)` — not instead of it. **Bug, confirmed
            // live (2026-08-04): this used to hardcode the literal
            // string "Wi-Fi" for the Wi-Fi case instead of calling
            // `networkDisplay(info)`, so the SSID never actually
            // rendered anywhere in this row** — the sparkline occupies a
            // separate `Grid` column from the detail text, it doesn't
            // stand in for the name textually. Fixed to call
            // `networkDisplay(info)` unconditionally, matching what its
            // own doc comment already claimed happened.
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
            let detail = networkDisplay(info) + " · \(ipAddressDisplay(info))" + knownNetworkSuffix
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
}
