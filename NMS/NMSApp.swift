import AppKit
import SwiftUI
import SwiftData
import MenuBarExtraAccess

@main
struct NMSApp: App {
    // Every view model here is `@Observable` (`@State`), not
    // `ObservableObject` (`@StateObject`) — see `PUNCHLIST.md`'s
    // Observation migration entry.
    @State private var networkMonitor: NetworkMonitorViewModel
    @State private var lanDiscovery: LANDiscoveryViewModel
    @State private var connectivity: ConnectivityViewModel
    @State private var networkIdentity: NetworkIdentityViewModel
    @State private var publicIP: PublicIPViewModel
    @State private var ispIdentity: ISPIdentityViewModel
    @State private var dhcpLease: DHCPLeaseViewModel
    @State private var networkQuality: NetworkQualityViewModel
    @State private var wifiStressTest: WiFiStressTestViewModel
    @State private var wifiSSID: WiFiSSIDViewModel
    @State private var ethernetLink: EthernetLinkViewModel
    @State private var traceroute: TracerouteViewModel
    @State private var snmp: SNMPViewModel
    @State private var saasMonitoring: SaaSMonitoringViewModel
    @State private var ddns: DDNSViewModel
    @State private var firewallVisibility: FirewallVisibilityViewModel
    // Un-gated from `#if DEBUG`, 2026-08-12 -- `LocalDiagnosticServer`
    // itself stopped being debug-only as part of the popover conversion
    // (the popover's status lines/links need it in Release too, see that
    // type's own doc comment), so this property has to be constructible
    // in Release builds as well. Constructed in `init()` below, not here
    // via a default value, so `setSaaSMonitoring`/`setNetworkViewModels`
    // can run once at launch before it's wrapped in `State`.
    @State private var diagnosticServer: LocalDiagnosticServer
    // Owns its own `GlobalpingReverseTraceService()` (a plain stateless
    // struct, constructed fresh in `init()` below) rather than a
    // separate `NMSApp`-level property for it -- popover conversion,
    // Phase 5: Path Discovery's own trigger moved from the (deleted)
    // debug-only Debug Tools window into the popover's own Run Test ▾
    // menu, un-gated from `#if DEBUG` since it has to be constructible
    // in Release too.
    @State private var pathDiscoveryRunner: PathDiscoveryRunner
    /// Real, user-driven popover open/closed state — see `MenuBarView`'s
    /// own doc comment (once Phase 3 wires this through) for why this
    /// can't be `.task`/`.onAppear` on the popover's content instead;
    /// same `MenuBarExtraAccess`-backed pattern RoonWatch already uses.
    @State private var isMenuPresented: Bool = false

    // SwiftData requires the container to be kept alive for as long as
    // anything derived from it (like `mainContext`) is in use. Without this
    // property the container was a throwaway local in `init()` — it got
    // deallocated as soon as `init()` returned, leaving `mainContext`
    // pointing at a dead container and crashing on the first later fetch.
    private let modelContainer: ModelContainer
    /// Computed once at launch, not a `@Published`/computed-in-`body`
    /// property — `body` re-evaluates on every network change, and this
    /// shells out to `git`, so it belongs alongside `modelContainer` as a
    /// plain constant rather than being recomputed on every re-render.
    private let buildInfo: BuildInfoService.Info?
    /// The store's resolved location, captured once so `ContentView` can
    /// read its on-disk size fresh on every render (unlike `buildInfo`,
    /// file *size* genuinely changes during a run, so only the path is
    /// cached here — not a size snapshot that would go stale). Reusing
    /// `makeModelContainer()`'s own resolution rather than calling
    /// `storeURL()` a second time, which would log a duplicate `App.store`
    /// line at every launch.
    private let storeURL: URL
    /// Kept alongside the view models it backs rather than left as an
    /// `init()`-local, since `KnownNetworksView`'s Review sheet needs it
    /// directly (via explicit-fingerprint fetches) rather than through a
    /// specific view model — see `NetworkReviewViewModel`.
    private let snapshotStore: SnapshotStore

