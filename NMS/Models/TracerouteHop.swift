import Foundation

/// One hop in a traceroute path.
struct TracerouteHop: Equatable, Codable, Identifiable {
    var id: Int { hopNumber }

    let hopNumber: Int
    /// `nil` if this hop didn't respond (shown as `*` by traceroute).
    let address: String?
    let hostname: String?
    let roundTripMs: Double?

    /// `true` if RFC 1918 private, `false` if a real internet address,
    /// `nil` if this hop didn't respond so there's nothing to classify.
    var isLocal: Bool? {
        guard let address else { return nil }
        return IPClassifier.isRFC1918(address)
    }
}
