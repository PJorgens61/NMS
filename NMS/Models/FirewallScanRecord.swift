import Foundation
import SwiftData

/// Persisted history of FW scan results — one row per completed scan.
/// FW's own server is deliberately stateless (in-memory job, discarded
/// once fetched or on a short TTL — see its `docs/api.md`), so this is
/// the *only* place a firewall-visibility history exists; NMS owns it
/// the same way it owns every other history section (DHCP leases, SNMP
/// devices), not FW.
///
/// Tagged with `networkFingerprint` like `DHCPLeaseRecord`/
/// `SNMPDeviceRecord` — exposure is a property of whichever network is
/// current (a home connection's own router/firewall), not a global fact,
/// so each network's scan history is kept separate. `FirewallVisibilityViewModel`
/// also only runs a scan while the current network is marked home (same
/// `snapshotStore.isCurrentNetworkHome()` gate `DDNSViewModel` uses) —
/// scanning from a coffee shop would test the coffee shop's NAT, not
/// anything this Mac's owner actually controls.
@Model
final class FirewallScanRecord {
    var scannedAt: Date
    var targetIPv4: String?
    var targetIPv6: [String]
    /// `FWClient.PortResult` is `Codable`, so SwiftData stores this array
    /// directly as a composite attribute — same shape `DHCPLeaseRecord
    /// .dnsServers` uses for `[String]`, just with a richer element type.
    var results: [FWClient.PortResult]
    var networkFingerprint: String?

    init(scannedAt: Date, targetIPv4: String?, targetIPv6: [String], results: [FWClient.PortResult], networkFingerprint: String?) {
        self.scannedAt = scannedAt
        self.targetIPv4 = targetIPv4
        self.targetIPv6 = targetIPv6
        self.results = results
        self.networkFingerprint = networkFingerprint
    }

    /// Ports currently reported `open`, sorted — the summary a UI wants
    /// at a glance without walking `results` itself.
    var openPorts: [Int] {
        results.filter { $0.state == "open" }.map(\.port).sorted()
    }
}