    init() {
        let (container, resolvedStoreURL) = Self.makeModelContainer()
        modelContainer = container
        storeURL = resolvedStoreURL
        let buildInfo = BuildInfoService.current()
        self.buildInfo = buildInfo
        UIStateLogger.log(
            "App.build",
            buildInfo.map { "\($0.shortHash)\($0.isDirty ? "+dirty" : "") — \($0.subject)" } ?? "unknown"
        )
        // Catches the override left set across a relaunch — the one case
        // `ConnectivityViewModel`'s own on-change log can't cover, since
        // it only fires from a *transition* and a key already set at
        // launch produces none. See `FailureInjector.activeOverridesSummary`.
        UIStateLogger.log("FailureInjector.activeOverrides", FailureInjector.activeOverridesSummary() ?? "none")
        // Started before any view model, so the beat covers the whole
        // launch sequence — the LAN scan, traceroute and connectivity
        // round kicked off below are exactly the kind of work a wedge
        // would happen during.
        UIStateLogger.startMainThreadHeartbeat()
        let store = SnapshotStore(context: container.mainContext)
        snapshotStore = store
        // Before any view model reads the device list: a store carrying
        // duplicate SNMP rows from the bug fixed in
        // `adoptUntaggedRecords` would otherwise crash the app on the next
        // poll. No-ops on a clean store. See `dedupeSNMPDevices`.
        store.dedupeSNMPDevices()
        let networkMonitor = NetworkMonitorViewModel(snapshotStore: store)
        let lanDiscovery = LANDiscoveryViewModel(snapshotStore: store)
        let networkIdentity = NetworkIdentityViewModel(snapshotStore: store)
        let publicIP = PublicIPViewModel(snapshotStore: store)
        let ispIdentity = ISPIdentityViewModel(snapshotStore: store)
        let dhcpLease = DHCPLeaseViewModel(snapshotStore: store, networkMonitor: networkMonitor)
        // No wiring into `wireDependencies` below, and no timer of its
        // own — deliberately never triggered automatically. See
        // `NetworkQualityViewModel`'s own doc comment.
        let networkQuality = NetworkQualityViewModel(snapshotStore: store)
        // Same "on-demand only, never auto-triggered" restraint as
        // `networkQuality` above.
        let wifiStressTest = WiFiStressTestViewModel(snapshotStore: store)
        let wifiSSID = WiFiSSIDViewModel(snapshotStore: store)
        let ethernetLink = EthernetLinkViewModel()
        let traceroute = TracerouteViewModel(snapshotStore: store)
        let connectivity = ConnectivityViewModel(
            networkMonitor: networkMonitor,
            traceroute: traceroute,
            publicIP: publicIP,
            snapshotStore: store
        )
        let snmp = SNMPViewModel(
            snapshotStore: store,
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            traceroute: traceroute
        )
        let saasMonitoring = SaaSMonitoringViewModel(snapshotStore: store)
        let ddns = DDNSViewModel(snapshotStore: store, publicIP: publicIP, traceroute: traceroute)
        let firewallVisibility = FirewallVisibilityViewModel(snapshotStore: store)
        // Two-phase: `SNMPViewModel` needs view models built alongside
        // `connectivity`, so the back-reference is injected once both exist.
        connectivity.attach(snmp: snmp)
        Self.wireDependencies(
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            connectivity: connectivity,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            ispIdentity: ispIdentity,
            dhcpLease: dhcpLease,
            wifiSSID: wifiSSID,
            ethernetLink: ethernetLink,
            traceroute: traceroute,
            snmp: snmp,
            networkQuality: networkQuality,
            wifiStressTest: wifiStressTest,
            saasMonitoring: saasMonitoring,
            ddns: ddns,
            firewallVisibility: firewallVisibility
        )
        _networkMonitor = State(wrappedValue: networkMonitor)
        _lanDiscovery = State(wrappedValue: lanDiscovery)
        _connectivity = State(wrappedValue: connectivity)
        _networkIdentity = State(wrappedValue: networkIdentity)
        _publicIP = State(wrappedValue: publicIP)
        _ispIdentity = State(wrappedValue: ispIdentity)
        _dhcpLease = State(wrappedValue: dhcpLease)
        _networkQuality = State(wrappedValue: networkQuality)
        _wifiStressTest = State(wrappedValue: wifiStressTest)
        _wifiSSID = State(wrappedValue: wifiSSID)
        _ethernetLink = State(wrappedValue: ethernetLink)
        _traceroute = State(wrappedValue: traceroute)
        _snmp = State(wrappedValue: snmp)
        _saasMonitoring = State(wrappedValue: saasMonitoring)
        _ddns = State(wrappedValue: ddns)
        _firewallVisibility = State(wrappedValue: firewallVisibility)

        let diagnosticServer = LocalDiagnosticServer()
        diagnosticServer.setSnapshotStore(store)
        diagnosticServer.setSaaSMonitoring(saasMonitoring)
        diagnosticServer.setNetworkViewModels(.init(
            viewModel: networkMonitor,
            connectivity: connectivity,
            wifiSSID: wifiSSID,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            ispIdentity: ispIdentity,
            traceroute: traceroute,
            dhcpLease: dhcpLease,
            ethernetLink: ethernetLink,
            ddns: ddns
        ))
        _diagnosticServer = State(wrappedValue: diagnosticServer)

        _pathDiscoveryRunner = State(wrappedValue: PathDiscoveryRunner(
            globalpingService: GlobalpingReverseTraceService(),
            diagnosticServer: diagnosticServer,
            snapshotStore: store,
            publicIP: publicIP,
            traceroute: traceroute,
            networkIdentity: networkIdentity,
            wifiSSID: wifiSSID
        ))

        // Recognize whatever network we're already on at launch, rather
        // than waiting for the next topology change to fire a scan.
        lanDiscovery.scan()
        wifiSSID.refresh(isWiFi: networkMonitor.currentInterface?.isWiFi ?? false)
        ethernetLink.refresh(
            isEthernet: networkMonitor.currentInterface?.isWiFi == false,
            device: networkMonitor.currentInterface?.interfaceName
        )
        // Same reasoning — `publicIP.currentIP` may already be a cached
        // value from last launch (`PublicIPViewModel.init()` reads
        // `snapshotStore.latestPublicIP()`), in which case
        // `onCurrentIPChanged` below would never fire this session since
        // nothing actually *changed*.
        ispIdentity.identify(ip: publicIP.currentIP)
    }

