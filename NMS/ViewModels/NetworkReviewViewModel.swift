import Foundation

/// Backs `NetworkReviewView` — a read-only look at a *past* `KnownNetwork`,
/// for a field technician revisiting a site who wants to see what this Mac
/// last recorded there without being on that network. Unlike every other
/// view model in this app, this one never polls and never writes: it loads
/// once, from the explicit-fingerprint `SnapshotStore` overloads
/// (`fetchRecentEvents(for:)`, `fetchSNMPDevices(for:)`,
/// `fetchDHCPLeaseHistory(for:)`, `fetchWiFiSampleHistory(for:)`), which
/// read the requested fingerprint directly rather than
/// `SnapshotStore.currentNetworkFingerprint` — reassigning that global to
/// browse another network would mistag whatever background writes (SNMP
/// poll, DHCP check, Wi-Fi sample) land on the *actual* current network
/// while this window is open. See DESIGN-NOTES.md's "Network Review".
@MainActor
@Observable
final class NetworkReviewViewModel {
    private(set) var events: [AppEventRecord] = []
    private(set) var snmpDevices: [SNMPDeviceRecord] = []
    private(set) var dhcpHistory: [DHCPLeaseRecord] = []
    private(set) var wifiSamples: [WiFiSampleRecord] = []

    let network: KnownNetwork
    private let snapshotStore: SnapshotStore

    init(network: KnownNetwork, snapshotStore: SnapshotStore) {
        self.network = network
        self.snapshotStore = snapshotStore
    }

    func load() {
        let fingerprint = network.fingerprint
        events = snapshotStore.fetchRecentEvents(for: fingerprint)
        snmpDevices = snapshotStore.fetchSNMPDevices(for: fingerprint)
        dhcpHistory = snapshotStore.fetchDHCPLeaseHistory(for: fingerprint)
        wifiSamples = snapshotStore.fetchWiFiSampleHistory(for: fingerprint)
    }
}
