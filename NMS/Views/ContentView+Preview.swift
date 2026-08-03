import SwiftUI
import SwiftData

/// `#Preview` support for `ContentView` — added once the popover/window
/// split was dropped and `Grid`/scroll-container special-casing came out
/// (see `NMSApp`/`NoBounceScrollView`'s removal), specifically so future
/// layout iteration on Network Health, Info, or Events can happen live in
/// Xcode's canvas instead of a full build→relaunch→screenshot round trip.
///
/// `ContentView` takes fifteen `@ObservedObject` view models, each with
/// real side effects at `init` (a background timer, a subprocess, a
/// network fetch) — building one straight from `NMSApp`'s own disk-backed
/// store would mean a preview that reaches out to the real network and
/// pollutes the real store. This builds the identical view-model graph
/// against a fresh, in-memory-only `SnapshotStore` instead (SwiftData's
/// standard preview pattern), so every side effect still runs, just
/// against throwaway state that vanishes with the canvas.
///
/// No seeded fixture data beyond what each view model's own `init`
/// produces — this is for checking layout/spacing, not exercising every
/// possible data state. A future pass could seed the in-memory store with
/// representative `KnownNetwork`/`AppEventRecord`/etc. rows first, the
/// same way `script/scenarios.sh` seeds a scratch copy of the real store
/// for its own live-scenario tests.
private enum ContentViewPreviewSupport {
    @MainActor
    static func makeContentView() -> ContentView {
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
            WiFiStressTestRecord.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        // `try!` — preview-only code; an in-memory container failing to
        // initialize means Xcode itself is broken, not something worth a
        // fallback path for.
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        let store = SnapshotStore(context: container.mainContext)

        let networkMonitor = NetworkMonitorViewModel(snapshotStore: store)
        let lanDiscovery = LANDiscoveryViewModel(snapshotStore: store)
        let networkIdentity = NetworkIdentityViewModel(snapshotStore: store)
        let publicIP = PublicIPViewModel(snapshotStore: store)
        let ispIdentity = ISPIdentityViewModel(snapshotStore: store)
        let dhcpLease = DHCPLeaseViewModel(snapshotStore: store, networkMonitor: networkMonitor)
        let networkQuality = NetworkQualityViewModel(snapshotStore: store)
        let wifiStressTest = WiFiStressTestViewModel(snapshotStore: store)
        let wifiSSID = WiFiSSIDViewModel(snapshotStore: store)
        let ethernetLink = EthernetLinkViewModel()
        let eventLog = EventLogViewModel(snapshotStore: store)
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

        return ContentView(
            viewModel: networkMonitor,
            lanDiscovery: lanDiscovery,
            connectivity: connectivity,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            ispIdentity: ispIdentity,
            dhcpLease: dhcpLease,
            networkQuality: networkQuality,
            wifiStressTest: wifiStressTest,
            wifiSSID: wifiSSID,
            ethernetLink: ethernetLink,
            eventLog: eventLog,
            traceroute: traceroute,
            snmp: snmp,
            saasMonitoring: saasMonitoring,
            ddns: ddns,
            buildInfo: nil,
            storeURL: URL(fileURLWithPath: "/dev/null")
        )
    }
}

#Preview("ContentView") {
    ContentViewPreviewSupport.makeContentView()
}