    /// Every cross-view-model connection in the app, split into four
    /// smaller functions below — one per `// MARK:` category this single
    /// function used to hold inline. Only two view models consume other
    /// view models' state — `ConnectivityViewModel` (reads
    /// `networkMonitor`, `traceroute`, `publicIP`, `snmp`) and
    /// `SNMPViewModel` (reads `networkMonitor`, `lanDiscovery`,
    /// `traceroute`) — so the whole dependency matrix is roughly eight
    /// edges and small enough to audit by reading these four functions,
    /// still called from exactly one place (`init()`).
    ///
    /// That matters because of a bug class this app has now hit three
    /// times. Every one of those reads is optional-chained with a silent
    /// fallback (`snmp?.devices ?? []`, `traceroute?.monitoredHop?.address`),
    /// so a dependency that isn't ready yet doesn't error — it quietly
    /// yields an incomplete result that then sits cached until some
    /// *timer* recomputes it. The ISP Edge Router row vanished for 30s
    /// that way, and the SNMP MAC merge for 60s. The fix in both cases
    /// was to make the recompute trigger belong to the dependency rather
    /// than the clock, which is what `wireDerivedStateDependencies` below
    /// does. An edge missing from that function is the shape this bug
    /// takes, so it should be possible to spot one by inspection instead
    /// of by user report.
    ///
    /// **Splitting these out was considered against a message-bus/pub-sub
    /// alternative and rejected in favor of this — see DESIGN-NOTES.md's
    /// "A message bus for cross-view-model events? Considered, rejected."**
    /// The problem being solved here is genuinely just "one function got
    /// long to read," not "these are too coupled" — pub-sub would trade
    /// away the exact property (a missing edge is visible by reading the
    /// wiring) that's caught three real bugs, in exchange for solving a
    /// readability problem four smaller functions already solve without
    /// that cost.
    private static func wireDependencies(
        networkMonitor: NetworkMonitorViewModel,
        lanDiscovery: LANDiscoveryViewModel,
        connectivity: ConnectivityViewModel,
        networkIdentity: NetworkIdentityViewModel,
        publicIP: PublicIPViewModel,
        ispIdentity: ISPIdentityViewModel,
        dhcpLease: DHCPLeaseViewModel,
        wifiSSID: WiFiSSIDViewModel,
        ethernetLink: EthernetLinkViewModel,
        traceroute: TracerouteViewModel,
        snmp: SNMPViewModel,
        networkQuality: NetworkQualityViewModel,
        wifiStressTest: WiFiStressTestViewModel,
        saasMonitoring: SaaSMonitoringViewModel,
        ddns: DDNSViewModel,
        firewallVisibility: FirewallVisibilityViewModel
    ) {
        wireTopologyChangeFanOut(
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            connectivity: connectivity,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            ispIdentity: ispIdentity,
            dhcpLease: dhcpLease,
            wifiSSID: wifiSSID,
            ethernetLink: ethernetLink,
            traceroute: traceroute,
            ddns: ddns
        )
        wireDerivedStateDependencies(
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            connectivity: connectivity,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            ispIdentity: ispIdentity,
            traceroute: traceroute,
            snmp: snmp
        )
        wireReachabilityTransitions(
            connectivity: connectivity,
            publicIP: publicIP,
            traceroute: traceroute,
            networkQuality: networkQuality
        )
        wireHistoryRefresh(
            networkMonitor: networkMonitor,
            connectivity: connectivity,
            publicIP: publicIP,
            ispIdentity: ispIdentity,
            dhcpLease: dhcpLease,
            wifiSSID: wifiSSID,
            networkIdentity: networkIdentity,
            snmp: snmp,
            traceroute: traceroute,
            saasMonitoring: saasMonitoring,
            networkQuality: networkQuality,
            wifiStressTest: wifiStressTest,
            ddns: ddns,
            firewallVisibility: firewallVisibility
        )
    }

