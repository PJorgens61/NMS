import Foundation

/// Probes an arbitrary LAN IP for a web server — a different, more
/// open-ended question than `HTTPCheckService`'s "does this one known
/// endpoint answer with the expected body." Used to add a link next to a
/// discovered SNMP device (`SNMPViewModel`) when it plausibly has an admin
/// web UI, per `PUNCHLIST.md`'s "SNMP Devices: detect a web server."
struct DeviceWebDetectionService {
    /// Trusts any server certificate unconditionally — used only by this
    /// service's own dedicated `URLSession`, never `URLSession.shared` or
    /// anywhere else in the app. Defensible specifically because these are
    /// LAN devices SNMP already confirmed answer to a configured community
    /// string, not an arbitrary internet host — matching what a user
    /// already does by hand in a browser for exactly this kind of device.
    private final class TrustAllCertificatesDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private let session = URLSession(configuration: .ephemeral, delegate: TrustAllCertificatesDelegate(), delegateQueue: nil)

    /// Tries HTTP first, then HTTPS, then HTTPS on port 4343 — Aruba's own
    /// non-standard admin-UI port, confirmed real on this network's own
    /// AP1/AP2 (`sysDescr` "AOS-8 (MODEL: 535)") — see `DESIGN-NOTES.md`'s
    /// "SNMP device web-detection: vendor-specific admin ports beyond
    /// 80/443" for the finding. Returns the first candidate that answers
    /// at all within a short LAN-appropriate timeout, `nil` if none do.
    /// `4343` costs nothing extra for a device that doesn't use it — the
    /// connection attempt just fails quickly, same as any other unused
    /// port.
    ///
    /// HTTP first, not HTTPS — confirmed live against this network's own
    /// printer: this probe's lenient trust-all `URLSession` "succeeds"
    /// against its HTTPS port (some response comes back), but real
    /// browsers (Safari, Brave) refuse or warn on that same connection —
    /// plausibly outdated TLS this probe doesn't check for, only that
    /// *something* answered, while HTTP works cleanly in both. Not
    /// specific to this one printer or household — consumer/prosumer LAN
    /// gear (routers, APs, printers) commonly ships with a self-signed
    /// cert and an old TLS stack that was never updated, across NMS's
    /// whole userbase, not just this network. A device that only serves
    /// HTTPS still falls through to it correctly (HTTP would simply fail
    /// to connect there); this just stops a technically-answering but
    /// browser-unfriendly HTTPS port from winning the race against a
    /// plain HTTP admin UI that actually works better.
    ///
    /// Any HTTP response counts as "detected," not just a 200 — a 401 or
    /// 404 still proves a genuine web server is there, which a bare TCP
    /// connect couldn't distinguish from an arbitrary non-HTTP service
    /// (e.g. SNMP's own port) happening to accept a connection.
    func detectWebURL(forAddress address: String) async -> String? {
        for candidate in ["http://\(address)/", "https://\(address)/", "https://\(address):4343/"] {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            if (try? await session.data(for: request)) != nil {
                return url.absoluteString
            }
        }
        return nil
    }
}
