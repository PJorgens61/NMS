import Foundation

/// A point-in-time description of the interface macOS is currently using
/// for its default route (i.e. "the network you're on right now").
///
/// This is intentionally a plain, `Equatable`, `Codable` value type — later,
/// when persistence is added (SwiftData/Core Data), snapshots of this struct
/// are what get written to disk so history can be diffed over time.
struct NetworkInterfaceInfo: Equatable, Codable {
    /// BSD interface name, e.g. "en0"
    let interfaceName: String

    /// Human-readable name from System Settings, e.g. "Wi-Fi" or "USB Ethernet"
    let displayName: String?

    let ipAddress: String?
    let subnetMask: String?
    let routerAddress: String?
    let isWiFi: Bool

    /// When this snapshot was captured. Not part of equality checks —
    /// two snapshots with identical network state but different timestamps
    /// should be considered "the same" for change detection.
    let capturedAt: Date

    static func == (lhs: NetworkInterfaceInfo, rhs: NetworkInterfaceInfo) -> Bool {
        lhs.interfaceName == rhs.interfaceName &&
        lhs.displayName == rhs.displayName &&
        lhs.ipAddress == rhs.ipAddress &&
        lhs.subnetMask == rhs.subnetMask &&
        lhs.routerAddress == rhs.routerAddress &&
        lhs.isWiFi == rhs.isWiFi
    }
}