    /// A change to the Mac's own interface/IP/router invalidates nearly
    /// everything, so it re-runs nearly everything.
    private static func wireTopologyChangeFanOut(
        networkMonitor: NetworkMonitorViewModel,
        lanDiscovery: LANDiscoveryViewModel,
        connectivity: ConnectivityViewModel,
        networkIdentity: NetworkIdentityViewModel,
        publicIP: PublicIPViewModel,
        ispIdentity: ISPIdentityViewModel,
        dhcpLease: DHCPLeaseViewModel,
        wifiSSID: WiFiSSIDViewModel,
        ethernetLink: EthernetLinkViewModel,
        traceroute: TracerouteViewModel,
        ddns: DDNSViewModel
    ) {
        // `[weak networkMonitor]` because this closure is stored *on*
        // `networkMonitor` and also reads it (for `currentInterface`
        // below) — the one self-referential edge in this whole wiring
        // graph, and so the one retain cycle. Every other assignment here
        // captures a different object than the one it's stored on. Doesn't
        // leak today, since these all live for the process lifetime, but
        // it would the moment any of them became per-scene.
        networkMonitor.onChangePersisted = { [weak networkMonitor] snapshot in
            // Clears recognition and the store's current-network
            // fingerprint immediately, before the LAN scan below can
            // re-recognize whatever network this change lands on —
            // without this, anything recorded during that gap (a DHCP
            // lease, an SNMP poll, an event) would be tagged with the
            // *previous* network's fingerprint. See
            // `NetworkIdentityViewModel.reset`. Its return value is the
            // fingerprint just cleared — passed to `wifiSSID.refresh`
            // below so a network-change event it logs still lands under
            // the network it's actually about, not wherever
            // `currentNetworkFingerprint` has moved on to by then.
            let departingFingerprint = networkIdentity.reset()
            // Cleared here too, not just `SnapshotStore`'s fingerprint —
            // see `ISPIdentityViewModel.reset()`'s doc comment for the
            // "old ISP info shows up in new networks" bug this closes.
            ispIdentity.reset()
            // Same reasoning, for the confirmed ISP Edge Router hop — see
            // `TracerouteViewModel.reloadMonitoredHop()`'s doc comment.
            // This first call reads back `nil` (fingerprint was just
            // cleared above); the second, from `onNetworkRecognized`
            // below, re-populates it for whichever network this change
            // actually lands on.
            traceroute.reloadMonitoredHop()
            // Same immediate-clear need as the two calls above: reads back
            // "not home" the instant the fingerprint is nil'd, which is
            // what actually fixes DDNS displaying the home network's setup
            // while connected elsewhere — see `DDNSViewModel`'s doc
            // comment. `onNetworkRecognized` below re-runs this for real
            // once the new network is known.
            ddns.checkAll()
            // Re-populate immediately with whatever `publicIP.currentIP`
            // already holds, the same direct-call pattern `init()` uses
            // for the equivalent launch-time case (see its own comment
            // there) — `identify(ip:)`'s own `nil`-ip guard makes this a
            // no-op if nothing's known yet. Needed because the only other
            // path back from `reset()`, `onCurrentIPChanged`, is gated on
            // the public IP's *value* actually changing: a flaky
            // reconnect that resolves back to the same IP already
            // recorded correctly stays silent there, but `reset()` above
            // already unconditionally cleared the display moments
            // earlier — with nothing else left to call `identify(ip:)`
            // again, the row stayed blank indefinitely. Confirmed live at
            // an off-site location with genuinely bad Wi-Fi (see
            // BUGS.md): a third reconnect within ~10 seconds, back to the
            // same network and the same already-known public IP, never
            // recovered without this.
            ispIdentity.identify(ip: publicIP.currentIP)
            lanDiscovery.scan(for: snapshot)
            // A topology change is the most likely moment the public IP
            // actually changed, so check it right away rather than waiting
            // for the next periodic tick.
            publicIP.check()
            // Same for the Wi-Fi SSID — e.g. unplugging Ethernet and
            // falling back to Wi-Fi is exactly this kind of change.
            wifiSSID.refresh(
                isWiFi: networkMonitor?.currentInterface?.isWiFi ?? false,
                departingNetworkFingerprint: departingFingerprint
            )
            // Same reasoning, the Ethernet-side counterpart — falling
            // back *to* Ethernet, or moving to a different switch port
            // on the same cable, is exactly when the negotiated link
            // speed is likely to have changed too.
            ethernetLink.refresh(
                isEthernet: networkMonitor?.currentInterface?.isWiFi == false,
                device: networkMonitor?.currentInterface?.interfaceName
            )
            // A topology change (new network, interface failover) is
            // exactly the moment a DHCP lease is likely to have changed
            // too, rather than waiting up to 5 minutes for the next poll.
            dhcpLease.check()
            // A new network means a genuinely different set of reachable
            // printers (CUPS' own configured list doesn't change, but
            // which of them are actually on this LAN does) — re-read
            // rather than waiting for the next launch to notice.
            connectivity.refreshConfiguredPrinters()
            // The path to the internet (and the ISP edge router) can change
            // along with the topology change itself, so re-trace now rather
            // than waiting up to 10 minutes for the next periodic run.
            traceroute.run()
            // Router/internet/DNS/HTTP reachability is exactly what just
            // changed too (e.g. an interface coming back up, or a failover
            // to a different one) — re-check now instead of leaving Network
            // Health showing stale router/internet/DNS/HTTP status for up
            // to 30s until the next periodic round.
            connectivity.runChecks()
        }
    }

