import Foundation
import Combine

@MainActor
final class LANDiscoveryViewModel: ObservableObject {
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?

    private let discoveryService = LANDiscoveryService()
    private let snapshotStore: SnapshotStore

    /// Fired with the freshly-scanned devices after every scan (automatic or
    /// manual) — this is what lets `NetworkIdentityViewModel` find the
    /// router's MAC without a second `arp` call.
    var onScanCompleted: (([DiscoveredDevice]) -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    /// Scans the ARP table and persists the results tied to `snapshot`
    /// (falling back to the most recently saved snapshot if none is given,
    /// e.g. for a manual scan that isn't reacting to a fresh change).
    func scan(for snapshot: NetworkSnapshot? = nil) {
        do {
            let found = try discoveryService.scan()
            devices = found
            lastScanAt = Date()
            lastError = nil
            snapshotStore.saveDiscoveredDevices(found, for: snapshot ?? snapshotStore.latestSnapshot())
            onScanCompleted?(found)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
