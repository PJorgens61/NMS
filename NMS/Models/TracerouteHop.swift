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
    /// `traceroute`'s own timing initially — a single, unretried probe
    /// (`-q 1 -w 1`), inherently noisy, and specifically unreliable right
    /// after a topology change before a fresh Wi-Fi association has
    /// settled (see `BUGS.md`'s "First traceroute after joining a network
    /// reports inflated latency"). `var`, not `let`, like `hostname` above,
    /// specifically so `TracerouteViewModel.enrichRoundTrips` can replace
    /// it with a real, direct ping's round-trip time shortly after — the
    /// same mechanism `ConnectivityViewModel` already trusts for the
    /// *confirmed* ISP edge router's ongoing latency, just applied to
    /// every hop in the path rather than only the one being monitored.
    var roundTripMs: Double?

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
