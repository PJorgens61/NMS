import Foundation
import Combine

@MainActor
final class NetworkIdentityViewModel: ObservableObject {
    @Published private(set) var currentNetwork: KnownNetwork?
    @Published private(set) var isNewNetwork = false
    @Published private(set) var knownNetworks: [KnownNetwork] = []

    private let snapshotStore: SnapshotStore

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    /// Finds the router's MAC address among freshly-scanned LAN devices and
    /// records/looks up the network identity for it, keyed by router MAC
    /// **and subnet** — see `KnownNetwork` for why the subnet is needed
    /// too. Called after every LAN scan (automatic or manual) since that's
    /// what produces the MAC data. If the router's MAC or the subnet mask
    /// can't be resolved yet (e.g. the ARP cache hasn't populated right
    /// after connecting), leaves recognition state as-is rather than
    /// guessing at an identity.
    ///
    /// Also sets `SnapshotStore.currentNetworkFingerprint`, which is what
    /// actually scopes Events/SNMP Devices/DHCP History to this network —
    /// this method existing and being called is the one place that
    /// connects "which network are we on" to "what data should show."
    func recognize(routerAddress: String?, subnetMask: String?, from devices: [DiscoveredDevice]) {
        guard
            let routerAddress,
            let subnetMask,
            let routerMAC = devices.first(where: { $0.ipAddress == routerAddress })?.macAddress,
            let subnet = SubnetCalculator.cidr(ipAddress: routerAddress, subnetMask: subnetMask)
        else {
            return
        }

        let (network, isNew) = snapshotStore.recordNetworkSeen(routerMAC: routerMAC, subnet: subnet)
        // Before declaring this the current network: anything written
        // while recognition was still pending (a real race — SNMP/DHCP
        // both run before the first LAN scan resolves this) is still
        // tagged `nil`. It was learned on this network, just before this
        // network had a name; adopt it now rather than leaving it
        // orphaned. See `SnapshotStore.adoptUntaggedRecords`.
        snapshotStore.adoptUntaggedRecords(into: network.fingerprint)
        currentNetwork = network
        isNewNetwork = isNew
        snapshotStore.setCurrentNetworkFingerprint(network.fingerprint)
        refreshKnownNetworks()
    }

    /// Clears recognition state and the store's current-network fingerprint
    /// — called right when a topology change is first detected, before the
    /// LAN scan that will re-`recognize` the new network completes. Without
    /// this, `currentNetworkFingerprint` would keep pointing at the
    /// *previous* network for the gap between the change and re-
    /// recognition, during which any data recorded would be wrongly
    /// attributed to it — exactly the cross-network leakage this whole
    /// feature exists to prevent.
    func reset() {
        currentNetwork = nil
        isNewNetwork = false
        snapshotStore.setCurrentNetworkFingerprint(nil)
    }

    /// Names a network — any known network, not just the current one,
    /// which is the whole point: `KnownNetworksView` lists every network
    /// this Mac has seen, and a field technician labelling a site they
    /// visited last week is exactly the case that matters. (The previous
    /// version of this took no network and silently only worked on
    /// `currentNetwork`; nothing ever called it, so it was dead code
    /// enforcing a restriction no caller wanted.)
    ///
    /// An empty label clears it rather than storing `""` — see
    /// `SnapshotStore.setLabel` — so the display falls back to the Wi-Fi
    /// SSID or "Ethernet" again, which is what an emptied field should
    /// mean.
    func setLabel(_ label: String, for network: KnownNetwork) {
        snapshotStore.setLabel(label, for: network)
        refreshKnownNetworks()
    }

    func refreshKnownNetworks() {
        knownNetworks = snapshotStore.fetchKnownNetworks()
    }

    /// Forgets a network entirely, including every event/lease/device it
    /// was ever the source of. See `SnapshotStore.deleteNetwork`.
    func deleteNetwork(_ network: KnownNetwork) {
        snapshotStore.deleteNetwork(network)
        if currentNetwork?.fingerprint == network.fingerprint {
            currentNetwork = nil
            isNewNetwork = false
        }
        refreshKnownNetworks()
    }
}
