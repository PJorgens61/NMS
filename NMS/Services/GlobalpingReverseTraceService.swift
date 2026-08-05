import Foundation

#if DEBUG
/// Runs a traceroute from several external vantage points back toward a
/// given target (typically this Mac's own public IP) via Globalping
/// (`api.globalping.io`) — the "reverse traceroute" technique explored at
/// length during a real field-testing session (2026-08-04): outbound
/// traceroute alone can't show the return-direction path or corroborate
/// an ISP's edge infrastructure from outside. See `DESIGN-NOTES.md` and
/// `PUNCHLIST.md` for the full research this comes from.
///
/// Deliberately unauthenticated — confirmed live that Globalping's
/// measurement API works fully anonymously, no account/token/credits,
/// unlike RIPE Atlas (which needs a funded account even for a single
/// one-off measurement, and new accounts start at 0 with no way to buy
/// more).
struct GlobalpingReverseTraceService {
    enum GlobalpingError: Error {
        case unexpectedResponse
        case measurementFailed
        case timedOut
    }

    struct ProbeTraceResult {
        struct Hop {
            let hopNumber: Int
            let address: String?
            let hostname: String?
            let roundTripTimesMs: [Double]
        }
        let city: String?
        let country: String?
        let network: String?
        let asn: Int?
        let status: String
        let resolvedAddress: String?
        let hops: [Hop]
    }

    private static let baseURL = "https://api.globalping.io/v1/measurements"

    /// Every operational knob for the reverse-trace measurement, pulled
    /// from `config.json` (see `loadConfig`) rather than hardcoded —
    /// raised directly ("can the configuration options be broken out
    /// into a file that could be changed at runtime so that we can test
    /// options without rebuilding nms?", then again "put all config
    /// parameters in the config file to avoid builds" once
    /// `maxAttempts`/`delaySeconds`/`timeoutSeconds` turned up still
    /// hardcoded as function-default parameters) — same reasoning
    /// `LocalDiagnosticServer`'s `readAsset` already established for the
    /// diagram's CSS/JS. `locations` is a list of Globalping "magic"
    /// strings (country/continent/"world"/etc, whatever the API's own
    /// magic matcher accepts) — each becomes its own `{"magic": ...}`
    /// location object, so e.g. `["USA", "Germany"]` mixes probes from
    /// both rather than requiring a single value. `maxAttempts`/
    /// `delaySeconds` control `fetchResult`'s poll loop; `timeoutSeconds`
    /// is the per-request `URLRequest.timeoutInterval`, shared by both
    /// `createMeasurement` and `fetchResult`.
    struct Config: Decodable {
        var probeCount: Int
        var locations: [String]
        var maxAttempts: Int
        var delaySeconds: Int
        var timeoutSeconds: Double
    }

    private static let defaultConfig = Config(
        probeCount: 5,
        locations: ["USA"],
        maxAttempts: 6,
        delaySeconds: 2,
        timeoutSeconds: 10
    )

