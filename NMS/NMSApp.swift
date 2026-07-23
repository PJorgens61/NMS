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
        }
        // Recognizing the current network depends on the router's MAC,
        // which only comes from a LAN scan — so identity recognition rides
        // along with every scan, automatic or manual.
        lanDiscovery.onScanCompleted = { devices in
            networkIdentity.recognize(routerAddress: networkMonitor.currentInterface?.routerAddress, from: devices)
        }
        let connectivity = ConnectivityViewModel(networkMonitor: networkMonitor, lanDiscovery: lanDiscovery, snapshotStore: store)
        _networkMonitor = StateObject(wrappedValue: networkMonitor)
        _lanDiscovery = StateObject(wrappedValue: lanDiscovery)
        _connectivity = StateObject(wrappedValue: connectivity)
        _networkIdentity = StateObject(wrappedValue: networkIdentity)
        _publicIP = StateObject(wrappedValue: publicIP)
        _wifiSSID = StateObject(wrappedValue: wifiSSID)

        // Recognize whatever network we're already on at launch, rather
        // than waiting for the next topology change to fire a scan.
        lanDiscovery.scan()
        wifiSSID.refresh(isWiFi: networkMonitor.currentInterface?.isWiFi ?? false)
    }

    var body: some Scene {
        MenuBarExtra("NMS", systemImage: networkMonitor.statusSymbolName) {
            ContentView(
                viewModel: networkMonitor,
                lanDiscovery: lanDiscovery,
                connectivity: connectivity,
                networkIdentity: networkIdentity,
                publicIP: publicIP,
                wifiSSID: wifiSSID
            )
        }
        .menuBarExtraStyle(.window)
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
            PublicIPRecord.self
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
