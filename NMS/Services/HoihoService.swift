import Foundation

#if DEBUG
/// Looks up embedded geolocation hints in router hostnames via CAIDA's
/// Hoiho API (api.hoiho.caida.org) -- the published, state-of-the-art
/// tool for exactly this (Luckie, Huffaker, Marder, Bischof, Fletcher,
/// claffy, "Learning to Extract Geographic Information from Internet
/// Router Hostnames," CoNEXT 2021). Raised directly after a live Path
/// Discovery session surfaced two very different ISP hostname "dialects"
/// in the same topology diagram (Sonic's CLLI-style `snfcca05`/
/// `colaca01`, Cogent's airport-code `sfo01`), and research turned up
/// that those are the two dominant real-world patterns generally, not
/// something specific to those two networks -- rather than hand-rolling
/// a regex heuristic for both, Hoiho already is one, trained on CAIDA's
/// own topology dataset (ITDK), with a free public API matching the same
/// unauthenticated-HTTP-call shape `GlobalpingReverseTraceService`
/// already uses.
///
/// Debug-only, same tier as `GlobalpingReverseTraceService`/Path
/// Discovery itself -- this exists purely to annotate that page's
/// topology diagram, not for anything the always-on monitoring path
/// depends on.
enum HoihoService {
    enum HoihoError: Error {
        case unexpectedResponse
    }

    private static let baseURL = "https://api.hoiho.caida.org/lookups"

    /// One hostname's geolocation hint, as much of it as Hoiho actually
    /// extracted. Most fields come back `nil` for a hostname it doesn't
    /// recognize a pattern in at all -- confirmed live: only 2 of 5 real
    /// hostnames tried from tonight's own Path Discovery run matched
    /// anything. Even a match doesn't always carry every field: a bare
    /// CLLI-code match can arrive with `clli` set but no resolved
    /// `place`/`lat`/`lng` -- confirmed live against
    /// `305.ae0.bng3.snfcca05.sonic.net`, which matched only `clli:
    /// "snfcca"`. `lat`/`lng` are strings, not numbers, matching the
    /// API's own OpenAPI schema (`GET /openapi.json`) and confirmed
    /// against a real response, not assumed.
    struct HostnameInfo: Decodable {
        var hostname: String
        var place: String?
        var st: String?
        var cc: String?
        var lat: String?
        var lng: String?
        var iata: String?
        var clli: String?
        var locode: String?

        /// A short, human-readable summary for display next to a hop --
        /// `nil` when nothing usable came back at all. Prefers a resolved
        /// place name; falls back to whatever raw code Hoiho found (IATA/
        /// CLLI/UN LOCODE) when the place itself didn't resolve, same
        /// "show the real partial signal, don't hide it" posture this
        /// app already applies elsewhere (e.g. `TracerouteHop`'s gap
        /// handling, `KnownNetwork.subnet`'s empty-string-for-a-legacy-row
        /// case).
        var displayLabel: String? {
            if let place {
                return [place, st].compactMap { $0 }.joined(separator: ", ")
            }
            return iata ?? clli ?? locode
        }
    }

    private struct LookupResponse: Decodable {
        var matches: [HostnameInfo]?
    }

    /// One request for the whole list, via the bulk `POST` endpoint --
    /// the API's own description asks for exactly this ("Please limit to
    /// 1 request/sec. Use POST for bulk requests"), and every caller here
    /// already gathers every hostname it needs before rendering, so
    /// there's naturally only ever one call per Path Discovery run.
    /// Hostnames Hoiho doesn't recognize simply don't appear in the
    /// returned dictionary -- not an error, real information (nothing
    /// embedded there that Hoiho's ruleset knows how to read).
    static func lookup(hostnames: [String]) async throws -> [String: HostnameInfo] {
        guard let url = URL(string: baseURL), !hostnames.isEmpty else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same reasoning as every other outbound check in this app
        // (Globalping included): a stale cached response would defeat
        // the point of a fresh lookup, though in practice Hoiho's
        // ruleset only updates occasionally (`Summary.ruleset_date`).
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(Array(Set(hostnames)).sorted())
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HoihoError.unexpectedResponse
        }
        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        var byHostname: [String: HostnameInfo] = [:]
        for match in decoded.matches ?? [] { byHostname[match.hostname] = match }
        return byHostname
    }
}
#endif
