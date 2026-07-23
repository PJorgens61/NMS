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
        // Tie a LAN scan to every observed topology change, not just the
        // manual "Scan" button.
        networkMonitor.onChangePersisted = { snapshot in
            lanDiscovery.scan(for: snapshot)
        }
        let connectivity = ConnectivityViewModel(networkMonitor: networkMonitor, lanDiscovery: lanDiscovery, snapshotStore: store)
        _networkMonitor = StateObject(wrappedValue: networkMonitor)
        _lanDiscovery = StateObject(wrappedValue: lanDiscovery)
        _connectivity = StateObject(wrappedValue: connectivity)
    }

    var body: some Scene {
        MenuBarExtra("NMS", systemImage: networkMonitor.statusSymbolName) {
            ContentView(viewModel: networkMonitor, lanDiscovery: lanDiscovery, connectivity: connectivity)
        }
        .menuBarExtraStyle(.window)
    }

    /// Falls back to an in-memory store if the on-disk store can't be
    /// opened (e.g. a corrupted database after a schema change), so a
    /// storage problem degrades to "history isn't saved this run" rather
    /// than the menu bar app failing to launch.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([NetworkSnapshot.self, DiscoveredDeviceRecord.self, ConnectivityCheckRecord.self])
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
