import Foundation

/// Checks a small, fixed list of business SaaS services' public status
/// pages — a different question from this app's core network checks
/// ("is the internet reachable"): "are the specific services this
/// business depends on reachable." See DESIGN-NOTES.md's "Business SaaS
/// monitoring" section for the full discovery-vs-monitoring split this
/// prototype comes from; this covers monitoring only, against a fixed
/// service list rather than anything auto-discovered.
///
/// `URLSession`, not a subprocess — this is a WAN JSON fetch to a third
/// party, the same category `PublicIPService`/`HTTPCheckService` already
/// use, not a LAN tool shell-out like `ping`/`arp`/`snmpget`.
struct SaaSStatusService {
    enum Indicator: String {
        case none, minor, major, critical
        /// A genuine fifth Statuspage value, not documented alongside the
        /// other four but confirmed live: Asana's real `summary.json`
        /// returned `"indicator":"maintenance"` (paired with `"Service
        /// Under Maintenance"`) for a scheduled maintenance window
        /// actually in progress (`scheduled_maintenances`, `status:
        /// "in_progress"`) — not an outage of any kind. Before this case
        /// existed, `Indicator(rawValue:)` fell through to `.unknown` for
        /// it, which read identically to a parsing failure (same gray) as
        /// "we don't know what's happening" — wrong on two counts: this
        /// *was* successfully parsed, and what it found isn't a fault.
        case maintenance
        /// Not a Statuspage value — used when a service's shape can't be
        /// classified at all (e.g. an unrecognized `indicator` string),
        /// so a parsing gap reads as "unknown," never silently as
        /// healthy.
        case unknown
    }

    struct MonitoredService {
        /// Which parser this service's endpoint needs — a name-based
        /// dispatch (`service.name == "Slack"`) stopped scaling once a
        /// second non-Statuspage shape (Zendesk) showed up, so this is
        /// explicit per service instead.
        enum Shape {
            case statuspage
            case slack
            case zendesk
            case googleIncidents
            /// A user-added site (`SaaSMonitoringViewModel
            /// .checkUserAddedSites`), not one of the curated table above
            /// — there's no real status API to parse, just "did the
            /// request succeed." See `checkStatus`'s dispatch for why
            /// that's enough on its own: reaching this case at all means
            /// the shared 200-check already passed.
            case reachabilityOnly
        }
        let name: String
        let endpoint: URL
        let shape: Shape
        /// Overrides `generalStatusPageURL`'s default `scheme://host`
        /// derivation. `nil` for every existing entry — confirmed to hold
        /// for all ten of them, so this stays opt-in rather than a second
        /// hand-typed URL everywhere. Needed for Google Workspace: its
        /// `incidents.json` lives under `www.google.com`, but that bare
        /// host is Google's search homepage, not a status page — the real
        /// one is at a specific path on the same host. Google Cloud
        /// doesn't need this; its endpoint host already *is*
        /// `status.cloud.google.com`, the same page a person would visit.
        let dashboardPath: String?

        init(name: String, endpoint: URL, shape: Shape, dashboardPath: String? = nil) {
            self.name = name
            self.endpoint = endpoint
            self.shape = shape
            self.dashboardPath = dashboardPath
        }
    }

    struct CheckResult {
        let indicator: Indicator
        let description: String
        /// Always a real, usable link — never `nil`. The specific
        /// incident's own page when one exists (most informative,
        /// resolved by each `parseXXX` below); otherwise the service's
        /// general status page, resolved once here in `checkStatus` from
        /// `service.endpoint`'s own host rather than a second hand-typed
        /// URL per service that could drift from the endpoint it's
        /// derived from. Shown as a link regardless of health — "check
        /// for yourself" is useful even when everything's reported fine.
        let url: String
    }

    enum SaaSStatusError: Error {
        case unexpectedResponse
    }

