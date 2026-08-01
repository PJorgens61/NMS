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
        }
        let name: String
        let endpoint: URL
        let shape: Shape
    }

    struct CheckResult {
        let indicator: Indicator
        let description: String
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
        MonitoredService(name: "Dropbox", endpoint: URL(string: "https://status.dropbox.com/api/v2/summary.json")!, shape: .statuspage)
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SaaSStatusError.unexpectedResponse
        }
        switch service.shape {
        case .statuspage: return try Self.parseStatuspage(data)
        case .slack: return try Self.parseSlack(data)
        case .zendesk: return try Self.parseZendesk(data)
        }
    }

    /// The standard Statuspage.io v2 summary shape — confirmed live for
    /// both Claude and ChatGPT: `{"status": {"indicator": "...",
    /// "description": "..."}, ...}`. `indicator` is one of
    /// `none`/`minor`/`major`/`critical`.
    private static func parseStatuspage(_ data: Data) throws -> CheckResult {
        struct Summary: Decodable {
            struct Status: Decodable {
                let indicator: String
                let description: String
            }
            let status: Status
        }
        let decoded = try JSONDecoder().decode(Summary.self, from: data)
        return CheckResult(
            indicator: Indicator(rawValue: decoded.status.indicator) ?? .unknown,
            description: decoded.status.description
        )
    }

    /// Slack's own API, not Statuspage — confirmed live, and genuinely
    /// different despite the similar-looking path: `{"status": "ok",
    /// "active_incidents": [...]}`. A plain string, not an
    /// indicator/description object, and no severity grading at all —
    /// only "ok" or not. `active_incidents` empty means healthy;
    /// non-empty means something's wrong, reported as `.major` since
    /// this shape gives no way to distinguish a minor blip from a major
    /// outage the way Statuspage's `indicator` does.
    private static func parseSlack(_ data: Data) throws -> CheckResult {
        struct SlackStatus: Decodable {
            struct Incident: Decodable {
                let name: String?
            }
            let status: String
            let activeIncidents: [Incident]

            enum CodingKeys: String, CodingKey {
                case status
                case activeIncidents = "active_incidents"
            }
        }
        let decoded = try JSONDecoder().decode(SlackStatus.self, from: data)
        guard !decoded.activeIncidents.isEmpty else {
            return CheckResult(indicator: .none, description: "All Systems Operational")
        }
        let names = decoded.activeIncidents.compactMap(\.name)
        return CheckResult(
            indicator: .major,
            description: names.isEmpty ? "Active incident reported" : names.joined(separator: ", ")
        )
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
    /// — any active incident reports as `.major`.
    private static func parseZendesk(_ data: Data) throws -> CheckResult {
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
            return CheckResult(indicator: .none, description: "All Systems Operational")
        }
        let titles = decoded.data.compactMap { $0.attributes?.title }
        return CheckResult(
            indicator: .major,
            description: titles.isEmpty ? "Active incident reported" : titles.joined(separator: ", ")
        )
    }
}
