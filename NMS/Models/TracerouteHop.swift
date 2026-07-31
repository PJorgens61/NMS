import Foundation

/// One hop in a traceroute path.
struct TracerouteHop: Equatable, Codable, Identifiable {
    var id: Int { hopNumber }

    let hopNumber: Int
    /// `nil` if this hop didn't respond (shown as `*` by traceroute).
    let address: String?
    /// Always `nil` immediately after a trace — `TracerouteService` runs
    /// with `-n`, so this is never populated by parsing traceroute's own
    /// output anymore. `var`, not `let`, specifically so
    /// `TracerouteViewModel`'s reverse-DNS enrichment can patch it in
    /// after the fact without reconstructing the whole hop.
    var hostname: String?
    let roundTripMs: Double?

    /// `true` if this hop's address isn't really "on the internet" — RFC
    /// 1918 private space, or the carrier-grade NAT range an ISP uses
    /// internally to share one public IP across several customers. `false`
    /// if it's a real, publicly routable address. `nil` if the hop didn't
    /// respond, so there's nothing to classify.
    ///
    /// CGNAT is folded in alongside RFC 1918 (originally this was RFC
    /// 1918 only) because `suggestedEdgeHop` picks the first hop where
    /// this is `false` — without this, a compliant CGNAT hop (real range,
    /// 100.64.0.0/10) would have been wrongly treated as "the real ISP
    /// edge," since it isn't RFC 1918 but also isn't actually the
    /// internet. See `TracerouteViewModel.leadingNonInternetHopCount`.
    var isLocal: Bool? {
        guard let address else { return nil }
        return IPClassifier.isRFC1918(address) || IPClassifier.isCGNAT(address)
    }
}
