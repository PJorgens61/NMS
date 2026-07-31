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
/// Existed for a while with no UI surfacing it at all — `SnapshotStore
/// .fetchProviderEdgeHistory` was built and unused until Path to
/// Internet needed real, naturally-growing content of its own (see
/// `ContentView.tracerouteSection`'s edge-history addition): the exact
/// history this type already tracked was sitting right there.
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
