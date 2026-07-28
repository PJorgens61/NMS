import Foundation
import SwiftData

/// One row per SNMP device, updated in place — the device's *current*
/// known state, not an observation log. Mirrors `KnownNetwork` rather than
/// `ConnectivityCheckRecord`: what matters here is "what did we last see
/// from this device," which is what the next poll gets compared against to
/// detect a restart (uptime went backwards) or a software change (sysDescr
/// differs). Keyed by `ipAddress`.
///
/// A `sysName`-based identity (collapsing a VRRP pair member's own address
/// and the shared virtual address it holds as master into one record) was
/// tried and reverted — it collapses "this specific router" and "whichever
/// router currently holds the virtual address" into one ambiguous entry,
/// which doesn't actually model VRRP, just hides the duplicate. Classical
/// dual-router VRRP support, if built properly later, likely needs to keep
/// both as distinct, related entries rather than merging them — see
/// `DESIGN-NOTES.md`.
@Model
final class SNMPDeviceRecord {
    @Attribute(.unique) var ipAddress: String
    var sysDescr: String
    var sysName: String?
    var uptimeTicks: Int
    /// Defaulted rather than plain `String` so adding this property to an
    /// existing on-disk store stays a lightweight migration — older rows
    /// predate multi-community support and were all found using the
    /// then-only default.
    var community: String = "public"
    var firstSeenAt: Date
    var lastSeenAt: Date

    init(from device: SNMPDevice, firstSeenAt: Date = Date()) {
        ipAddress = device.ipAddress
        sysDescr = device.sysDescr
        sysName = device.sysName
        uptimeTicks = device.uptimeTicks
        community = device.community
        self.firstSeenAt = firstSeenAt
        lastSeenAt = device.polledAt
    }
}
