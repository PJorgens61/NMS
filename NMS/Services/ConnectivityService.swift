import Foundation

/// Checks reachability of a target host by shelling out to `/sbin/ping`
/// (one real ICMP echo request), giving true round-trip latency rather
/// than a TCP connect-time approximation. Not sandbox-safe — if this app
/// is ever distributed via the Mac App Store, swap this for TCP/UDP
/// reachability via the `Network` framework instead (see README).
struct ConnectivityService {
    struct Target {
        let label: String
        let host: String
    }

    func check(_ target: Target) -> ConnectivityCheck {
        let checkedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-t", "2", target.host]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ConnectivityCheck(label: target.label, target: target.host, success: false, latencyMs: nil, checkedAt: checkedAt)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        let latencyMs = Self.parseLatency(output)

        return ConnectivityCheck(
            label: target.label,
            target: target.host,
            success: process.terminationStatus == 0 && latencyMs != nil,
            latencyMs: latencyMs,
            checkedAt: checkedAt
        )
    }

    func check(targets: [Target]) -> [ConnectivityCheck] {
        targets.map(check)
    }

    private static let latencyRegex = try! NSRegularExpression(pattern: #"time=([0-9.]+) ms"#)

    private static func parseLatency(_ output: String) -> Double? {
        let ns = output as NSString
        guard let match = latencyRegex.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Double(ns.substring(with: match.range(at: 1)))
    }
}