    /// The edges that exist specifically so a consumer re-derives when its
    /// dependency resolves, instead of waiting for a timer. Each one here
    /// corresponds to a real bug that shipped without it.
    private static func wireDerivedStateDependencies(
        networkMonitor: NetworkMonitorViewModel,
        lanDiscovery: LANDiscoveryViewModel,
        connectivity: ConnectivityViewModel,
        networkIdentity: NetworkIdentityViewModel,
        publicIP: PublicIPViewModel,
        ispIdentity: ISPIdentityViewModel,
        traceroute: TracerouteViewModel,
        snmp: SNMPViewModel
    ) {
        // `ConnectivityViewModel.buildTargets` reads
        // `traceroute.monitoredHop` to decide whether to include the ISP Edge
        // Router target. `traceroute.run()` is async, so the first check round
        // at launch runs before any hop exists and silently omits the row —
        // invisible for up to 30s. Also covers every later trace, so a changed
        // edge-router address is picked up at once.
        traceroute.onTraceCompleted = { connectivity.runChecks() }

        // `SNMPViewModel.rebuildDeviceList` reads `lanDiscovery.devices` for
        // the MACs behind its merge (one device answering at several
        // addresses). `lanDiscovery.scan()` is async — it had to be, to stop
        // `arp` blocking the main thread — so `SNMPViewModel.init()` rebuilds
        // before any MAC exists and the merge didn't land for 60s.
        // `networkIdentity` shares this edge: recognizing a network needs the
        // router's MAC, which only a LAN scan can supply.
        lanDiscovery.onScanCompleted = { devices in
            networkIdentity.recognize(
                routerAddress: networkMonitor.currentInterface?.routerAddress,
                subnetMask: networkMonitor.currentInterface?.subnetMask,
                from: devices
            )
            snmp.rebuildDeviceList()
        }

        // The retry half of the fix in `NetworkIdentityViewModel.recognize`
        // for `BUGS.md`'s "Known Networks silently never adds an
        // unfamiliar network": a scan that ran too early for the OS to
        // have ARP-resolved the router yet used to leave that network
        // unrecognized for the rest of the session, with nothing to
        // retrigger recognition. 3s is long enough for the OS to catch up
        // (this exact race, after a Wi-Fi reconnect, is what
        // `SNMPViewModel.refreshARPIfMergeDataIsStale`'s own doc comment
        // already describes) without meaningfully delaying a legitimately
        // new network's first recognition. Capped at one retry by
        // `NetworkIdentityViewModel.hasRequestedRetry`, not here.
        networkIdentity.onRecognitionPending = { [weak lanDiscovery] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                lanDiscovery?.scan()
            }
        }

        // `ConnectivityViewModel.buildTargets` pings the SNMP device list as
        // its infrastructure targets, reading it as `snmp?.devices ?? []`.
        // `connectivity` is constructed *before* `snmp` (the back-reference is
        // injected afterward by `attach(snmp:)`), so the first check round at
        // launch runs with `snmp` still nil and monitors no infrastructure at
        // all. Until this edge existed it recovered only because
        // `onTraceCompleted` above rebuilt the target list ~500ms later and
        // happened to pick up SNMP too — a neighbour masking a missing edge,
        // which is exactly what this grouping is meant to make visible.
        // Found by the "unavailable: snmpDevices" line in the state log.
        snmp.onDeviceListChanged = { connectivity.runChecks() }

