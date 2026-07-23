import Foundation
import SwiftData

/// Persisted history of the ISP's edge router (the first non-RFC1918 hop
/// in the traceroute path — see `TracerouteViewModel`). Like
/// `PublicIPRecord`, only real changes get a row, not a per-run log.
@Model
final class ProviderEdgeRecord {
    var address: String
    var hostname: String?
    var observedAt: Date

    init(address: String, hostname: String?, observedAt: Date = Date()) {
        self.address = address
        self.hostname = hostname
        self.observedAt = observedAt
    }
}
