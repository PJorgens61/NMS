import Foundation

/// Async client for FW (github.com/PJorgens61/FW) — a separate,
/// internet-hosted companion service that tests what's reachable on this
/// Mac's own public IP from outside, requested here and polled to
/// completion. Field-for-field against FW's own `docs/api.md`, which is
/// the source of truth for this contract, not this file.
///
/// `URLSession`, same category as `SaaSStatusService`/`PublicIPService` —
/// a WAN JSON fetch to a server this Mac doesn't control, not a LAN
/// subprocess shell-out like `ping`/`snmpget`.
///
/// Deliberately stateless itself, same as FW's own server: every call
/// takes exactly what it needs and returns exactly what came back, no
/// caching or retry logic here. `FirewallVisibilityViewModel` owns the
/// poll loop and the local history — see its doc comment for why (FW's
/// own design keeps the server itself free of any persisted record of
/// what was scanned).
struct FWClient {
    enum FWClientError: Error, Equatable {
        /// No server URL and/or device token configured yet — see
        /// `FeatureFlags.firewallServerURL`/`FWKeychain.token()`.
        case notConfigured
        case invalidResponse
        case server(status: Int, message: String?)

        var displayMessage: String {
            switch self {
            case .notConfigured:
                return "Firewall Visibility isn't configured yet — set a server URL and device token in Preferences."
            case .invalidResponse:
                return "FW server sent an unrecognized response."
            case let .server(status, message):
                return message ?? "FW server returned HTTP \(status)."
            }
        }
    }

    struct PortResult: Codable, Equatable {
        let address: String
        let port: Int
        let state: String
    }

    /// One hop of a `/v1/traces` result — mirrors Globalping's own
    /// gap convention (see `GlobalpingReverseTraceService`'s doc
    /// comment): a non-responding hop still appears in position with
    /// every field `nil`, rather than being omitted, matching FW's own
    /// contract (PJorgens61/FW#1).
    struct TraceHop: Codable, Equatable {
        let address: String?
        let hostname: String?
        let rttMs: Double?
    }

    /// Same shape/reasoning as `ScanJob` above, for `/v1/traces`
    /// instead of `/v1/scans` — covers both the just-started shape
    /// (`hops` empty) and the polled shape (`hops` populated once
    /// `status == "complete"`).
    struct TraceJob {
        let id: String
        let status: String
        let pollAfterMs: Int
        let hops: [TraceHop]
    }

    /// One `/v1/scans` or `/v1/scans/{id}` round-trip's worth of state —
    /// covers both the just-started shape (`targetIPv4`/`targetIPv6` set,
    /// `results` empty) and the polled shape (`startedAt`/`completedAt`/
    /// `results` set once `status == "complete"`), since callers need to
    /// thread the job ID and poll interval through either way.
    struct ScanJob {
        let id: String
        let status: String
        let pollAfterMs: Int
        let targetIPv4: String?
        let targetIPv6: [String]
        let startedAt: Date?
        let completedAt: Date?
        let results: [PortResult]
    }

    private let baseURL: URL
    private let token: String

    /// `nil` whenever either half of configuration is missing — every
    /// call site handles that as `FWClientError.notConfigured` rather
    /// than constructing a client that can't actually reach anything.
    init?(baseURLString: String?, token: String?) {
        guard
            let baseURLString, !baseURLString.isEmpty,
            let token, !token.isEmpty,
            let url = URL(string: baseURLString)
        else {
            return nil
        }
        baseURL = url
        self.token = token
    }

    func startScan(ports: [Int]) async throws -> ScanJob {
        var request = makeRequest(path: "v1/scans", method: "POST")
        request.httpBody = try JSONEncoder().encode(StartScanRequestBody(ports: ports, protocolName: "tcp"))
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        return try Self.decodeStartScanResponse(data)
    }

