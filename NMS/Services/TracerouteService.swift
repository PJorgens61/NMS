import Foundation

/// Walks the path to a target host via `/usr/sbin/traceroute` (setuid root
/// on macOS, so this works without any special entitlements — same as
/// `arp`/`ping` elsewhere in this app). Uses a single probe per hop
/// (`-q 1`) specifically to keep output at one line per hop — the default
/// 3-probes-per-hop mode can print multiple differing hosts per hop under
/// ECMP load balancing, spanning multiple lines, which isn't worth parsing
/// for what this app needs (identifying the path and the ISP edge router).
///
/// `-n` (no reverse DNS) and a tight 1s per-hop timeout, capped at 4 hops.
/// Measured directly on a real path (14 hops to reach the target): reverse
/// DNS itself wasn't the bottleneck (14.1s with it vs. 14.1s with `-n`
/// alone) — unresponsive/filtered hops each waiting out the full 2s probe
/// timeout dominated. `-n` plus a 1s timeout with the full hop range
/// intact measured 7.1s (2x); adding the 4-hop cap measured 1.06s (13x),
/// since it stops well before reaching most of those unresponsive hops.
/// The 4-hop cap is a deliberate accuracy tradeoff, not just a speed
/// knob: on a campus/enterprise network where the ISP edge sits deeper
/// than hop 4 (multiple internal routers before the real ISP boundary —
/// exactly the topology `suggestedEdgeHop`/manual hop-confirmation exist
/// to handle), that hop can never appear in the list at all, not just
/// harder to find. Chosen anyway, knowingly, for the speed.
struct TracerouteService {
    enum TracerouteError: Error {
        case processFailed(String)
    }

    private static let maxHops = 4
    private static let probeTimeoutSeconds = 1

    func trace(to host: String) throws -> [TracerouteHop] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        process.arguments = ["-m", "\(Self.maxHops)", "-n", "-q", "1", "-w", "\(Self.probeTimeoutSeconds)", host]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw TracerouteError.processFailed(error.localizedDescription)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return Self.parse(output)
    }

    /// Matches a responsive hop. With `-n` now always passed, real output
    /// is always the bare-IP form (` 2  75.101.33.52  1.163 ms`); the
    /// hostname-resolved form (` 1  router (10.0.0.1)  0.642 ms`) is kept
    /// as an alternative in the pattern for robustness, not because
    /// traceroute itself will ever produce it anymore.
    private static let hopRegex = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\s+(?:(\S+)\s+\(([\d.]+)\)|([\d.]+))\s+([\d.]+)\s*ms"#
    )
    /// Matches a timed-out hop, e.g. ` 4  *` (single probe, so a single `*`).
    private static let timeoutRegex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+\*\s*$"#)

    static func parse(_ output: String) -> [TracerouteHop] {
        output.split(separator: "\n").compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> TracerouteHop? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)

        if let match = hopRegex.firstMatch(in: line, range: range) {
            let hopNumber = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let hasHostname = match.range(at: 2).location != NSNotFound
            let hostname = hasHostname ? ns.substring(with: match.range(at: 2)) : nil
            let address = hasHostname ? ns.substring(with: match.range(at: 3)) : ns.substring(with: match.range(at: 4))
            let rtt = Double(ns.substring(with: match.range(at: 5)))
            return TracerouteHop(hopNumber: hopNumber, address: address, hostname: hostname, roundTripMs: rtt)
        }

        if let match = timeoutRegex.firstMatch(in: line, range: range) {
            let hopNumber = Int(ns.substring(with: match.range(at: 1))) ?? 0
            return TracerouteHop(hopNumber: hopNumber, address: nil, hostname: nil, roundTripMs: nil)
        }

        return nil
    }
}
