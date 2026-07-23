import Foundation
import SwiftData

/// Persisted history of `DiscoveredDevice` scans, tied to the
/// `NetworkSnapshot` that was current when the scan ran — so a device list
/// can be read back per topology change rather than as one undifferentiated
/// pile.
@Model
final class DiscoveredDeviceRecord {
    var ipAddress: String
    var macAddress: String?
    var hostname: String?
    var interfaceName: String?
    var discoveredAt: Date
    var snapshot: NetworkSnapshot?

    init(from device: DiscoveredDevice, snapshot: NetworkSnapshot?) {
        ipAddress = device.ipAddress
        macAddress = device.macAddress
        hostname = device.hostname
        interfaceName = device.interfaceName
        discoveredAt = device.discoveredAt
        self.snapshot = snapshot
    }
}
