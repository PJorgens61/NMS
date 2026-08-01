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
    /// A detected admin web UI — see `DeviceWebDetectionService`. Plain
    /// optional, not defaulted like `community` above needed to be:
    /// SwiftData already treats an optional's absence on existing rows as
    /// `nil` with no migration risk, the same reason `sysName` and
    /// `networkFingerprint` above never needed one either. Persisted
    /// (unlike `SNMPDevice.webURL` being purely transient before this)
    /// so the link shows immediately on the next launch instead of
    /// waiting out a fresh probe every single time — see
    /// `SNMPViewModel.activate()`, which seeds its own in-memory cache
    /// from this on rehydration.
    var webURL: String?
    /// A resolved reverse-DNS (PTR) domain name — see
    /// `DeviceWebDetectionService`'s sibling, `ReverseDNSService`, called
    /// from `SNMPViewModel.enrichHostnames`. Same plain-optional,
    /// no-migration-risk shape as `webURL` just above.
    var hostname: String?

    /// The name worth showing: hostname when the device reports one,
    /// otherwise the address. Mirrors `SNMPDevice.displayName` — this
    /// record has no live reachability/alias data to also show (that's
    /// `SNMPViewModel`'s territory), so Network Review, the one place
    /// this is read for display, shows just the name.
    var displayName: String {
        guard let sysName, !sysName.isEmpty else { return ipAddress }
        return sysName
    }

    /// Mirrors `SNMPDevice.uptimeDescription` — same coarse-on-purpose
    /// rendering, duplicated here rather than shared because the two
    /// types otherwise have no relationship a shared protocol would be
    /// worth introducing for.
    var uptimeDescription: String {
        let totalSeconds = Int(TimeInterval(uptimeTicks) / 100)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        if days > 0 { return "up \(days)d \(hours)h" }
        if hours > 0 { return "up \(hours)h \(minutes)m" }
        return "up \(minutes)m"
    }

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