    /// Confirmed live via `curl`, not assumed from documentation — same
    /// discipline DESIGN-NOTES.md's own endpoint table was built with.
    /// Every entry here except Slack and Zendesk is a genuine Statuspage.io
    /// `/api/v2/summary.json` endpoint (Trello's is Atlassian-hosted but a
    /// distinct subdomain from Jira/Confluence's, not the same page);
    /// Slack's and Zendesk's are each a different shape despite looking
    /// similar at a glance — see `parseSlack`/`parseZendesk` below.
    static let monitoredServices: [MonitoredService] = [
        MonitoredService(name: "Slack", endpoint: URL(string: "https://slack-status.com/api/v2.0.0/current")!, shape: .slack),
        MonitoredService(name: "Claude", endpoint: URL(string: "https://status.claude.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "ChatGPT", endpoint: URL(string: "https://status.openai.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Jira/Confluence", endpoint: URL(string: "https://status.atlassian.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Zendesk", endpoint: URL(string: "https://status.zendesk.com/api/incidents/active")!, shape: .zendesk),
        MonitoredService(name: "Zoom", endpoint: URL(string: "https://www.zoomstatus.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Trello", endpoint: URL(string: "https://trello.status.atlassian.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Asana", endpoint: URL(string: "https://status.asana.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Notion", endpoint: URL(string: "https://www.notion-status.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Dropbox", endpoint: URL(string: "https://status.dropbox.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Discord", endpoint: URL(string: "https://discordstatus.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "GitHub", endpoint: URL(string: "https://www.githubstatus.com/api/v2/summary.json")!, shape: .statuspage),
        // Confirmed live *during* a real "Minor Service Outage" — not
        // just the healthy path, unlike most of this list's first
        // verification.
        MonitoredService(name: "Cloudflare", endpoint: URL(string: "https://www.cloudflarestatus.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Figma", endpoint: URL(string: "https://status.figma.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "HubSpot", endpoint: URL(string: "https://status.hubspot.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Docusign", endpoint: URL(string: "https://status.docusign.com/api/v2/summary.json")!, shape: .statuspage),
        MonitoredService(name: "Google Cloud", endpoint: URL(string: "https://status.cloud.google.com/incidents.json")!, shape: .googleIncidents),
        MonitoredService(
            name: "Google Workspace",
            endpoint: URL(string: "https://www.google.com/appsstatus/dashboard/incidents.json")!,
            shape: .googleIncidents,
            dashboardPath: "/appsstatus/dashboard/"
        )
    ]

    func checkStatus(_ service: MonitoredService) async throws -> CheckResult {
        var request = URLRequest(url: service.endpoint)
        // Same reasoning as HTTPCheckService: a stale cached response
        // would silently defeat the whole point of checking at all.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // More generous than the 1-2s LAN targets use — this is a WAN
        // fetch to a third party with no reason to assume sub-second
        // response times.
        request.timeoutInterval = 5
        // HEAD, not the default GET, specifically for `.reachabilityOnly`
        // — that shape only ever looks at the status code below, but a
        // plain GET downloads the *entire* response body first regardless,
        // discarded unread. Confirmed live (GitHub #18): a user-added real
        // webpage (unlike the curated list's small JSON endpoints) pulled
        // 337KB on a single poll for a check that only cares whether the
        // server answered — real bandwidth spent every 5-minute cycle.
        // HEAD asks the server itself not to send a body, so the saving is
        // on the wire, not just a client-side discard of data already paid
        // for.
        if service.shape == .reachabilityOnly {
            request.httpMethod = "HEAD"
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SaaSStatusError.unexpectedResponse
        }

        // Handled first and separately: a user-added site needs the
        // status code itself as its whole signal (any 2xx counts, not
        // just exactly 200 the way a real status API's JSON body does),
        // and no body parsing at all, unlike every curated shape below.
        if service.shape == .reachabilityOnly {
            guard (200...299).contains(http.statusCode) else { throw SaaSStatusError.unexpectedResponse }
            return CheckResult(indicator: .none, description: "Reachable", url: service.endpoint.absoluteString)
        }

        guard http.statusCode == 200 else { throw SaaSStatusError.unexpectedResponse }
        let parsed: (indicator: Indicator, description: String, specificURL: String?)
        switch service.shape {
        case .statuspage: parsed = try Self.parseStatuspage(data)
        case .slack: parsed = try Self.parseSlack(data)
        case .zendesk: parsed = try Self.parseZendesk(data)
        case .googleIncidents: parsed = try Self.parseGoogleIncidents(data, service: service)
        case .reachabilityOnly:
            preconditionFailure("reachabilityOnly is handled and returned above, before this switch")
        }
        return CheckResult(
            indicator: parsed.indicator,
            description: parsed.description,
            url: parsed.specificURL ?? Self.generalStatusPageURL(for: service)
        )
    }

    /// The service's general, human-facing status page — derived from
    /// `endpoint`'s own scheme/host rather than a second, hand-typed URL
    /// per service, so there's nothing here that could drift from the
    /// endpoint it's actually fetching. Confirmed this holds for all ten
    /// (each API endpoint lives at the same host as the page a person
    /// would actually visit — e.g. `status.claude.com/api/v2/summary.json`
    /// and `status.claude.com` itself, which matched Claude's own
    /// `page.url` field exactly).
    ///
    /// Not `private` — `SaaSMonitoringViewModel.checkAll()`'s catch branch
    /// (a fetch failure, not a parsed result) needs the same fallback: a
    /// service this Mac couldn't reach right now is still worth a link to
    /// its status page, on the chance the page itself is up even though
    /// this particular fetch wasn't.
    static func generalStatusPageURL(for service: MonitoredService) -> String {
        let base = "\(service.endpoint.scheme ?? "https")://\(service.endpoint.host ?? service.endpoint.absoluteString)"
        guard let path = service.dashboardPath else { return base }
        return base + path
    }

    /// The standard Statuspage.io v2 summary shape — confirmed live for
    /// both Claude and ChatGPT: `{"status": {"indicator": "...",
    /// "description": "..."}, "incidents": [...]}`. `indicator` is one of
    /// `none`/`minor`/`major`/`critical`.
    ///
    /// The top-level `status.description` is a generic aggregate
    /// ("Partial System Outage") — confirmed live that `incidents` (empty
    /// when healthy) carries the *specific* incident instead, e.g. "Degraded
    /// performance on Claude Sonnet 5", plus a `shortlink` straight to
    /// that incident's own page. Preferred over the generic description
    /// whenever a real incident is listed.
    /// Not `private` — same reasoning as `generalStatusPageURL` above:
    /// `NMSTests` reaches these directly via `@testable import`, which
    /// exposes `internal` but not `private`. Fixture-based, no network —
    /// exactly the shape that caught `77912bf` (OpenAI/Notion's omitted
    /// `incidents` key) after the fact; these tests exist so the next
    /// shape drift like it is caught before shipping instead.
    static func parseStatuspage(_ data: Data) throws -> (indicator: Indicator, description: String, specificURL: String?) {
        struct Summary: Decodable {
            struct Status: Decodable {
                let indicator: String
                let description: String
            }
            struct Incident: Decodable {
                let name: String
                let shortlink: String?
            }
            let status: Status
            /// Optional, not `[Incident]` — confirmed live that OpenAI's and
            /// Notion's `summary.json` omit this key entirely when nothing's
            /// active, rather than sending `"incidents": []` the way
            /// Claude's does. A non-optional array made `JSONDecoder` throw
            /// `keyNotFound` for those two every round, which surfaced as a
            /// permanent `.unknown` ("Could not check status") despite the
            /// endpoint itself returning a healthy 200 — same tenant-to-
            /// tenant shape drift this file already tracks for Slack/
            /// Zendesk, just within "Statuspage" instead of between vendors.
            let incidents: [Incident]?
        }
        let decoded = try JSONDecoder().decode(Summary.self, from: data)
        let indicator = Indicator(rawValue: decoded.status.indicator) ?? .unknown
        if let incident = decoded.incidents?.first {
            return (indicator, incident.name, incident.shortlink)
        }
        return (indicator, decoded.status.description, nil)
    }

    /// Slack's own API, not Statuspage — confirmed live, and genuinely
    /// different despite the similar-looking path: `{"status": "ok",
    /// "active_incidents": [...]}`. A plain string, not an
    /// indicator/description object, and no severity grading at all —
    /// only "ok" or not. `active_incidents` empty means healthy;
    /// non-empty means something's wrong, reported as `.major` since
    /// this shape gives no way to distinguish a minor blip from a major
    /// outage the way Statuspage's `indicator` does.
    ///
    /// `title`/`url` per incident — confirmed from Slack's own incident
    /// *history* endpoint (`/api/v2.0.0/history`), which returned real
    /// past incidents shaped `{"title": "...", "url": "https://slack-status.com/...", ...}`.
    /// `active_incidents` itself was only ever observed empty (this Mac
    /// never caught Slack mid-outage), so this shape is inferred from the
    /// history endpoint's identical-looking incident objects, not
    /// confirmed directly against a live active one — worth rechecking
    /// the first time a real active incident actually appears.
    /// Not `private` — see `parseStatuspage`'s note above.
    static func parseSlack(_ data: Data) throws -> (indicator: Indicator, description: String, specificURL: String?) {
        struct SlackStatus: Decodable {
            struct Incident: Decodable {
                let title: String?
                let url: String?
            }
            let status: String
            let activeIncidents: [Incident]

            enum CodingKeys: String, CodingKey {
                case status
                case activeIncidents = "active_incidents"
            }
        }
        let decoded = try JSONDecoder().decode(SlackStatus.self, from: data)
        guard let incident = decoded.activeIncidents.first else {
            return (.none, "All Systems Operational", nil)
        }
        return (.major, incident.title ?? "Active incident reported", incident.url)
    }

    /// Zendesk's own active-incidents endpoint, not Statuspage — confirmed
    /// live: `{"data": [...], "included": [...]}`, a JSON:API-shaped list
    /// where `data` holds every currently active incident. **Only the
    /// empty case (`data: []`, meaning no active incidents) has actually
    /// been observed** — a real incident's exact `attributes` shape is
    /// inferred from Zendesk's documented JSON:API convention
    /// (`attributes.title`), not confirmed against a live one, the same
    /// "hasn't been observed directly yet" gap `PrinterDiscoveryService`'s
    /// own multi-reason parsing flagged for the same reason. Worth
    /// rechecking the first time this actually renders a real Zendesk
    /// incident. No severity grading in this shape either, same as Slack
    /// — any active incident reports as `.major`. No per-incident URL
    /// anywhere in this shape either, unlike Statuspage/Slack — every
    /// Zendesk row falls back to the general status page.
    /// Not `private` — see `parseStatuspage`'s note above.
    static func parseZendesk(_ data: Data) throws -> (indicator: Indicator, description: String, specificURL: String?) {
        struct ZendeskResponse: Decodable {
            struct Incident: Decodable {
                struct Attributes: Decodable {
                    let title: String?
                }
                let attributes: Attributes?
            }
            let data: [Incident]
        }
        let decoded = try JSONDecoder().decode(ZendeskResponse.self, from: data)
        guard !decoded.data.isEmpty else {
            return (.none, "All Systems Operational", nil)
        }
        let titles = decoded.data.compactMap { $0.attributes?.title }
        return (.major, titles.isEmpty ? "Active incident reported" : titles.joined(separator: ", "), nil)
    }

    /// Google Cloud's and Google Workspace's shared `incidents.json` shape
    /// — confirmed live for both, and structurally unlike every other
    /// shape here: not a "current status" summary, a **rolling incident
    /// history** (Google's own published schema at
    /// `status.cloud.google.com/incidents.schema.json` confirms this
    /// directly: `begin`/`created`/`modified`/`end`, not a single
    /// top-level `status` object). "Currently healthy" isn't an explicit
    /// value anywhere in the shape — it's the absence of any incident
    /// with a missing `end`, confirmed live: both endpoints' full history
    /// (4 and 50 entries respectively, at the time this was checked) had
    /// zero incidents with a null `end`, i.e. today's real "all clear"
    /// case for both.
    ///
    /// **Severity mapping is a real judgment call, not confirmed against
    /// a live example of every case.** Google's schema documents
    /// `severity` as "(high, medium)" — only two values, no `low` or
    /// `critical` — and only one real incident (`severity: "medium"`) has
    /// actually been observed through this parser. Mapped conservatively:
    /// `high` → `.major`, `medium` → `.minor`, anything else (including
    /// missing) → `.unknown` rather than guessing at a mapping this
    /// hasn't been checked against. `status_impact` (e.g.
    /// `SERVICE_DISRUPTION`) carries the same kind of signal but has no
    /// documented enum in Google's own schema, so it's used for
    /// description text only, not severity.
    ///
    /// If multiple incidents are ongoing at once (also unobserved, only
    /// ever seen zero at a time so far), the most recently `modified` one
    /// is reported — the rest are real but not surfaced, same trade-off
    /// Statuspage's `incidents.first` makes elsewhere in this file.
    /// Not `private` — see `parseStatuspage`'s note above.
    static func parseGoogleIncidents(_ data: Data, service: MonitoredService) throws -> (indicator: Indicator, description: String, specificURL: String?) {
        struct Incident: Decodable {
            let modified: String
            let end: String?
            let externalDesc: String?
            let severity: String?
            let uri: String?

            enum CodingKeys: String, CodingKey {
                case modified, end, severity, uri
                case externalDesc = "external_desc"
            }
        }
        let decoded = try JSONDecoder().decode([Incident].self, from: data)
        let ongoing = decoded.filter { $0.end == nil }
        guard let incident = ongoing.max(by: { $0.modified < $1.modified }) else {
            return (.none, "All Systems Operational", nil)
        }
        let indicator: Indicator
        switch incident.severity {
        case "high": indicator = .major
        case "medium": indicator = .minor
        default: indicator = .unknown
        }
        let description = incident.externalDesc ?? "Active incident reported"
        let specificURL = incident.uri.map { uri -> String in
            let base = Self.generalStatusPageURL(for: service)
            let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
            return "\(normalizedBase)/\(uri)"
        }
        return (indicator, description, specificURL)
    }
}
