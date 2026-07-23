import Foundation
import SwiftData

/// A network the Mac has connected to before, identified by its gateway's
/// MAC address (see `NetworkIdentityViewModel`) rather than by SSID —
/// stable across DHCP lease changes and doesn't require Wi-Fi/location
/// permissions to read.
@Model
final class KnownNetwork {
    @Attribute(.unique) var fingerprint: String
    var label: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var timesSeen: Int

    init(fingerprint: String, firstSeenAt: Date) {
        self.fingerprint = fingerprint
        self.label = nil
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = firstSeenAt
        self.timesSeen = 1
    }
}
