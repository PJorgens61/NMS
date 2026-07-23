import Foundation
import Combine

@MainActor
final class NetworkIdentityViewModel: ObservableObject {
    @Published private(set) var currentNetwork: KnownNetwork?
    @Published private(set) var isNewNetwork = false

    private let snapshotStore: SnapshotStore

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    /// Finds the router's MAC address among freshly-scanned LAN devices and
    /// records/looks up the network identity for it. Called after every LAN
    /// scan (automatic or manual) since that's what produces the MAC data.
    /// If the router's MAC can't be resolved yet (e.g. the ARP cache hasn't
    /// populated right after connecting), leaves recognition state as-is
    /// rather than guessing at an identity.
    func recognize(routerAddress: String?, from devices: [DiscoveredDevice]) {
        guard
            let routerAddress,
            let routerMAC = devices.first(where: { $0.ipAddress == routerAddress })?.macAddress
        else {
            return
        }

        let (network, isNew) = snapshotStore.recordNetworkSeen(fingerprint: routerMAC)
        currentNetwork = network
        isNewNetwork = isNew
    }

    func setLabel(_ label: String) {
        guard let currentNetwork else { return }
        snapshotStore.setLabel(label, for: currentNetwork)
    }
}
