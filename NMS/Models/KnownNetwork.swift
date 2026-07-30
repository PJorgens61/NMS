import Foundation
import SwiftData

/// A network the Mac has connected to before, identified by its gateway's
/// MAC address plus subnet (see `NetworkIdentityViewModel`) rather than by
/// SSID — stable across DHCP lease changes and doesn't require Wi-Fi/
/// location permissions to read.
///
/// Router MAC alone isn't enough: one router serving several VLANs (a main
/// LAN and a guest network, say) answers on the same MAC for both, which
/// collapsed them into a single `KnownNetwork` — confirmed directly while
/// dual-homed, and the root cause of SNMP devices, DHCP history, and
/// Events all mixing together across networks that aren't actually the
/// same one. Subnet is the second signal that tells them apart — see
/// DESIGN-NOTES.md's "Per-network device scoping" for the full reasoning
/// and the cases this key does and doesn't handle.
@Model
final class KnownNetwork {
    @Attribute(.unique) var fingerprint: String
    var routerMAC: String
    var subnet: String
    var label: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var timesSeen: Int

    init(routerMAC: String, subnet: String, firstSeenAt: Date) {
        self.fingerprint = Self.makeFingerprint(routerMAC: routerMAC, subnet: subnet)
        self.routerMAC = routerMAC
        self.subnet = subnet
        self.label = nil
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = firstSeenAt
        self.timesSeen = 1
    }

    static func makeFingerprint(routerMAC: String, subnet: String) -> String {
        "\(routerMAC)|\(subnet)"
    }
}
