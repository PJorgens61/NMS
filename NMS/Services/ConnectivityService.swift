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

    /// Runs all targets' pings concurrently, not sequentially — with up to
    /// 5 targets (router, 2 LAN devices, internet, ISP edge router) each
    /// capable of blocking for the full 2s timeout during a real outage,
    /// running them one after another could add up to 10s just for pings,
    /// on top of whatever DNS/HTTP then add after. Concurrently, the whole
    /// batch is bounded by the single slowest ping (~2s), not their sum.
    func check(targets: [Target]) -> [ConnectivityCheck] {
        guard !targets.isEmpty else { return [] }
        var results = [ConnectivityCheck?](repeating: nil, count: targets.count)
        let lock = NSLock()
        let group = DispatchGroup()
        for (index, target) in targets.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let result = self.check(target)
                lock.lock()
                results[index] = result
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return results.compactMap { $0 }
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
