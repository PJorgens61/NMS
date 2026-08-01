import Foundation

/// One rung in the "is the internet actually working" dependency chain,
/// ordered low (most fundamental) to high (most dependent on everything
/// below it): interface -> network association -> local router -> ISP
/// edge router -> DNS -> HTTP. Purely derived from other view models'
/// already-published state for display — not persisted.
enum LayerStatus {
    case healthy
    case unhealthy
    /// Not a failure — just nothing to judge yet (e.g. the ISP router hop
    /// hasn't been confirmed, or a check hasn't run).
    case unknown
}

struct ConnectionLayer: Identifiable {
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

    init(id: String, label: String, detail: String, status: LayerStatus, correlatedWithChange: Bool = false, url: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.status = status
        self.correlatedWithChange = correlatedWithChange
        self.url = url
    }
}
