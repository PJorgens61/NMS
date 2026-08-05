import Foundation
import SwiftData

/// Persisted history of the ISP's edge router (the first non-RFC1918 hop
/// in the traceroute path — see `TracerouteViewModel`). Like
/// `PublicIPRecord`, only real changes get a row, not a per-run log —
/// traces run every 10 minutes (`TracerouteViewModel.runInterval`), and
/// the path is almost always unchanged from one trace to the next, so
/// logging every run would mean mostly-identical rows rather than a
/// readable timeline.
///
/// Briefly had a UI (a "Provider Edge History" list under Path to
/// Internet's hop list) — removed as a display once
/// `ContentView.tileHeight` stopped depending on this tile having its
/// own naturally-growing content to match Speed Test's height, and the
/// underlying data turned out too sparse/noisy on a single-homed network
/// to be worth showing on its own (see `PUNCHLIST.md`). The type and its
/// recording (`SnapshotStore.recordProviderEdgeIfChanged`) stay: this is
/// still how `TracerouteViewModel.monitoredHopAddress` survives an
/// outage without dropping to "Not checked", and how a resolved hostname
/// gets attached after the fact.
@Model
final class ProviderEdgeRecord {
    var address: String
    var hostname: String?
    var observedAt: Date
    /// See `AppEventRecord.networkFingerprint` — same scoping, same `nil`
    /// meaning ("not recognized yet," not "belongs to every network").
    /// Optional and added after rows already existed on disk — a
    /// mandatory attribute here would hit the exact migration failure
    /// `BUGS.md`'s "The persistent store fails to open" describes.
    var networkFingerprint: String?
    /// When a reverse-traceroute (Path Discovery, `GlobalpingReverseTraceService`)
    /// last observed this same address as an external vantage point's
    /// last hop before reaching this Mac — independent, outside
    /// confirmation that this is genuinely the ISP's stable edge, not
    /// just what one outbound trace happened to see once. `nil` means
    /// "never externally corroborated," same absent-value convention as
    /// `hostname`/`networkFingerprint` above, not "corroboration
    /// failed." Optional with no default needed at all (unlike
    /// `KnownNetwork.isHome`/`isPublicForCapture`'s `Bool = false`
    /// pattern) since this model's existing optional fields already
    /// establish that lightweight migration handles a new optional
    /// attribute on a model with existing rows fine — only a *mandatory*
    /// new attribute hits the failure `networkFingerprint`'s own doc
    /// comment describes.
    var externallyCorroboratedAt: Date?
    /// How many Path Discovery probes ran, and how many of those
    /// corroborated `address` specifically, on the most recent run —
    /// both `nil` together always (never independently), same "no run
    /// yet" meaning as `externallyCorroboratedAt` being `nil`. Kept
    /// alongside the corroboration timestamp rather than in a separate
    /// model: this is context about the same edge address's external
    /// confirmation, not a new kind of fact.
    var pathDiscoveryProbeCount: Int?
    var pathDiscoveryCorroboratingCount: Int?

    init(address: String, hostname: String?, observedAt: Date = Date(), networkFingerprint: String? = nil) {
        self.address = address
        self.hostname = hostname
        self.observedAt = observedAt
        self.networkFingerprint = networkFingerprint
        self.externallyCorroboratedAt = nil
        self.pathDiscoveryProbeCount = nil
        self.pathDiscoveryCorroboratingCount = nil
    }
}
