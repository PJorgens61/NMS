import Foundation

/// Checks real HTTP-layer reachability using Apple's own captive-portal
/// probe endpoint — the same one macOS itself uses to detect captive
/// portals, so it's plain HTTP (not HTTPS, deliberately: captive portals
/// intercept port 80 to inject their redirect) and expected to always
/// return a specific, tiny, stable body. This is the layer above IP and
/// DNS: a firewall blocking outbound port 80/443, or a captive portal, can
/// break this while raw IP ping and DNS resolution both still succeed.
struct HTTPCheckService {
    enum HTTPCheckError: Error {
        case unexpectedResponse
    }

    private static let endpoint = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    private static let expectedBodyFragment = "Success"

    func check() async throws -> Void {
        // `URLSession.shared`'s default cache policy can serve this request
        // from `URLCache` without touching the network at all — Apple's
        // probe page doesn't send cache-preventing headers. That made this
        // check report "reachable" (implausibly fast, ~1ms) even with the
        // interface down, since it was replaying a cached response instead
        // of actually testing anything. Forcing the request to ignore the
        // cache makes this a real network round trip every time.
        var request = URLRequest(url: Self.endpoint)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let body = String(data: data, encoding: .utf8),
            body.contains(Self.expectedBodyFragment)
        else {
            throw HTTPCheckError.unexpectedResponse
        }
    }
}
