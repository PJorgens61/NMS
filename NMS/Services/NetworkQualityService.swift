import Foundation

/// Measures throughput via Cloudflare's public speed-test backend (the
/// same one behind speed.cloudflare.com) — plain HTTPS GET/POST, no
/// account, no hosting, no subprocess dependency. Chosen over Apple's
/// bundled `networkQuality` CLI for the throughput half of "network
/// quality" (see DESIGN-NOTES.md's "Network Quality" section for the full
/// comparison) — this app deliberately doesn't attempt the RPM/
/// bufferbloat signal `networkQuality`'s sequential mode provides, which
/// only that tool can measure.
///
/// Verified directly against the real endpoint before choosing a payload
/// size: a 1MB download measured ~104 Mbps, a 25MB download ~725 Mbps, on
/// the same network at the same moment — a transfer that small finishes
/// before TCP slow-start ramps up, so it mostly measures TLS handshake
/// overhead, not sustained capacity. 25MB is the minimum that produced a
/// believable number on that connection.
///
/// **That's the wrong number to use unconditionally, though.** Reported
/// directly from a slow DSL line: the full 25MB transfer either took
/// unreasonably long or ran past the timeout outright, for a fixed cost
/// that only gets worse the slower the link is — the exact opposite of
/// where a large payload is needed. A slow connection doesn't have TCP
/// slow-start's overhead problem in the first place: at a few Mbps, even
/// a couple of megabytes takes long enough that the transfer is already
/// dominated by real sustained throughput, not handshake noise. So each
/// direction is measured with a small probe first, and only escalates to
/// the full 25MB if the probe suggests a fast-enough link that the small
/// transfer would otherwise understate it — cheap and fast on a slow
/// connection, accurate on a fast one, without needing to know which one
/// this is in advance.
struct NetworkQualityService {
    private static let probeBytes = 2_000_000
    private static let fullBytes = 25_000_000
    /// If the probe alone takes at least this long, the link is slow
    /// enough that the probe's own reading is already believable —
    /// escalating to the full transfer would only cost more time and data
    /// for a number that wouldn't meaningfully change.
    private static let slowLinkThreshold: TimeInterval = 2.0
    /// The probe only ever moves `probeBytes` (2MB) — a genuinely dead
    /// link should fail fast here, not share the full transfer's 45s
    /// budget meant for a large payload over a slow-but-alive connection.
    /// See BUGS.md's "Speed Test times out... with no telemetry to say
    /// why": previously both stages shared one 45s timeout, so a probe
    /// that could never succeed still made the user wait the full 45s
    /// before finding out.
    private static let probeTimeout: TimeInterval = 10
    /// Matches `session`'s own configured default below — set explicitly
    /// per-request now that the probe stage uses a shorter one, so it's
    /// clear this is a deliberate choice for the full transfer, not just
    /// whatever the session happens to default to.
    private static let fullTransferTimeout: TimeInterval = 45

    private static func downloadURL(bytes: Int) -> URL {
        URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)")!
    }
    private static let uploadURL = URL(string: "https://speed.cloudflare.com/__up")!

    enum QualityError: Error {
        case invalidResponse
    }

    /// `.ephemeral`, not `.shared` — both endpoints are hit with the exact
    /// same URL every run, and a cached response would make a repeat run
    /// return instantly instead of performing a real transfer, silently
    /// corrupting the measurement.
    ///
    /// **Two different timeouts, both needed.** `timeoutIntervalForRequest`
    /// is an *idle-gap* timeout — it only fires if the connection goes
    /// fully silent (zero bytes) for that long, and resets on every byte
    /// received. On a genuinely slow but alive link (a trickling
    /// low-bandwidth connection, say), 25MB could take far longer than 45s
    /// while never triggering it at all, since data never stops arriving.
    /// `timeoutIntervalForResource` is the one that caps *total* wall-clock
    /// time regardless of trickle — without it explicitly set, it silently
    /// defaults to Apple's own default of 7 days, which is not a safety cap
    /// in any meaningful sense. Both default to 45s here, mirroring
    /// `networkQuality`'s own `-M 45`.
    ///
    /// `downloadOnce`/`uploadOnce` override the idle-gap half per-request
    /// (`URLRequest.timeoutInterval`) down to `probeTimeout` for the probe
    /// stage specifically — a fully dead link now fails fast during the
    /// small 2MB probe instead of waiting out the full 45s meant for a
    /// large payload over a slow-but-alive connection. This session's
    /// 45s `timeoutIntervalForResource` still applies underneath as the
    /// absolute wall-clock cap either way; it's just never what actually
    /// fires for a stalled probe, since the shorter idle timeout gets
    /// there first.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// No `-I <interface>` equivalent — `URLSession` doesn't offer direct
    /// interface binding the way the CLI flag does, so on a genuinely
    /// multi-homed Mac this measures whatever interface the OS's default
    /// route currently picks, not necessarily the one NMS is tracking.
    /// Accepted limitation — see DESIGN-NOTES.md's open questions.
    /// Returns the actual byte count moved alongside the Mbps figure —
    /// `Self.probeBytes` if the probe alone was believable, `Self.fullBytes`
    /// if it escalated — raised directly so NMS can tell a user exactly
    /// how much data a run just used, not just "up to ~50MB per run."
    func measureDownload() async throws -> (mbps: Double, bytes: Int) {
        let probe = try await downloadOnce(bytes: Self.probeBytes, timeout: Self.probeTimeout)
        guard probe.elapsed < Self.slowLinkThreshold else { return (probe.mbps, Self.probeBytes) }
        let full = try await downloadOnce(bytes: Self.fullBytes, timeout: Self.fullTransferTimeout)
        return (full.mbps, Self.fullBytes)
    }

    func measureUpload() async throws -> (mbps: Double, bytes: Int) {
        let probe = try await uploadOnce(bytes: Self.probeBytes, timeout: Self.probeTimeout)
        guard probe.elapsed < Self.slowLinkThreshold else { return (probe.mbps, Self.probeBytes) }
        let full = try await uploadOnce(bytes: Self.fullBytes, timeout: Self.fullTransferTimeout)
        return (full.mbps, Self.fullBytes)
    }

    private func downloadOnce(bytes: Int, timeout: TimeInterval) async throws -> (mbps: Double, elapsed: TimeInterval) {
        var request = URLRequest(url: Self.downloadURL(bytes: bytes))
        request.timeoutInterval = timeout
        let start = Date()
        let (_, response) = try await Self.session.data(for: request)
        let elapsed = Date().timeIntervalSince(start)
        try Self.validate(response)
        return (Self.mbps(bytes: bytes, elapsed: elapsed), elapsed)
    }

    private func uploadOnce(bytes: Int, timeout: TimeInterval) async throws -> (mbps: Double, elapsed: TimeInterval) {
        var request = URLRequest(url: Self.uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        // All-zero, not random: this is a request body, never subject to
        // response compression, so there's no risk of it round-tripping
        // faster than its real size implies — and generating random bytes
        // would cost real, pointless CPU time on every run for no
        // measurement benefit.
        let body = Data(count: bytes)
        let start = Date()
        let (_, response) = try await Self.session.upload(for: request, from: body)
        let elapsed = Date().timeIntervalSince(start)
        try Self.validate(response)
        return (Self.mbps(bytes: bytes, elapsed: elapsed), elapsed)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw QualityError.invalidResponse
        }
    }

    private static func mbps(bytes: Int, elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        return Double(bytes) * 8 / elapsed / 1_000_000
    }
}
