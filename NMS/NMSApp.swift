import SwiftUI
import AppKit
import SwiftData

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory = menu bar only, no Dock icon, no app switcher entry.
        // This is the standard pattern for background utility apps.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct NMSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var networkMonitor: NetworkMonitorViewModel
    @StateObject private var lanDiscovery: LANDiscoveryViewModel
    @StateObject private var connectivity: ConnectivityViewModel
    @StateObject private var networkIdentity: NetworkIdentityViewModel
    @StateObject private var publicIP: PublicIPViewModel
    @StateObject private var dhcpLease: DHCPLeaseViewModel
    @StateObject private var wifiSSID: WiFiSSIDViewModel
    @StateObject private var eventLog: EventLogViewModel
    @StateObject private var traceroute: TracerouteViewModel
    @StateObject private var bonjourDiscovery: BonjourDiscoveryViewModel
    @StateObject private var snmp: SNMPViewModel

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

    init() {
        let container = Self.makeModelContainer()
        modelContainer = container
        let buildInfo = BuildInfoService.current()
        self.buildInfo = buildInfo
        UIStateLogger.log(
            "App.build",
            buildInfo.map { "\($0.shortHash)\($0.isDirty ? "+dirty" : "") — \($0.subject)" } ?? "unknown"
        )
        let store = SnapshotStore(context: container.mainContext)
        let networkMonitor = NetworkMonitorViewModel(snapshotStore: store)
        let lanDiscovery = LANDiscoveryViewModel(snapshotStore: store)
        let networkIdentity = NetworkIdentityViewModel(snapshotStore: store)
        let publicIP = PublicIPViewModel(snapshotStore: store)
        let dhcpLease = DHCPLeaseViewModel(snapshotStore: store, networkMonitor: networkMonitor)
        let wifiSSID = WiFiSSIDViewModel(snapshotStore: store)
        let eventLog = EventLogViewModel(snapshotStore: store)
        let traceroute = TracerouteViewModel(snapshotStore: store)
        let bonjourDiscovery = BonjourDiscoveryViewModel(snapshotStore: store)
        let connectivity = ConnectivityViewModel(
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            traceroute: traceroute,
            publicIP: publicIP,
            snapshotStore: store
        )
        let snmp = SNMPViewModel(
            snapshotStore: store,
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            bonjourDiscovery: bonjourDiscovery,
            traceroute: traceroute
        )
        // Two-phase: `SNMPViewModel` needs view models built alongside
        // `connectivity`, so the back-reference is injected once both exist.
        connectivity.attach(snmp: snmp)
        Self.wireDependencies(
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            connectivity: connectivity,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            dhcpLease: dhcpLease,
            wifiSSID: wifiSSID,
            eventLog: eventLog,
            traceroute: traceroute,
            snmp: snmp
        )
        _networkMonitor = StateObject(wrappedValue: networkMonitor)
        _lanDiscovery = StateObject(wrappedValue: lanDiscovery)
        _connectivity = StateObject(wrappedValue: connectivity)
        _networkIdentity = StateObject(wrappedValue: networkIdentity)
        _publicIP = StateObject(wrappedValue: publicIP)
        _dhcpLease = StateObject(wrappedValue: dhcpLease)
        _wifiSSID = StateObject(wrappedValue: wifiSSID)
        _eventLog = StateObject(wrappedValue: eventLog)
        _traceroute = StateObject(wrappedValue: traceroute)
        _bonjourDiscovery = StateObject(wrappedValue: bonjourDiscovery)
        _snmp = StateObject(wrappedValue: snmp)

        // Recognize whatever network we're already on at launch, rather
        // than waiting for the next topology change to fire a scan.
        lanDiscovery.scan()
        wifiSSID.refresh(isWiFi: networkMonitor.currentInterface?.isWiFi ?? false)
        // Bonjour Devices no longer has a UI section (see ContentView —
        // hidden to fit a 13" screen), and its only other consumer,
        // `SNMPViewModel`'s candidate list, gains nothing from it: Bonjour
        // only ever finds link-local/same-subnet devices, which the SNMP
        // sweep already covers directly. Several real seconds of mDNS
        // scanning for now-redundant data isn't worth it, so this no
        // longer runs at launch. `bonjourDiscovery`/`BonjourDiscoveryService`
        // are otherwise untouched if the section comes back later.
    }

    /// Every cross-view-model connection in the app, in one place.
    ///
    /// Grouped here deliberately rather than scattered through `init()`.
    /// Only two view models consume other view models' state —
    /// `ConnectivityViewModel` (reads `networkMonitor`, `traceroute`,
    /// `publicIP`, `snmp`) and `SNMPViewModel` (reads `networkMonitor`,
    /// `lanDiscovery`, `bonjourDiscovery`, `traceroute`) — so the whole
    /// dependency matrix is roughly eight edges and small enough to audit by
    /// reading one function.
    ///
    /// That matters because of a bug class this app has now hit three times.
    /// Every one of those reads is optional-chained with a silent fallback
    /// (`snmp?.devices ?? []`, `traceroute?.monitoredHop?.address`), so a
    /// dependency that isn't ready yet doesn't error — it quietly yields an
    /// incomplete result that then sits cached until some *timer* recomputes
    /// it. The ISP Edge Router row vanished for 30s that way, and the SNMP
    /// MAC merge for 60s. The fix in both cases was to make the recompute
    /// trigger belong to the dependency rather than the clock, which is what
    /// the "derived state" section below wires. An edge missing from that
    /// section is the shape this bug takes, so it should be possible to spot
    /// one by inspection instead of by user report.
    private static func wireDependencies(
        networkMonitor: NetworkMonitorViewModel,
        lanDiscovery: LANDiscoveryViewModel,
        connectivity: ConnectivityViewModel,
        networkIdentity: NetworkIdentityViewModel,
        publicIP: PublicIPViewModel,
        dhcpLease: DHCPLeaseViewModel,
        wifiSSID: WiFiSSIDViewModel,
        eventLog: EventLogViewModel,
        traceroute: TracerouteViewModel,
        snmp: SNMPViewModel
    ) {
        // MARK: Topology change fan-out
        // A change to the Mac's own interface/IP/router invalidates nearly
        // everything, so it re-runs nearly everything.
        networkMonitor.onChangePersisted = { snapshot in
            lanDiscovery.scan(for: snapshot)
            // A topology change is the most likely moment the public IP
            // actually changed, so check it right away rather than waiting
            // for the next periodic tick.
            publicIP.check()
            // Same for the Wi-Fi SSID — e.g. unplugging Ethernet and
            // falling back to Wi-Fi is exactly this kind of change.
            wifiSSID.refresh(isWiFi: networkMonitor.currentInterface?.isWiFi ?? false)
            // A topology change (new network, interface failover) is
            // exactly the moment a DHCP lease is likely to have changed
            // too, rather than waiting up to 5 minutes for the next poll.
            dhcpLease.check()
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

        // MARK: Derived-state dependencies
        // The edges that exist specifically so a consumer re-derives when its
        // dependency resolves, instead of waiting for a timer. Each one here
        // corresponds to a real bug that shipped without it.

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
            networkIdentity.recognize(routerAddress: networkMonitor.currentInterface?.routerAddress, from: devices)
            snmp.rebuildDeviceList()
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
        publicIP.onCurrentIPChanged = { connectivity.runChecks() }

        // MARK: Reachability transitions
        // An upstream failure (e.g. a switch between the local router and the
        // ISP) doesn't touch the Mac's own interface/IP/router, so
        // `onChangePersisted` never fires for it — the raw IP check failing is
        // the earliest signal something broke upstream.
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
        }

        // MARK: Event log refresh
        // Every producer that can write an `AppEventRecord` tells the log view
        // to re-read.
        networkMonitor.onEventLogged = { eventLog.refresh() }
        connectivity.onEventLogged = { eventLog.refresh() }
        publicIP.onEventLogged = { eventLog.refresh() }
        dhcpLease.onEventLogged = { eventLog.refresh() }
        wifiSSID.onEventLogged = { eventLog.refresh() }
        snmp.onEventLogged = { eventLog.refresh() }
    }

    /// The at-a-glance severity: interface down and router/internet/DNS/HTTP
    /// failures are critical (red); a monitored LAN device being down is
    /// marginal (yellow); anything else is normal (green).
    private var overallStatus: OverallStatus {
        OverallStatus.compute(interfaceIsDown: networkMonitor.currentInterface == nil, checks: connectivity.checks)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                viewModel: networkMonitor,
                lanDiscovery: lanDiscovery,
                connectivity: connectivity,
                networkIdentity: networkIdentity,
                publicIP: publicIP,
                dhcpLease: dhcpLease,
                wifiSSID: wifiSSID,
                eventLog: eventLog,
                traceroute: traceroute,
                bonjourDiscovery: bonjourDiscovery,
                snmp: snmp,
                buildInfo: buildInfo
            )
        } label: {
            Image(nsImage: Self.statusIcon(symbolName: networkMonitor.statusSymbolName, color: overallStatus.color))
        }
        .menuBarExtraStyle(.window)
    }

    /// macOS forces menu bar icons to render as monochrome "template"
    /// images by default — a plain SwiftUI `Image` with `.foregroundStyle`
    /// gets that treatment too, silently ignoring the color (confirmed:
    /// the color didn't show up at all with that approach). Rasterizing
    /// the symbol into an `NSImage` and explicitly setting `isTemplate =
    /// false` is the standard way to bypass that.
    private static func statusIcon(symbolName: String, color: Color) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()

        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        NSColor(color).set()
        let rect = NSRect(origin: .zero, size: base.size)
        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    /// Falls back to an in-memory store if the on-disk store can't be
    /// opened (e.g. a corrupted database after a schema change), so a
    /// storage problem degrades to "history isn't saved this run" rather
    /// than the menu bar app failing to launch.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            NetworkSnapshot.self,
            DiscoveredDeviceRecord.self,
            ConnectivityCheckRecord.self,
            KnownNetwork.self,
            PublicIPRecord.self,
            DHCPLeaseRecord.self,
            AppEventRecord.self,
            ProviderEdgeRecord.self,
            BonjourDeviceRecord.self,
            SNMPDeviceRecord.self
        ])
        do {
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)])
        } catch {
            print("NMS: failed to open persistent store (\(error)); falling back to in-memory store")
            return try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
    }
}
