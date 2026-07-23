import Foundation

/// A device found on the local subnet, currently sourced from the kernel's
/// ARP cache (see `LANDiscoveryService`).
struct DiscoveredDevice: Equatable, Codable, Identifiable {
    var id: String { macAddress ?? ipAddress }

    let ipAddress: String
    let macAddress: String?
    let hostname: String?
    let interfaceName: String?
    let discoveredAt: Date
}
