import Foundation
import Combine

@MainActor
final class BonjourDiscoveryViewModel: ObservableObject {
    @Published private(set) var devices: [BonjourDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanAt: Date?

    private let service = BonjourDiscoveryService()
    private let snapshotStore: SnapshotStore

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    /// Takes a few seconds — browsing and resolving several service types in
    /// parallel — so this is meant to be triggered manually or once at
    /// launch, not tied to every topology change the way the near-instant
    /// ARP-based scan is. `BonjourDiscoveryService.discover()` is a real
    /// `async` function (task groups, `Task.sleep`), not a blocking call
    /// like `Process`-based ping/arp, so it doesn't need a background-queue
    /// hop to avoid stalling the UI.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let service = self.service
        Task {
            let found = await service.discover()
            devices = found
            lastScanAt = Date()
            isScanning = false
            snapshotStore.saveBonjourDevices(found, for: snapshotStore.latestSnapshot())
        }
    }
}
