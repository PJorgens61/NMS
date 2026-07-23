import Foundation

/// Enumerates devices on the local subnet by reading the kernel's ARP cache
/// via `arp -a`. This surfaces hosts the machine has already exchanged
/// traffic with (router, active peers) rather than actively probing the
/// subnet — no special entitlements needed, and it's near-instant.
struct LANDiscoveryService {
    enum DiscoveryError: Error {
        case processFailed(String)
    }

    func scan() throws -> [DiscoveredDevice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-a"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw DiscoveryError.processFailed(error.localizedDescription)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return Self.parse(output)
    }

    /// Same physical device commonly shows up once per local interface
    /// (e.g. `en0` and `en1` on a Mac with both Wi-Fi and Ethernet up), so
    /// results are de-duplicated by IP, keeping the first sighting.
    static func parse(_ output: String) -> [DiscoveredDevice] {
        let now = Date()
        let all = output.split(separator: "\n").compactMap { parseLine(String($0), discoveredAt: now) }
        var seenIPs = Set<String>()
        return all.filter { seenIPs.insert($0.ipAddress).inserted }
    }

    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^(\S+) \(([0-9]{1,3}(?:\.[0-9]{1,3}){3})\) at (\S+) on (\S+)"#
    )

    /// Parses a line like:
    /// `router.local (10.0.0.1) at bc:b9:23:81:a6:d4 on en0 ifscope [ethernet]`
    /// Entries without a resolved MAC (`(incomplete)`) and multicast
    /// addresses (the `224.0.0.251` mDNS entry that's always present) are
    /// skipped — neither is an actual device on the LAN.
    private static func parseLine(_ line: String, discoveredAt: Date) -> DiscoveredDevice? {
        let nsLine = line as NSString
        guard let match = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }

        let hostnameToken = nsLine.substring(with: match.range(at: 1))
        let ip = nsLine.substring(with: match.range(at: 2))
        let mac = nsLine.substring(with: match.range(at: 3))
        let interfaceName = nsLine.substring(with: match.range(at: 4))

        guard mac != "(incomplete)", !isMulticast(ip) else { return nil }

        return DiscoveredDevice(
            ipAddress: ip,
            macAddress: mac,
            hostname: hostnameToken == "?" ? nil : hostnameToken,
            interfaceName: interfaceName,
            discoveredAt: discoveredAt
        )
    }

    private static func isMulticast(_ ip: String) -> Bool {
        guard let firstOctet = ip.split(separator: ".").first.flatMap({ Int($0) }) else { return false }
        return (224...239).contains(firstOctet)
    }
}
