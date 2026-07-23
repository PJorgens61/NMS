import Foundation

/// Looks up this Mac's public (WAN-facing) IP address. There's no way to
/// learn this locally — it's whatever address the network's NAT/router
/// presents to the internet — so this asks a third-party echo service.
/// Uses api.ipify.org: a purpose-built, no-auth endpoint whose entire
/// response body is the caller's IP address as plain text. Swappable via
/// `endpoint` if this service ever becomes unavailable or rate-limited.
struct PublicIPService {
    enum LookupError: Error {
        case invalidResponse
    }

    private static let endpoint = URL(string: "https://api.ipify.org?format=text")!

    func fetch() async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: Self.endpoint)
        guard
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !ip.isEmpty
        else {
            throw LookupError.invalidResponse
        }
        return ip
    }
}