        // `ConnectivityViewModel.buildTargets` also reads `publicIP.currentIP`
        // for the Public IP ping target, and `check()` is an async network
        // fetch — same shape as the two edges above. Observed directly: the
        // target was absent for the first two rounds at launch, appearing
        // only 30 seconds in in via the periodic timer rather than anything
        // noticing the fetch had resolved. This closes the last of
        // `ConnectivityViewModel`'s four dependencies.
        //
        // Also the moment the ISP identity itself needs re-checking — a
        // public IP change is exactly when the owning allocation (and so
        // the registrant `ISPIdentityService.identify` would return)
        // could have changed too.
        publicIP.onCurrentIPChanged = {
            connectivity.runChecks()
            ispIdentity.identify(ip: publicIP.currentIP)
        }
    }

    /// An upstream failure (e.g. a switch between the local router and the
    /// ISP) doesn't touch the Mac's own interface/IP/router, so
    /// `onChangePersisted` never fires for it — the raw IP check failing is
    /// the earliest signal something broke upstream.
    private static func wireReachabilityTransitions(
        connectivity: ConnectivityViewModel,
        publicIP: PublicIPViewModel,
        traceroute: TracerouteViewModel,
        networkQuality: NetworkQualityViewModel
    ) {
        connectivity.onInternetUnreachable = { traceroute.run() }
        // The recovery counterpart. The trace fired above runs while the path
        // is still down, so it fails and clears the monitored hop, removing
        // the ISP Edge Router target entirely — leaving an outage with no
        // matching recovery until the next periodic trace up to 10 minutes
        // later. Re-tracing on recovery restores the hop and the check.
        connectivity.onInternetReachable = {
            traceroute.run()
            // Same stale-after-recovery problem, different symptom: a public
            // IP fetch that fails mid-transition leaves `lastError` set, and
            // the popover renders it verbatim — so URLError's "The Internet
            // connection appears to be offline." sat under Info while every
            // Network Health row was green, until the next 5-minute tick.
            publicIP.check()
            // Same bug, third symptom: Speed Test's own `lastError` is just
            // as sticky, and reported directly — Ethernet reconnecting
            // still showed "offline" until a manual re-run. Cleared, not
            // re-fetched: a real Speed Test transfer must never happen
            // without the user asking for it.
            networkQuality.clearStaleErrorOnRecovery()
        }
    }

    /// Re-checks exposure on a router/firmware signal, plus the one thing
    /// that makes *already-stored* history readable at all once a network
    /// is recognized (see `onNetworkRecognized` below). Used to also fan
    /// out an `onEventLogged` refresh to `EventLogViewModel` for every
    /// producer that could write an `AppEventRecord` — removed alongside
    /// `EventsTile`/`EventLogViewModel` themselves (popover conversion,
    /// Phase 4): `/log` already reads `AppEventRecord` history directly
    /// from `SnapshotStore` on every request, no view-model cache to
    /// invalidate.
    private static func wireHistoryRefresh(
        networkMonitor: NetworkMonitorViewModel,
        connectivity: ConnectivityViewModel,
        publicIP: PublicIPViewModel,
        ispIdentity: ISPIdentityViewModel,
        dhcpLease: DHCPLeaseViewModel,
        wifiSSID: WiFiSSIDViewModel,
        networkIdentity: NetworkIdentityViewModel,
        snmp: SNMPViewModel,
        traceroute: TracerouteViewModel,
        saasMonitoring: SaaSMonitoringViewModel,
        networkQuality: NetworkQualityViewModel,
        wifiStressTest: WiFiStressTestViewModel,
        ddns: DDNSViewModel,
        firewallVisibility: FirewallVisibilityViewModel
    ) {
        // See `FirewallVisibilityViewModel.handleRouterSignal()`'s doc
        // comment: a router reboot or firmware change can silently reset
        // port-forwarding rules, so it's worth re-checking exposure.
        snmp.onRouterOrFirewallSoftwareEvent = { firewallVisibility.handleRouterSignal() }

        // This covers stored data that was already there: these view
        // models fetch once in `init`, before the first LAN scan has
        // resolved which network this is, so they come back empty and —
        // until now — nothing re-ran them. DHCP history only re-read when
        // a lease changed, typically a day out; Speed Test history only
        // re-read after a fresh run, which may never happen this session.
        //
        // SNMP needs no equivalent here: `rebuildDeviceList()` is already
        // called from `lanDiscovery.onScanCompleted`, the same scan whose
        // completion drives recognition in the first place.
        networkIdentity.onNetworkRecognized = {
            dhcpLease.reloadHistory()
            // `check()`, not just `reloadHistory()`: the launch/topology-
            // change check that raced ahead of recognition (see
            // `SnapshotStore.recordDHCPLeaseIfChanged`'s doc comment) is
            // now correctly a no-op instead of a duplicate row, so this
            // re-runs it under the now-known fingerprint rather than
            // leaving that data point to wait out the full 300s timer.
            dhcpLease.check()
            networkQuality.reloadHistory()
            wifiStressTest.reloadHistory()
            traceroute.reloadMonitoredHop()
            // Real check, not just a reload: unlike the history reloads
            // above, DDNS has no persisted per-network history to re-read
            // — this is what actually re-populates it once the newly
            // recognized network turns out to be home, rather than
            // waiting out `FeatureFlags.ddnsCheckInterval`.
            ddns.checkAll()
            // Opt-in only (`FeatureFlags.autoBaselineNetworkQuality`'s own
            // doc comment has the why) — never on the very first time
            // this Mac has ever seen a network (`isNewNetwork`), so a
            // network passed through once, never revisited, never gets
            // an uninvited real bandwidth-under-load test run against it.
            if FeatureFlags.autoBaselineNetworkQuality, !networkIdentity.isNewNetwork {
                networkQuality.runQuickCheck(interfaceName: networkMonitor.currentInterface?.interfaceName)
            }
        }
    }

    /// Opens a diagnostic-server page in the system browser — same
    /// `NSWorkspace.shared.open(url)`-via-`diagnosticServerURL(path:)`
    /// shape RoonWatch's own `openDiagnostics` closure already uses, a
    /// deliberate choice (not an embedded `WKWebView`) recorded in the
    /// plan doc's "Decided, not open" list. Passed into `MenuBarView`
    /// below, which calls it for every status line/link tap.
    private func openDiagnostics(path: String) {
        Task {
            guard let url = await diagnosticServer.diagnosticServerURL(path: path) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    var body: some Scene {
        // Popover conversion, Phase 2 (scene rewrite) -- the original
        // `Window("NMS", ...)` this replaced (Phase 0's spike target) is
        // gone for good now, not just swapped out temporarily; its
        // replacement is `MenuBarView`/`MenuBarIcon`. `MenuBarView`
        // itself is still Phase 0's placeholder content -- real view-model
        // wiring is Phase 3's job, not this one.
        // `.menuBarExtraAccess` must be the first scene modifier after
        // `MenuBarExtra` -- it's declared as an extension on the concrete
        // `MenuBarExtra` type, not the general `Scene` protocol, so it
        // has to run before `.menuBarExtraStyle` erases that to `some
        // Scene` (confirmed directly, RoonWatch already hit this).
        MenuBarExtra {
            MenuBarView(
                viewModel: networkMonitor,
                connectivity: connectivity,
                wifiSSID: wifiSSID,
                ethernetLink: ethernetLink,
                dhcpLease: dhcpLease,
                traceroute: traceroute,
                networkQuality: networkQuality,
                wifiStressTest: wifiStressTest,
                snmp: snmp,
                saasMonitoring: saasMonitoring,
                firewallVisibility: firewallVisibility,
                pathDiscoveryRunner: pathDiscoveryRunner,
                storeURL: storeURL,
                openDiagnostics: openDiagnostics
            )
        } label: {
            MenuBarIcon(status: OverallStatus.computeForPopover(
                interfaceIsDown: networkMonitor.currentInterface == nil,
                checks: connectivity.checks,
                dhcpIsAbnormal: dhcpLease.isFallenBackToLinkLocal || dhcpLease.isRenewalOverdue
            ))
        }
        .menuBarExtraAccess(isPresented: $isMenuPresented)
        .menuBarExtraStyle(.window)

        // A separate window rather than a sheet — see
        // `KnownNetworksView`'s doc comment.
        Window("Known Networks", id: "known-networks") {
            KnownNetworksView(networkIdentity: networkIdentity, snapshotStore: snapshotStore)
        }
        .defaultSize(width: 460, height: 320)

        // A real `Settings` scene now, not a plain `Window` -- see
        // `PreferencesView`'s doc comment for why it used to avoid this
        // (`.accessory` + `MenuBarExtra` makes `Settings`'s automatic
        // Preferences-menu/⌘, wiring reliable, unlike the `.regular`,
        // no-real-menu-bar situation that reasoning was written for).
        // Still gets `PreferencesView.body`'s own `ScrollView` for a
        // MacBook-Air-height window, same reasoning as before.
        Settings {
            PreferencesView()
        }
    }

    /// Falls back to an in-memory store if the on-disk store can't be
    /// opened (e.g. a corrupted database after a schema change), so a
    /// storage problem degrades to "history isn't saved this run" rather
    /// than the menu bar app failing to launch.
    ///
    /// **Explicit, app-specific store URL — not the SwiftData default.**
    /// `ModelConfiguration(schema:)` with no `url:` resolves to a bare
    /// `~/Library/Application Support/default.store` — a generic filename
    /// with no per-app namespacing at all. Confirmed directly via `lsof`
    /// that this app was NOT the only process on the Mac open on that
    /// exact path: `/usr/libexec/icloudmailagent`, a completely unrelated
    /// system daemon, had the same file open read/write at the same time,
    /// apparently for the same reason (it also left its own store
    /// unnamed). Two independent processes issuing SQLite writes/locks
    /// against one physical file is a real collision, not a hypothetical
    /// one — it produced a beachballed, genuinely unkillable (`kill -9`
    /// had no effect) NMS process, consistent with the main thread wedged
    /// in an uninterruptible wait on a contended file lock. Namespacing
    /// under a dedicated `NMS/` subdirectory, matching the pattern already
    /// used for `UIStateLogger`'s log file, makes this collision
    /// structurally impossible rather than just unlikely.
    /// The real store, unless a debug override points somewhere else.
    ///
    /// ```
    /// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSStorePath /tmp/nms-test/scratch.store
    /// defaults delete ~/Library/Preferences/Thistle.NMS.plist NMSStorePath
    /// ```
    ///
    /// Exists so scripted scenarios stop polluting real history.
    /// Injected failures write genuine `AppEventRecord` and
    /// `ConnectivityCheckRecord` rows, so every test run permanently
    /// added `[injected]` entries to the same event log and DHCP history
    /// the app exists to keep honest — twice already they had to be
    /// deleted by hand. Pointing a run at a throwaway path makes that
    /// structurally impossible instead of a cleanup step someone has to
    /// remember.
    ///
    /// Also gives scenarios a *known* starting state, which matters for
    /// more than tidiness: SNMP restart detection compares against a
    /// previously stored uptime, so against a fresh store the first poll
    /// is `.firstSeen` and logs nothing. A script wanting that event must
    /// let two polls run — obvious when starting from empty, invisible
    /// when starting from whatever happened to be there.
    ///
    /// `#if DEBUG` like the rest of the debug tooling. Parent directories
    /// are created if missing, and the path is logged at launch, because
    /// silently running against a different store than expected would be
    /// a genuinely confusing way to lose an afternoon.
    private static func storeURL() -> URL {
        let defaultURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NMS", isDirectory: true)
            .appendingPathComponent("default.store")

        #if DEBUG
        var resolved = defaultURL
        if let override = UserDefaults.standard.string(forKey: "NMSStorePath"), !override.isEmpty {
            resolved = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        #else
        let resolved = defaultURL
        #endif

        try? FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        UIStateLogger.log("App.store", resolved.path)
        return resolved
    }

    /// Returns the resolved store URL alongside the container — not just
    /// for logging (that already happens inside `storeURL()`), but so
    /// `ContentView` can read the store's on-disk size later. In the
    /// in-memory fallback path there's no real file at this path at all;
    /// `StoreSizeService` already reports that case as `nil` (the base
    /// file genuinely doesn't exist there) rather than a misleading zero,
    /// so no special-casing is needed here for it.
    /// Non-nil when the on-disk store could not be opened and the app is
    /// running against a throwaway in-memory container instead — i.e.
    /// every persisted history is empty and nothing written this session
    /// will survive quitting.
    ///
    /// Exists because the failure used to be invisible. The fallback's
    /// only signal was a `print()`, which reaches stdout and nowhere else
    /// — not `UIStateLogger`, so not `ui-state.log`, not a state dump, and
    /// not a bug report. An empty Events list renders the friendly
    /// "No events yet — everything's healthy" copy, so a store that
    /// wouldn't open looked exactly like a quiet, well-behaved network.
    /// That went unnoticed for two days across several bug reports; see
    /// `BUGS.md`. Serving an empty database in place of the real one is
    /// worth saying out loud.
    private(set) static var storeFallbackReason: String?

    /// The actual detect-and-fall-back logic, factored out from
    /// `makeModelContainer()` so it's testable against a schema/URL a
    /// test fully controls — not `private`, unlike the function below,
    /// specifically for that reason (`NMSTests` reaches it via
    /// `@testable import`, same reasoning as `SaaSStatusService`'s
    /// parsers).
    ///
    /// A **literal** schema-migration mismatch (the real historical bug
    /// — see `BUGS.md`, "The persistent store fails to open") needs two
    /// different compiled versions of the same model class, which isn't
    /// constructible within one test run. What's tested instead, and
    /// what actually matters most: does *any* store-open failure get
    /// detected and reported rather than silently swallowed — that
    /// silence, not the specific migration trigger, was the two-day
    /// bug's real failure mode (a single `print()`, reaching nowhere
    /// `UIStateLogger`/a bug report/a state dump would show it).
    static func openStoreWithFallback(schema: Schema, url: URL) -> (container: ModelContainer, fallbackReason: String?) {
        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            return (container, nil)
        } catch {
            let reason = (error as NSError).localizedDescription
            let container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            return (container, reason)
        }
    }

    private static func makeModelContainer() -> (ModelContainer, URL) {
        let schema = Schema([
            NetworkSnapshot.self,
            DiscoveredDeviceRecord.self,
            ConnectivityCheckRecord.self,
            KnownNetwork.self,
            PublicIPRecord.self,
            DHCPLeaseRecord.self,
            NetworkQualityRecord.self,
            AppEventRecord.self,
            ProviderEdgeRecord.self,
            SNMPDeviceRecord.self,
            WiFiSampleRecord.self,
            WiFiStressTestRecord.self,
            FirewallScanRecord.self
        ])
        let storeURL = Self.storeURL()
        let (container, reason) = openStoreWithFallback(schema: schema, url: storeURL)
        if let reason {
            // Deliberately recorded three ways, because the single
            // `print()` this used to be reached none of the places anyone
            // actually looks. `UIStateLogger` puts it in `ui-state.log`
            // and therefore in every state dump and bug report; the
            // static above drives a visible banner in the popover.
            Self.storeFallbackReason = reason
            UIStateLogger.log(
                "App.storeFallback",
                "could not open \(storeURL.path) — running in memory, all history is unavailable and nothing will persist: \(reason)"
            )
            print("NMS: failed to open persistent store (\(reason)); falling back to in-memory store")
        }
        return (container, storeURL)
    }
}