    /// `#filePath`-anchored project-root resolution — same pattern
    /// established in `LocalDiagnosticServer.projectRoot()`, duplicated
    /// here rather than shared since the two services have no other
    /// reason to depend on each other.
    private static func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NMS/Services
            .deletingLastPathComponent() // NMS
            .deletingLastPathComponent() // project root
    }

    /// Reads `config.json` fresh from
    /// `GlobalpingReverseTraceServiceAssets/` on every call, not compiled
    /// into the binary — edit the file and rerun Path Discovery to see
    /// the new probe count/locations, no rebuild needed. Falls back to
    /// `defaultConfig` if the file's missing, unreadable, or fails to
    /// parse (e.g. a typo mid-edit) rather than failing the whole run.
    static func loadConfig() -> Config {
        let url = projectRoot()
            .appendingPathComponent("NMS/Services/GlobalpingReverseTraceServiceAssets")
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            print("GlobalpingReverseTraceService: couldn't read config.json, using built-in defaults")
            return defaultConfig
        }
        return config
    }

    /// Creates a one-off traceroute measurement toward `target`, sourced
    /// from `config.json`'s `probeCount` vantage points across its
    /// `locations` by default — the simplest pattern confirmed live to
    /// work well across several rounds the same session. `probeCount`
    /// stays as an explicit override for callers that want one (e.g.
    /// tests); pass `nil` (the default) to use whatever's currently in
    /// the config file. No ASN/provider-specific targeting here
    /// deliberately — that was useful for manual investigation but is
    /// over-scoped for this button's first version; stays as a manual
    /// `curl` technique for now (see `PUNCHLIST.md`). Returns the
    /// measurement ID to poll via `fetchResult`.
    func createMeasurement(target: String, probeCount: Int? = nil) async throws -> String {
        guard let url = URL(string: Self.baseURL) else {
            throw GlobalpingError.unexpectedResponse
        }
        let config = Self.loadConfig()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same reasoning as every other outbound check in this app
        // (HTTPCheckService/SaaSStatusService/ISPIdentityService): a
        // stale cached response would defeat the point of a fresh check.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = config.timeoutSeconds
        let body: [String: Any] = [
            "type": "traceroute",
            "target": target,
            "locations": config.locations.map { ["magic": $0] },
            "limit": probeCount ?? config.probeCount
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GlobalpingError.unexpectedResponse
        }
        return try Self.parseMeasurementID(data)
    }

    /// Not `private` — `NMSTests` reaches this directly via `@testable
    /// import`, same reasoning as `SaaSStatusService.parseXXX`: fixture-
    /// based tests against a real captured response shape, no network.
    static func parseMeasurementID(_ data: Data) throws -> String {
        struct CreateResponse: Decodable {
            let id: String
        }
        let decoded = try JSONDecoder().decode(CreateResponse.self, from: data)
        return decoded.id
    }

    /// Polls the measurement until it's finished, up to `maxAttempts`
    /// tries with a fixed delay between them — confirmed live,
    /// repeatedly, the same session that Globalping's one-off
    /// traceroutes finish in a few seconds in practice, so a short fixed
    /// delay is enough rather than needing real exponential backoff.
    /// Throws `.measurementFailed` immediately if Globalping itself
    /// reports the measurement failed, rather than polling out the full
    /// `maxAttempts` for something that's never going to finish.
    /// `maxAttempts`/`delaySeconds` default to `config.json`'s values
    /// (`nil` means "use whatever's currently configured"); both stay as
    /// explicit overrides for callers that want one, e.g. tests.
    func fetchResult(measurementID: String, maxAttempts: Int? = nil, delaySeconds: Int? = nil) async throws -> [ProbeTraceResult] {
        let config = Self.loadConfig()
        let maxAttempts = maxAttempts ?? config.maxAttempts
        let delayNanoseconds = UInt64(delaySeconds ?? config.delaySeconds) * 1_000_000_000
        guard let url = URL(string: "\(Self.baseURL)/\(measurementID)") else {
            throw GlobalpingError.unexpectedResponse
        }
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = config.timeoutSeconds
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw GlobalpingError.unexpectedResponse
            }
            let (status, results) = try Self.parseMeasurement(data)
            switch status {
            case "finished":
                return results
            case "failed":
                throw GlobalpingError.measurementFailed
            default:
                continue
            }
        }
        throw GlobalpingError.timedOut
    }

    /// Not `private` — same reasoning as `parseMeasurementID` above.
    /// Confirmed against real captured response shapes (2026-08-04,
    /// several live rounds): a non-responding hop appears as a real
    /// entry in `hops[]` at its correct position (`resolvedAddress`/
    /// `resolvedHostname: null`, `timings: []`), not omitted — so hop
    /// numbers are derived from array position, not a separate field
    /// Globalping doesn't actually send.
    static func parseMeasurement(_ data: Data) throws -> (status: String, results: [ProbeTraceResult]) {
        struct MeasurementResponse: Decodable {
            struct Result: Decodable {
                struct Probe: Decodable {
                    let city: String?
                    let country: String?
                    let network: String?
                    let asn: Int?
                }
                struct HopTiming: Decodable {
                    let rtt: Double?
                }
                struct Hop: Decodable {
                    let resolvedAddress: String?
                    let resolvedHostname: String?
                    let timings: [HopTiming]
                }
                struct Inner: Decodable {
                    let status: String
                    let resolvedAddress: String?
                    let hops: [Hop]?
                }
                let probe: Probe
                let result: Inner
            }
            let status: String
            let results: [Result]?
        }
        let decoded = try JSONDecoder().decode(MeasurementResponse.self, from: data)
        let probeResults = (decoded.results ?? []).map { entry -> ProbeTraceResult in
            let hops = (entry.result.hops ?? []).enumerated().map { index, hop in
                ProbeTraceResult.Hop(
                    hopNumber: index + 1,
                    address: hop.resolvedAddress,
                    hostname: hop.resolvedHostname,
                    roundTripTimesMs: hop.timings.compactMap(\.rtt)
                )
            }
            return ProbeTraceResult(
                city: entry.probe.city,
                country: entry.probe.country,
                network: entry.probe.network,
                asn: entry.probe.asn,
                status: entry.result.status,
                resolvedAddress: entry.result.resolvedAddress,
                hops: hops
            )
        }
        return (decoded.status, probeResults)
    }

    /// Strips a *safe, narrow* set of leading interface-label segments
    /// from a hop hostname to find the underlying device's own name —
    /// e.g. `lo0.bng3.snfcca05.sonic.net` and `305.ae0.bng3.snfcca05.sonic.net`
    /// both reduce to `bng3.snfcca05.sonic.net`. Confirmed live
    /// (2026-08-04) against a real device: the bare stem and an
    /// explicit `lo0.` prefix both resolved to the identical address,
    /// and a VLAN-numbered `ae0` sibling (already observed as a real hop
    /// elsewhere in the same data, not guessed) shared the same stem.
    ///
    /// Deliberately conservative, not a general cross-ISP parser —
    /// interface-naming conventions vary too much between operators to
    /// guess reliably (same caveat already on `PUNCHLIST.md`'s
    /// alias-resolution entry). Only strips labels matching Sonic's own
    /// confirmed shapes (`lo`/`ae` plus digits, or a purely numeric
    /// label) from the *front*, one at a time, stopping at the first
    /// label that doesn't match — `nil` if the very first label already
    /// doesn't match anything recognized, rather than guessing.
    static func deviceStem(fromHostname hostname: String) -> String? {
        var labels = hostname.split(separator: ".").map(String.init)
        // Need at least 3 labels left over after stripping (device +
        // domain, e.g. "bng3.sonic.net") -- 2 would just be the bare
        // registrable domain ("sonic.net") with no device-specific part
        // at all, not a real stem.
        guard labels.count > 3 else { return nil }
        var strippedAny = false
        while let first = labels.first, labels.count > 3, isInterfaceLabel(first) {
            labels.removeFirst()
            strippedAny = true
        }
        guard strippedAny else { return nil }
        return labels.joined(separator: ".")
    }

    private static func isInterfaceLabel(_ label: String) -> Bool {
        if label.allSatisfy(\.isNumber), !label.isEmpty { return true }
        for prefix in ["lo", "ae"] {
            guard label.hasPrefix(prefix) else { continue }
            let rest = label.dropFirst(prefix.count)
            if rest.isEmpty || rest.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}
#endif
