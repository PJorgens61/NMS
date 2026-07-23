import Foundation

/// Walks the path to a target host via `/usr/sbin/traceroute` (setuid root
/// on macOS, so this works without any special entitlements — same as
/// `arp`/`ping` elsewhere in this app). Uses a single probe per hop
/// (`-q 1`) specifically to keep output at one line per hop — the default
/// 3-probes-per-hop mode can print multiple differing hosts per hop under
/// ECMP load balancing, spanning multiple lines, which isn't worth parsing
/// for what this app needs (identifying the path and the ISP edge router).
struct TracerouteService {
    enum TracerouteError: Error {
        case processFailed(String)
    }

    private static let maxHops = 20
    private static let probeTimeoutSeconds = 2

    func trace(to host: String) throws -> [TracerouteHop] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        process.arguments = ["-m", "\(Self.maxHops)", "-w", "\(Self.probeTimeoutSeconds)", "-q", "1", host]

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

    /// Matches a responsive hop, e.g.:
    /// ` 1  router (10.0.0.1)  0.642 ms` (hostname resolved)
    /// ` 2  75.101.33.52  1.163 ms` (no reverse DNS, bare IP)
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
