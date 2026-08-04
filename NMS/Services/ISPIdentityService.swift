import Foundation

/// Identifies the ISP behind the Mac's current public IP via RDAP (the
/// modern, structured successor to WHOIS) — a sharper signal than location
/// for this specific question, and one this app already has every
/// ingredient for: `PublicIPViewModel` fetches the public IP every round
/// already, no new permission needed. See `DESIGN-NOTES.md`'s "ISP status
/// pages" section for the full research this comes from.
///
/// Deliberately identification-only, not monitoring the way
/// `SaaSStatusService` does — confirmed live that consumer ISPs don't
/// share a common structured-feed platform the way the SaaS ecosystem
/// converged on Statuspage.io. This is "get one click closer to checking
/// yourself," not "poll for health."
struct ISPIdentityService {
    enum ISPIdentityError: Error {
        case unexpectedResponse
        case notFound
    }

    /// `rdap.org` is a bootstrap service — it redirects to whichever
    /// regional registry (ARIN/RIPE/APNIC/etc.) actually holds the record,
    /// so one URL works globally rather than needing region detection
    /// first. `URLSession` follows the redirect automatically.
    func identify(ip: String) async throws -> String {
        guard let url = URL(string: "https://rdap.org/ip/\(ip)") else {
            throw ISPIdentityError.unexpectedResponse
        }
        var request = URLRequest(url: url)
        // Same reasoning as HTTPCheckService/SaaSStatusService: a stale
        // cached response would defeat the point of checking at all.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ISPIdentityError.unexpectedResponse
        }
        return try Self.parseRegistrantName(data)
    }

    /// The exact field path, confirmed live by walking a real captured
    /// RDAP response (this household's own, Sonic.net) byte-for-byte:
    /// `entities[]` → the entity whose `roles` contains `"registrant"` →
    /// `vcardArray[1]` (an array of `[key, params, type, value]` tuples,
    /// not `Codable`-friendly since it mixes types — parsed with
    /// `JSONSerialization` instead) → the tuple whose first element is
    /// `"fn"` → its 4th element, the actual name (`"Sonic.net, LLC"`).
    ///
    /// Falls back to `entities.first` if no entity is tagged
    /// `"registrant"` — registries aren't perfectly consistent about
    /// this — and throws `.notFound` rather than guessing if that still
    /// doesn't yield an `"fn"`. Not `private` — `NMSTests` calls this
    /// directly via `@testable import`, same reasoning
    /// `SaaSStatusService`'s `parseXXX` functions are `internal` too.
    static func parseRegistrantName(_ data: Data) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entities = json["entities"] as? [[String: Any]],
            !entities.isEmpty
        else {
            throw ISPIdentityError.notFound
        }
        let entity = entities.first { ($0["roles"] as? [String])?.contains("registrant") == true } ?? entities[0]
        guard
            let vcardArray = entity["vcardArray"] as? [Any],
            vcardArray.count > 1,
            let properties = vcardArray[1] as? [[Any]],
            let fnProperty = properties.first(where: { ($0.first as? String) == "fn" }),
            let name = fnProperty.last as? String
        else {
            throw ISPIdentityError.notFound
        }
        return name
    }

    /// A small, curated table mapping an RDAP-confirmed registrant
    /// organization name to that ISP's real, public status/outage page —
    /// checked one real entry at a time, per `DESIGN-NOTES.md`'s own
    /// discipline (the two wrong guesses it found for other ISPs are
    /// exactly why this isn't built speculatively).
    ///
    /// - `"Sonic.net, LLC"`: confirmed twice — both of this app's
    ///   development Macs' real public IPs resolve to this exact name,
    ///   and `sonicstatus.com` is confirmed live, public, no login.
    /// - AT&T/Xfinity/MonkeyBrains: their status-page URLs are confirmed
    ///   live (browser-verified, `DESIGN-NOTES.md`'s SF-94131 table), but
    ///   the RDAP name keys here are best-effort — there's no real
    ///   customer on those ISPs to verify the name against, and RDAP
    ///   registrant names are inconsistent enough (legal entity vs.
    ///   brand vs. reseller) that these may simply never match. Same
    ///   "hasn't been observed directly yet" gap this codebase already
    ///   accepts for Zendesk's incident shape.
    ///
    /// Astound Broadband (formerly RCN/Grande/Wave in many regions) is
    /// deliberately **not** here — checked live via ARIN's org search,
    /// which turned up real registered names (`"Astound Broadband LLC"`,
    /// `"RCN Corporation"`, `"RCN"`) but no public, unauthenticated
    /// status/outage page for any of them (every plausible URL 404s or
    /// fails to resolve; their support site only offers a coverage/sales
    /// "check for service" tool). An organization not in this table
    /// still displays correctly wherever `organizationName` is shown —
    /// it just gets no link icon, which is the correct behavior here,
    /// not a gap to fill later.
    static let statusPages: [String: String] = [
        "Sonic": "https://sonicstatus.com/",
        "AT&T": "https://www.att.com/outages/",
        "Comcast": "https://www.xfinity.com/support/statusmap",
        "MonkeyBrains": "https://www.monkeybrains.net/map/"
    ]

    /// Maps a *substring* of an RDAP registrant name to a short,
    /// user-facing ISP brand name — checked in order, first match wins.
    /// Substring rather than exact match: confirmed live (2026-08-04)
    /// that the same ISP's RDAP registrant name varies by address block
    /// — "Comcast Cable Communications, LLC" for one block, "Comcast IP
    /// Services, L.L.C." for another (the first public hop past a home
    /// router vs. the Mac's own public IP, on the very same network),
    /// both really Comcast/Xfinity. An exact-match table would need a
    /// separate entry per block-naming variant and silently miss any not
    /// yet observed — exactly the "legal entity vs. brand vs. reseller"
    /// inconsistency this file's own `statusPages` doc comment already
    /// flagged as a real risk for AT&T/Xfinity/MonkeyBrains, now
    /// confirmed directly rather than just anticipated. Falls back to the
    /// full RDAP name verbatim when nothing matches, same as before this
    /// table existed — an unrecognized organization still displays
    /// correctly, just unshortened.
    static let shortNames: [(match: String, short: String)] = [
        ("Comcast", "Comcast"),
        ("AT&T", "AT&T"),
        ("Sonic.net", "Sonic"),
        ("MonkeyBrains", "MonkeyBrains")
    ]

    static func shortName(for organizationName: String) -> String {
        shortNames.first { organizationName.contains($0.match) }?.short ?? organizationName
    }

    /// Routed through `shortName(for:)`, not a direct `statusPages`
    /// lookup — see `shortNames`'s doc comment for why an exact match on
    /// the raw RDAP name is too brittle to rely on here specifically:
    /// this is the one place a missed match silently drops a real,
    /// working status-page link rather than just showing a longer name.
    func statusPageURL(forOrganization name: String) -> String? {
        Self.statusPages[Self.shortName(for: name)]
    }
}
