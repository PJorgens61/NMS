import SwiftUI
import SwiftData

/// `#Preview` support for `ContentView` — added once the popover/window
/// split was dropped and `Grid`/scroll-container special-casing came out
/// (see `NMSApp`/`NoBounceScrollView`'s removal), specifically so future
/// layout iteration on Network Health, Info, or Events can happen live in
/// Xcode's canvas instead of a full build→relaunch→screenshot round trip.
///
/// `ContentView` takes sixteen `@Observable` view models, each with
/// real side effects at `init` (a background timer, a subprocess, a
/// network fetch) — building one straight from `NMSApp`'s own disk-backed
/// store would mean a preview that reaches out to the real network and
/// pollutes the real store. This builds the identical view-model graph
/// against a fresh, in-memory-only `SnapshotStore` instead (SwiftData's
/// standard preview pattern), so every side effect still runs, just
/// against throwaway state that vanishes with the canvas.
///
/// Seeded with a first slice of fixture data — DHCP lease history and
/// `networkQuality` quick-check history, the two gaps this session's own
/// tile work actually ran into (both needed a real build+launch to see
/// rendered at all: DHCP's row reads "Not checked" with nothing seeded,
/// and the quick-check dot-history is empty with zero history). Not a
/// full seed of every table — `KnownNetwork`/SNMP/DDNS/etc. still render
/// their own empty states here, since seeding `KnownNetwork` specifically
/// wouldn't do anything on its own: `NetworkIdentityViewModel
/// .currentNetwork` is only ever set by live `recognize()` matching a
/// real detected router MAC/subnet, not read back from a persisted
/// "current" row, so a seeded `KnownNetwork` row would sit in the store
/// unused rather than making the Network row show "seen N×." A future
/// pass can extend this the same way, one gap at a time, as it's
/// actually run into — same spirit `script/scenarios.sh` seeds a scratch
/// copy of the real store for its own live-scenario tests, just for
/// canvas iteration instead of test assertions.
// Not `private` — also called from `NMSTests/PreviewCapture.swift` (via
// `@testable import NMS`) to render this same real, fixture-seeded view
// straight to a PNG for headless layout iteration. See that file's own
// doc comment for why: a full build→launch→AppleScript→screenshot round
// trip was slow and took over the whole screen for the duration.
enum ContentViewPreviewSupport {
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
        seedFixtureData(into: container.mainContext)

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

    /// Inserted directly into the context, not through `SnapshotStore`'s
    /// own `record*`/`log*` methods — those exist to mirror a live event
    /// (a real check just completed, a real run just finished), which
    /// isn't what's happening here. `networkFingerprint` left `nil` on
    /// every row: `SnapshotStore.currentNetworkFingerprint` is `nil` at
    /// this point too (nothing has recognized a network yet in a fresh
    /// in-memory container), and every fetch this feeds
    /// (`fetchDHCPLeaseHistory`/`fetchQuickCheckHistory`) scopes by
    /// exactly that value — `nil` seeded rows are what a `nil`-scoped
    /// fetch actually matches, not a shortcut.
    @MainActor
    private static func seedFixtureData(into context: ModelContext) {
        let dhcpInfo = DHCPLeaseInfo(
            interfaceName: "en0",
            serverIdentifier: "10.0.0.1",
            assignedAddress: "10.0.0.142",
            subnetMask: "255.255.255.0",
            broadcastAddress: "10.0.0.255",
            router: "10.0.0.1",
            dnsServers: ["10.0.0.1"],
            domainName: nil,
            leaseSeconds: 86400,
            t1Seconds: 43200,
            t2Seconds: 75600,
            transactionID: "0x1a2b3c4d",
            clientHardwareAddress: "aa:bb:cc:dd:ee:ff",
            checkedAt: Date()
        )
        context.insert(DHCPLeaseRecord(from: dhcpInfo, firstObservedAt: Date().addingTimeInterval(-3600)))

        // A mixed trail — good/fair/poor — so `quickCheckHistoryDots`
        // actually shows varied colors in the canvas rather than one flat
        // run of green. Oldest first, matching `quickCheckHistory`'s own
        // `.reversed()` at the call site.
        let sampleRPMs = [2100, 1900, 850, 700, 2400, 1600]
        for (index, rpm) in sampleRPMs.enumerated() {
            let result = NetworkQualityResult(
                downloadMbps: nil,
                uploadMbps: nil,
                downloadResponsivenessRPM: nil,
                uploadResponsivenessRPM: nil,
                combinedResponsivenessRPM: rpm,
                baseRTTMs: nil,
                downloadBytesTransferred: nil,
                uploadBytesTransferred: nil,
                source: .quickCheck,
                testedAt: Date().addingTimeInterval(TimeInterval(index - sampleRPMs.count) * 300)
            )
            context.insert(NetworkQualityRecord(from: result))
        }

        try? context.save()
    }
}

#Preview("ContentView") {
    ContentViewPreviewSupport.makeContentView()
}