    func pollJob(id: String) async throws -> ScanJob {
        let request = makeRequest(path: "v1/scans/\(id)", method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        return try Self.decodeJobStatusResponse(data)
    }

    /// Unlike `startScan`, the target isn't inferred from the requester's
    /// own address — NMS supplies it directly (this Mac's own public IP,
    /// per `FWTraceService`), since a reverse trace needs an explicit
    /// destination the way a port scan of "your own exposed ports"
    /// doesn't.
    func startTrace(target: String) async throws -> TraceJob {
        var request = makeRequest(path: "v1/traces", method: "POST")
        request.httpBody = try JSONEncoder().encode(StartTraceRequestBody(target: target))
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        return try Self.decodeStartTraceResponse(data)
    }

    func pollTraceJob(id: String) async throws -> TraceJob {
        let request = makeRequest(path: "v1/traces/\(id)", method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        return try Self.decodeTraceStatusResponse(data)
    }

    /// Pure and `static` — directly unit-testable against sample JSON
    /// with no live network call, same discipline
    /// `SaaSStatusService.parseStatuspage`/`parseSlack` already follow for
    /// their own response shapes.
    static func decodeStartScanResponse(_ data: Data) throws -> ScanJob {
        let body = try decoder.decode(StartScanResponseBody.self, from: data)
        return ScanJob(
            id: body.jobID,
            status: body.status,
            pollAfterMs: body.pollAfterMs,
            targetIPv4: body.targets.ipv4,
            targetIPv6: body.targets.ipv6 ?? [],
            startedAt: nil,
            completedAt: nil,
            results: []
        )
    }

    static func decodeJobStatusResponse(_ data: Data) throws -> ScanJob {
        let body = try decoder.decode(JobStatusResponseBody.self, from: data)
        return ScanJob(
            id: body.jobID,
            status: body.status,
            // Only present on the still-running shape; a completed job's
            // response has nothing more to poll for, so 500ms here is
            // never actually used by a well-behaved caller.
            pollAfterMs: body.pollAfterMs ?? 500,
            targetIPv4: nil,
            targetIPv6: [],
            startedAt: body.startedAt,
            completedAt: body.completedAt,
            results: (body.results ?? []).map { PortResult(address: $0.address, port: $0.port, state: $0.state) }
        )
    }

    static func decodeStartTraceResponse(_ data: Data) throws -> TraceJob {
        let body = try decoder.decode(StartTraceResponseBody.self, from: data)
        return TraceJob(id: body.jobID, status: body.status, pollAfterMs: body.pollAfterMs, hops: [])
    }

    static func decodeTraceStatusResponse(_ data: Data) throws -> TraceJob {
        let body = try decoder.decode(TraceStatusResponseBody.self, from: data)
        return TraceJob(
            id: body.jobID,
            status: body.status,
            pollAfterMs: body.pollAfterMs ?? 500,
            hops: (body.hops ?? []).map { TraceHop(address: $0.address, hostname: $0.hostname, rttMs: $0.rttMs) }
        )
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same reasoning as SaaSStatusService: a stale cached response
        // here would report exposure that's already changed.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // A connect-scan across up to 128 ports can genuinely take a few
        // seconds server-side even before this Mac starts polling — but
        // this request itself, starting or polling a job, is a small
        // JSON round-trip and shouldn't need more than an ordinary WAN
        // fetch's worth of patience.
        request.timeoutInterval = 10
        return request
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw FWClientError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = try? decoder.decode(ErrorBody.self, from: data).error
            throw FWClientError.server(status: http.statusCode, message: message)
        }
    }

    /// Go's `time.Time` JSON marshaling emits RFC3339 with fractional
    /// seconds and a numeric zone offset (not always `Z`) — plain
    /// `.iso8601` rejects the fractional-seconds form outright, so this
    /// tries the fractional-seconds formatter first and falls back to
    /// the plain one rather than failing the whole decode over a
    /// sub-second timestamp difference.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { fieldDecoder in
            let container = try fieldDecoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFractional.date(from: string) ?? plain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date format: \(string)")
        }
        return decoder
    }()
}

/// Wire-format structs, private to this file — kept separate from
/// `FWClient.PortResult`/`ScanJob` above so the JSON shape (snake_case,
/// `protocol` as a field name Swift reserves) never leaks into the
/// public API the rest of the app actually uses.
private struct StartScanRequestBody: Encodable {
    let ports: [Int]
    let protocolName: String

    enum CodingKeys: String, CodingKey {
        case ports
        case protocolName = "protocol"
    }
}

private struct TargetsBody: Decodable {
    let ipv4: String?
    let ipv6: [String]?
}

private struct StartScanResponseBody: Decodable {
    let jobID: String
    let status: String
    let targets: TargetsBody
    let pollAfterMs: Int

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status, targets
        case pollAfterMs = "poll_after_ms"
    }
}

private struct PortResultBody: Decodable {
    let address: String
    let port: Int
    let state: String
}

private struct JobStatusResponseBody: Decodable {
    let jobID: String
    let status: String
    let pollAfterMs: Int?
    let startedAt: Date?
    let completedAt: Date?
    let results: [PortResultBody]?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case pollAfterMs = "poll_after_ms"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case results
    }
}

private struct ErrorBody: Decodable {
    let error: String
}

private struct StartTraceRequestBody: Encodable {
    let target: String
}

private struct StartTraceResponseBody: Decodable {
    let jobID: String
    let status: String
    let pollAfterMs: Int

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case pollAfterMs = "poll_after_ms"
    }
}

private struct TraceHopBody: Decodable {
    let address: String?
    let hostname: String?
    let rttMs: Double?

    enum CodingKeys: String, CodingKey {
        case address, hostname
        case rttMs = "rtt_ms"
    }
}

private struct TraceStatusResponseBody: Decodable {
    let jobID: String
    let status: String
    let pollAfterMs: Int?
    let startedAt: Date?
    let completedAt: Date?
    let hops: [TraceHopBody]?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case pollAfterMs = "poll_after_ms"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case hops
    }
}
