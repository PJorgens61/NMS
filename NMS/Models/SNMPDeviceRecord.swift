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
    // No longer `@Attribute(.unique)`: once devices are scoped per
    // network (see `networkFingerprint`), two different networks can
    // legitimately each have a `192.168.1.1` — a global uniqueness
    // constraint would make that unstorable. Uniqueness is now "IP within
    // a network," enforced in code by `SnapshotStore.recordSNMPDevice`'s
    // own fetch rather than expressed as a SwiftData constraint, which
    // can't represent a composite key. See DESIGN-NOTES.md's "Per-network
    // device scoping."
    var ipAddress: String
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
    /// See `AppEventRecord.networkFingerprint` — same scoping, same `nil`
    /// meaning.
    var networkFingerprint: String?

    init(from device: SNMPDevice, firstSeenAt: Date = Date(), networkFingerprint: String? = nil) {
        ipAddress = device.ipAddress
        sysDescr = device.sysDescr
        sysName = device.sysName
        uptimeTicks = device.uptimeTicks
        community = device.community
        self.firstSeenAt = firstSeenAt
        lastSeenAt = device.polledAt
        self.networkFingerprint = networkFingerprint
    }
}
