import Foundation
import SwiftData

/// Persisted history of Bonjour-discovered devices, tied to the
/// `NetworkSnapshot` current when the scan ran — mirrors
/// `DiscoveredDeviceRecord`'s relationship to snapshots.
@Model
final class BonjourDeviceRecord {
    var name: String
    var serviceType: String
    var serviceLabel: String
    var ipAddress: String?
    var discoveredAt: Date
    var snapshot: NetworkSnapshot?

    init(from device: BonjourDevice, snapshot: NetworkSnapshot?) {
        name = device.name
        serviceType = device.serviceType
        serviceLabel = device.serviceLabel
        ipAddress = device.ipAddress
        discoveredAt = device.discoveredAt
        self.snapshot = snapshot
    }
}
