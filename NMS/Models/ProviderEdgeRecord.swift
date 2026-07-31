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

    init(address: String, hostname: String?, observedAt: Date = Date(), networkFingerprint: String? = nil) {
        self.address = address
        self.hostname = hostname
        self.observedAt = observedAt
        self.networkFingerprint = networkFingerprint
    }
}
