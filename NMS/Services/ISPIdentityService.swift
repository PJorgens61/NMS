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
        "MonkeyBrains": "https://www.monkeybrains.net/map/",
        // Both live-verified 2026-08-04 (real browser navigation, not just
        // search snippets): loads with no login, shows real live data.
        "Spectrum": "https://www.spectrum.net/outage-map",
        // Confirmed real and live (timestamped "LAST UPDATED..." on load,
        // no sign-in), but it's specifically Cox *Voice* outages, not
        // labeled Internet, and California-specific -- the general
        // /outages.html page requires an address or sign-in and fails
        // this table's public-unauthenticated bar. Kept anyway: an
        // outage large enough to hit 100+ Voice customers in a zip code
        // almost always means the same zip's Cox Internet is affected
        // too, not a phone-only signal.
        "Cox": "https://www.cox.com/residential/support/outages/ca-outage-map.html"
        // Optimum and WOW! checked live the same day but NOT added:
        // Optimum's page (optimum.com/outage-map) loads but shows no
        // outage content and fires no data request, sitting behind a
        // Cloudflare bot-challenge; WOW!'s check was interrupted by a
        // tooling failure before it could be confirmed either way. Both
        // still have real curated short-name entries above -- this is
        // only about the status-page link.
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
        ("MonkeyBrains", "MonkeyBrains"),
        // Added from desk research (Google search, not live RDAP-verified
        // against a real customer on each ISP) -- see
        // isp-shortname-quick-research.md. A brand-mismatch case each,
        // same reason Comcast/AT&T are here: generic-word-stripping alone
        // can't get from the legal name to the name customers recognize.
        ("Charter", "Spectrum"),
        ("Cox", "Cox"),
        // Altice USA renamed to Optimum Communications, Inc. in Nov 2025;
        // matching both catches RDAP records still under the old name.
        ("Altice", "Optimum"),
        ("Optimum", "Optimum"),
        ("WideOpenWest", "WOW!")
    ]

    /// Generic corporate words stripped from an RDAP name that doesn't
    /// match anything in `shortNames` above — a cheap, general fallback
    /// so an *unrecognized* ISP still displays reasonably cleaned up
    /// ("XYZ Broadband Communications, LLC" → "XYZ") rather than the
    /// full raw legal string, without needing a curated entry for every
    /// ISP that exists. Deliberately doesn't replace the curated table
    /// and never overrides it: stripping generic words can't fix a
    /// genuine brand mismatch (stripping "Charter Communications LLC"
    /// down to "Charter" still isn't "Spectrum," the name customers
    /// actually recognize) — only a real curated entry can, so
    /// `shortName(for:)` always checks `shortNames` first.
    private static let genericWords = [
        "Telecommunications", "Communications", "Broadband", "Network",
        "Networks", "Cable", "Services", "Holdings", "Corporation",
        "Corp.", "Corp", "Inc.", "Inc", "LLC", "L.L.C.", "Ltd.", "Ltd"
    ]

    /// Word-boundary removal, not a raw substring strip — "Inc" inside
    /// "Incorporated" shouldn't be touched, only "Inc" as its own word.
    /// Lookarounds (`(?<!\w)`/`(?!\w)`), not `\b`: a plain `\b` fails at
    /// the very end of the string right after a suffix ending in a
    /// period ("...L.L.C." with nothing following) — `\b` needs an
    /// actual word/non-word *transition*, and both "the period" and
    /// "end of string" count as non-word, so no transition exists there.
    /// Confirmed by direct testing against "Comcast IP Services,
    /// L.L.C." before shipping this, not assumed. The lookaround form
    /// only asks "is a word character adjacent," which end-of-string
    /// trivially satisfies as "no," fixing exactly this case.
    /// Leftover punctuation/whitespace the removals leave behind (a
    /// dangling comma, a trailing period, doubled spaces) gets cleaned
    /// up after.
    static func stripGenericWords(_ name: String) -> String {
        var result = name
        for word in genericWords {
            result = result.replacingOccurrences(
                of: "(?<!\\w)\(NSRegularExpression.escapedPattern(for: word))(?!\\w)",
                with: "",
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(of: #"\s*,\s*"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func shortName(for organizationName: String) -> String {
        if let curated = shortNames.first(where: { organizationName.contains($0.match) })?.short {
            return curated
        }
        let stripped = stripGenericWords(organizationName)
        return stripped.isEmpty ? organizationName : stripped
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
