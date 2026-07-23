import Foundation

/// A device found on the local subnet, currently sourced from the kernel's
/// ARP cache (see `LANDiscoveryService`).
struct DiscoveredDevice: Equatable, Codable, Identifiable {
    // IP is what `LANDiscoveryService.parse` actually de-dupes on — the same
    // MAC can legitimately appear twice in one scan (e.g. a device got a new
    // DHCP lease and its old IP's ARP entry hasn't expired yet), so MAC
    // can't be used as the identity here.
    var id: String { ipAddress }

    let ipAddress: String
    let macAddress: String?
    let hostname: String?
    let interfaceName: String?
    let discoveredAt: Date
}
