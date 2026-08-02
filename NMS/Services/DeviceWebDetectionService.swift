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

    private let lenientSession = URLSession(configuration: .ephemeral, delegate: TrustAllCertificatesDelegate(), delegateQueue: nil)
    /// Standard, unmodified certificate validation — no delegate override,
    /// so this accepts exactly what a real browser would accept without a
    /// warning. Checked *first*, ahead of the lenient session below, so a
    /// device with a genuinely valid, modern cert gets an encrypted link
    /// automatically rather than never being offered the chance.
    private let strictSession = URLSession(configuration: .ephemeral)

    /// One candidate to probe: which URL, and which trust policy to probe
    /// it with.
    private struct Candidate {
        let url: String
        let session: URLSession
    }

    /// Tries, in order: HTTPS with real certificate validation, then
    /// plain HTTP, then HTTPS again but trusting any certificate, then
    /// HTTPS on port 4343 (Aruba's own non-standard admin-UI port,
    /// confirmed real on this network's own AP1/AP2 — `sysDescr`
    /// "AOS-8 (MODEL: 535)" — see `DESIGN-NOTES.md`'s "SNMP device
    /// web-detection: vendor-specific admin ports beyond 80/443"). Returns
    /// the first candidate that answers at all within a short
    /// LAN-appropriate timeout, `nil` if none do. `4343` costs nothing
    /// extra for a device that doesn't use it — the connection attempt
    /// just fails quickly, same as any other unused port.
    ///
    /// **This ordering resolves a real tradeoff, not an arbitrary
    /// preference.** A first version tried plain HTTPS (trust-all) ahead
    /// of HTTP, and that broke on this network's own printer: the
    /// trust-all session "succeeded" against its HTTPS port (some
    /// response came back), but real browsers (Safari, Brave) refused or
    /// warned on that same connection — plausibly outdated TLS the
    /// trust-all check couldn't see, only that *something* answered. The
    /// fix isn't picking a different fixed winner (HTTP always first has
    /// the opposite problem: a device with a perfectly valid modern cert
    /// would never get offered its own encrypted link) — it's actually
    /// checking. `strictSession` answers the real question ("would a
    /// browser accept this without a warning?") instead of "did anything
    /// answer at all?", so a genuinely trustworthy HTTPS server wins
    /// first, a browser-unfriendly one falls through to HTTP (matching
    /// what was actually observed working on this network's printer),
    /// and only once both of those fail does a self-signed/outdated-TLS
    /// HTTPS server get offered anyway — still better than no link, and
    /// the same "let a failed click-through be the browser's own
    /// fallback" posture the Local Router link already uses. Not specific
    /// to this one printer or household — consumer/prosumer LAN gear
    /// commonly ships with a self-signed cert and a stale TLS stack,
    /// across NMS's whole userbase.
    ///
    /// Any HTTP(S) response counts as "detected," not just a 200 — a 401
    /// or 404 still proves a genuine web server is there, which a bare
    /// TCP connect couldn't distinguish from an arbitrary non-HTTP
    /// service (e.g. SNMP's own port) happening to accept a connection.
    func detectWebURL(forAddress address: String) async -> String? {
        let candidates = [
            Candidate(url: "https://\(address)/", session: strictSession),
            Candidate(url: "http://\(address)/", session: lenientSession),
            Candidate(url: "https://\(address)/", session: lenientSession),
            Candidate(url: "https://\(address):4343/", session: lenientSession)
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate.url) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            if (try? await candidate.session.data(for: request)) != nil {
                return url.absoluteString
            }
        }
        return nil
    }
}
