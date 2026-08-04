import Foundation

/// One rung in the "is the internet actually working" dependency chain,
/// ordered low (most fundamental) to high (most dependent on everything
/// below it): interface -> network association -> local router -> ISP
/// edge router -> DNS -> HTTP. Purely derived from other view models'
/// already-published state for display — not persisted.
enum LayerStatus: Equatable {
    case healthy
    case unhealthy
    /// Not a failure — just nothing to judge yet (e.g. the ISP router hop
    /// hasn't been confirmed, or a check hasn't run).
    case unknown
}

/// `Equatable` so `ConnectionLayerRow` (a plain value input) can be
/// diffed field-by-field — a layer whose contents didn't actually change
/// between two `NetworkTile.body` evaluations lets SwiftUI skip
/// re-rendering that row entirely, rather than the whole `Grid`
/// re-evaluating just because *some* sibling layer changed. See
/// `PUNCHLIST.md`'s view-structure factoring entry.
struct ConnectionLayer: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    let status: LayerStatus
    /// Only meaningful for layers backed by a `ConnectivityCheck` (Local
    /// Router, Internet, DNS, HTTP) — `false` for Interface/Network/ISP
    /// Router, which aren't derived from one.
    let correlatedWithChange: Bool
    /// A web link relevant to this layer — `nil` for every layer except
    /// Local Router, which sets this to its own LAN admin UI address once
    /// known. Same "only some layers have something real to say" shape
    /// `correlatedWithChange` already established, not a new pattern.
    let url: String?
    /// A tooltip explaining this layer's current `detail` text, when it
    /// isn't self-explanatory — `nil` for most layers. Same "only some
    /// layers have something real to say" shape as `url`/
    /// `correlatedWithChange`. Threaded through to `statusGridRow`'s own
    /// `dotHelp:` parameter by `ConnectionLayerRow`.
    let help: String?

    init(id: String, label: String, detail: String, status: LayerStatus, correlatedWithChange: Bool = false, url: String? = nil, help: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.status = status
        self.correlatedWithChange = correlatedWithChange
        self.url = url
        self.help = help
    }
}
