import Foundation
import SwiftData

/// Persisted history of `NetworkInterfaceInfo` snapshots. One row is written
/// each time `SystemConfigurationService` reports an actual network change
/// (not on every UI refresh), so this table is a timeline of topology
/// changes rather than a polling log.
@Model
final class NetworkSnapshot {
    var interfaceName: String
    var displayName: String?
    var ipAddress: String?
    var subnetMask: String?
    var routerAddress: String?
    var isWiFi: Bool
    var capturedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \DiscoveredDeviceRecord.snapshot)
    var discoveredDevices: [DiscoveredDeviceRecord] = []

    init(from info: NetworkInterfaceInfo) {
        interfaceName = info.interfaceName
        displayName = info.displayName
        ipAddress = info.ipAddress
        subnetMask = info.subnetMask
        routerAddress = info.routerAddress
        isWiFi = info.isWiFi
        capturedAt = info.capturedAt
    }
}
