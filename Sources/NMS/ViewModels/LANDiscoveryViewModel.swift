import Foundation

@MainActor
final class LANDiscoveryViewModel: ObservableObject {
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?

    private let discoveryService = LANDiscoveryService()
    private let snapshotStore: SnapshotStore

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
        } catch {
            lastError = error.localizedDescription
        }
    }
}
