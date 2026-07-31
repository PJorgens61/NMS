import Foundation
import SwiftData

/// A network the Mac has connected to before, identified by its gateway's
/// MAC address plus subnet (see `NetworkIdentityViewModel`) rather than by
/// SSID — stable across DHCP lease changes and doesn't require Wi-Fi/
/// location permissions to read.
///
/// Router MAC alone isn't enough: one router serving several VLANs (a main
/// LAN and a guest network, say) answers on the same MAC for both, which
/// collapsed them into a single `KnownNetwork` — confirmed directly while
/// dual-homed, and the root cause of SNMP devices, DHCP history, and
/// Events all mixing together across networks that aren't actually the
/// same one. Subnet is the second signal that tells them apart — see
/// DESIGN-NOTES.md's "Per-network device scoping" for the full reasoning
/// and the cases this key does and doesn't handle.
@Model
final class KnownNetwork {
    @Attribute(.unique) var fingerprint: String
    var label: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var timesSeen: Int

    init(routerMAC: String, subnet: String, firstSeenAt: Date) {
        self.fingerprint = Self.makeFingerprint(routerMAC: routerMAC, subnet: subnet)
        self.label = nil
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = firstSeenAt
        self.timesSeen = 1
    }

    static let fingerprintSeparator: Character = "|"

    static func makeFingerprint(routerMAC: String, subnet: String) -> String {
        "\(routerMAC)\(fingerprintSeparator)\(subnet)"
    }

    /// Derived from `fingerprint`, not stored alongside it.
    ///
    /// **This is what fixed the store failing to open.** Both of these
    /// were stored, non-optional `String`s added to a model that already
    /// had rows on disk (commit `e2f9ba2`), and SwiftData's lightweight
    /// migration cannot add a mandatory attribute to existing rows — it
    /// has no value to put there. Every launch after that commit failed
    /// with "Cannot migrate store in-place: Validation error missing
    /// attribute values on mandatory destination attribute", and
    /// `NMSApp.makeModelContainer()` quietly fell back to an in-memory
    /// container, so the app started empty every time while 230 real
    /// events sat unreadable in the file.
    ///
    /// Storing them was redundant anyway: `fingerprint` is defined as
    /// `routerMAC|subnet`, so the same two values were being written
    /// twice, and the copies could in principle disagree. Deriving them
    /// removes the duplication *and* removes the two mandatory attributes
    /// that blocked migration — dropping attributes is something
    /// lightweight migration handles fine, unlike adding required ones.
    /// Nothing queries or sorts on these (they're display-only, in
    /// `KnownNetworksView` and `NetworkReviewView`), so there's no
    /// predicate that needs them to be real columns.
    var routerMAC: String { Self.routerMAC(fromFingerprint: fingerprint) }

    /// Split out as a static so it's testable without a `ModelContainer`
    /// — the same reason `ConnectivityViewModel`'s decision helpers are
    /// `nonisolated static`. Instantiating a `@Model` class needs a live
    /// container, which is exactly the kind of setup this project's test
    /// suite deliberately avoids.
    static func routerMAC(fromFingerprint fingerprint: String) -> String {
        String(fingerprint.split(
            separator: fingerprintSeparator,
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first ?? "")
    }

    /// Empty for rows written before the subnet joined the fingerprint —
    /// one such row exists in the real store (`bc:b9:23:81:a6:d4`, no
    /// separator, from when router MAC alone was the whole key). Reported
    /// as unknown rather than guessed at: an empty subnet is honest about
    /// a legacy row, and these are display-only.
    var subnet: String { Self.subnet(fromFingerprint: fingerprint) }

    static func subnet(fromFingerprint fingerprint: String) -> String {
        let parts = fingerprint.split(
            separator: fingerprintSeparator,
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        return parts.count > 1 ? String(parts[1]) : ""
    }
}
