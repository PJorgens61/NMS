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

    init() {
        let container = Self.makeModelContainer()
        modelContainer = container
        let store = SnapshotStore(context: container.mainContext)
        let networkMonitor = NetworkMonitorViewModel(snapshotStore: store)
        let lanDiscovery = LANDiscoveryViewModel(snapshotStore: store)
        let networkIdentity = NetworkIdentityViewModel(snapshotStore: store)
        let publicIP = PublicIPViewModel(snapshotStore: store)
        let wifiSSID = WiFiSSIDViewModel()
        let eventLog = EventLogViewModel(snapshotStore: store)
        let traceroute = TracerouteViewModel(snapshotStore: store)
        let bonjourDiscovery = BonjourDiscoveryViewModel(snapshotStore: store)
        let connectivity = ConnectivityViewModel(networkMonitor: networkMonitor, lanDiscovery: lanDiscovery, traceroute: traceroute, snapshotStore: store)
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
        // Tie a LAN scan to every observed topology change, not just the
        // manual "Scan" button.
        networkMonitor.onChangePersisted = { snapshot in
            lanDiscovery.scan(for: snapshot)
            // A topology change is the most likely moment the public IP
            // actually changed, so check it right away rather than waiting
            // for the next periodic tick.
            publicIP.check()
            // Same for the Wi-Fi SSID — e.g. unplugging Ethernet and
            // falling back to Wi-Fi is exactly this kind of change.
            wifiSSID.refresh(isWiFi: networkMonitor.currentInterface?.isWiFi ?? false)
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
        // Refresh the event log whenever any producer logs a new event
        // (interface down, router/internet/DNS/HTTP unreachable, or the
        // public IP changed).
        networkMonitor.onEventLogged = { eventLog.refresh() }
        connectivity.onEventLogged = { eventLog.refresh() }
        publicIP.onEventLogged = { eventLog.refresh() }
        snmp.onEventLogged = { eventLog.refresh() }
        // An upstream failure (e.g. a switch between the local router and
        // the ISP) doesn't touch the Mac's own interface/IP/router, so
        // `onChangePersisted` above never fires for it — the raw IP check
        // failing is the earliest signal something's wrong upstream, so
        // re-trace immediately instead of waiting on traceroute's own
        // (much slower) schedule to notice.
        connectivity.onInternetUnreachable = { traceroute.run() }
        // Recognizing the current network depends on the router's MAC,
        // which only comes from a LAN scan — so identity recognition rides
        // along with every scan, automatic or manual.
        lanDiscovery.onScanCompleted = { devices in
            networkIdentity.recognize(routerAddress: networkMonitor.currentInterface?.routerAddress, from: devices)
        }
        _networkMonitor = StateObject(wrappedValue: networkMonitor)
        _lanDiscovery = StateObject(wrappedValue: lanDiscovery)
        _connectivity = StateObject(wrappedValue: connectivity)
        _networkIdentity = StateObject(wrappedValue: networkIdentity)
        _publicIP = StateObject(wrappedValue: publicIP)
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
                wifiSSID: wifiSSID,
                eventLog: eventLog,
                traceroute: traceroute,
                bonjourDiscovery: bonjourDiscovery,
                snmp: snmp
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
