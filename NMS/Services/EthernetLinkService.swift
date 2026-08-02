import Foundation

/// Reads the current Ethernet interface's negotiated link speed and
/// duplex via `networksetup -getMedia`, a bundled macOS tool — same
/// free-ride shell-out pattern as `ping`/`arp`/`traceroute`/`ipconfig`/
/// `snmpget` elsewhere in this app. No IOKit call or private API needed.
///
/// Verified against this Mac's own real Ethernet connection before
/// writing the parser below, not assumed from documentation:
/// ```
/// $ networksetup -getMedia en0
/// Current: autoselect
/// Active: 1000baseT <full-duplex flow-control>
/// ```
nonisolated struct EthernetLinkService {
    private static let executablePath = "/usr/sbin/networksetup"

    struct Info {
        /// Negotiated link speed in Mbps — e.g. 1000 for Gigabit
        /// Ethernet, 10000 for 10GbE. `nil` if there's no active link
        /// (cable unplugged) or the media string didn't parse.
        let speedMbps: Double?
        /// "Full Duplex" or "Half Duplex". `nil` if not reported.
        let duplex: String?
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// All-`nil` `Info` covers every "nothing to report" case alike: the
    /// tool missing, the device not existing, or an "Active: none" link
    /// (interface up but no cable — `ifconfig` still lists it) — none is
    /// a failure worth telling apart from the others here.
    func currentInfo(device: String) -> Info {
        guard Self.isAvailable else { return Info(speedMbps: nil, duplex: nil) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = ["-getMedia", device]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let trace = SubprocessTracer.begin(process.executableURL!.path, process.arguments ?? [])
        do {
            try process.run()
        } catch {
            SubprocessTracer.end(trace, exitCode: nil, byteCount: 0)
            return Info(speedMbps: nil, duplex: nil)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: data.count)
        guard process.terminationStatus == 0 else { return Info(speedMbps: nil, duplex: nil) }

        let output = String(data: data, encoding: .utf8) ?? ""
        guard let activeLine = output.split(separator: "\n").first(where: { $0.hasPrefix("Active: ") }) else {
            return Info(speedMbps: nil, duplex: nil)
        }
        return Self.parse(String(activeLine.dropFirst("Active: ".count)))
    }

    /// Parses e.g. `"1000baseT <full-duplex flow-control>"` into speed +
    /// duplex, or `"none"` (no link) into both `nil`.
    static func parse(_ active: String) -> Info {
        guard let baseToken = active.split(separator: " ").first, baseToken != "none" else {
            return Info(speedMbps: nil, duplex: nil)
        }

        var duplex: String?
        if active.contains("full-duplex") {
            duplex = "Full Duplex"
        } else if active.contains("half-duplex") {
            duplex = "Half Duplex"
        }
        return Info(speedMbps: Self.speedMbps(fromMediaToken: String(baseToken)), duplex: duplex)
    }

    /// e.g. `"1000baseT"` -> 1000, `"100baseTX"` -> 100, `"10baseT/UTP"`
    /// -> 10, `"10Gbase-T"` -> 10000 — the `G` suffix on the leading
    /// digits (10GbE's own media-type naming) means "thousands," not
    /// units, so it can't be read with a plain digit prefix alone.
    private static func speedMbps(fromMediaToken token: String) -> Double? {
        var digits = ""
        var index = token.startIndex
        while index < token.endIndex, token[index].isNumber {
            digits.append(token[index])
            index = token.index(after: index)
        }
        guard let value = Double(digits) else { return nil }
        if index < token.endIndex, token[index] == "G" || token[index] == "g" {
            return value * 1000
        }
        return value
    }
}
