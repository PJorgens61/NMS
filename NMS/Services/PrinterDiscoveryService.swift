import Foundation

/// Discovers network printers macOS already has configured (System
/// Settings → Printers & Scanners), via `lpstat -v` — a purely local read
/// of CUPS's own configuration, no network I/O itself. Chosen over an
/// SNMP subnet sweep or Bonjour/mDNS browsing for the same reason DHCP
/// lease *reading* was chosen over forcing a fresh negotiation: this is
/// the user's own already-expressed intent ("these are the printers I
/// use"), not an inference from scanning the network — and it finds a
/// printer regardless of whether it speaks SNMP at all, unlike the
/// sweep-based discovery `SNMPViewModel` already does.
struct PrinterDiscoveryService {
    private static let executablePath = "/usr/bin/lpstat"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    struct ConfiguredPrinter: Equatable {
        let name: String
        /// Already resolved to something `ping` can use directly — see
        /// `resolvedHost(from:)` for why this isn't always just the raw
        /// value `lpstat` reported.
        let host: String
    }

    /// Only URI schemes confirmed to carry a directly pingable host.
    /// Deliberately an allow-list, not a block-list excluding just `usb`:
    /// `dnssd://` URIs report an mDNS *service instance name*
    /// (`Brother%20HL-L2395DW._ipp._tcp.local.`), not reliably a bare
    /// resolvable host, and there's no bundled macOS tool for resolving
    /// one short of hand-rolling mDNS-SD — same reasoning as
    /// `SubnetCalculator` treating "can't tell" as "don't act," rather
    /// than guessing. A printer CUPS only knows about via `dnssd://`
    /// simply isn't monitored yet, rather than monitored incorrectly.
    private static let pingableSchemes: Set<String> = ["ipp", "ipps", "socket", "lpd", "http", "https"]

    /// Empty covers "`lpstat` isn't available" and "no printers
    /// configured" alike — neither is a failure worth alarming about.
    func configuredNetworkPrinters() -> [ConfiguredPrinter] {
        guard Self.isAvailable else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = ["-v"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let trace = SubprocessTracer.begin(process.executableURL!.path, process.arguments ?? [])
        do {
            try process.run()
        } catch {
            SubprocessTracer.end(trace, exitCode: nil, byteCount: 0)
            return []
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: data.count)
        guard process.terminationStatus == 0 else { return [] }

        return Self.parse(String(data: data, encoding: .utf8) ?? "")
    }

    /// Parses `lpstat -v`'s one-line-per-printer output: `device for
    /// <name>: <uri>`. Verified against real output rather than assumed —
    /// this Mac's own configured printer reported `device for
    /// brotherlaserprinter: ipp://brotherlaserprinter/ipp/port1`.
    static func parse(_ output: String) -> [ConfiguredPrinter] {
        var printers: [ConfiguredPrinter] = []
        let prefix = "device for "
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix(prefix), let colonRange = line.range(of: ": ") else { continue }

            let name = line[line.index(line.startIndex, offsetBy: prefix.count)..<colonRange.lowerBound]
            let uriString = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard
                let url = URL(string: uriString),
                let scheme = url.scheme, pingableSchemes.contains(scheme),
                let rawHost = url.host, !rawHost.isEmpty
            else { continue }

            printers.append(ConfiguredPrinter(name: String(name), host: Self.resolvedHost(from: rawHost)))
        }
        return printers
    }

    /// `lpstat -v` can report a bare mDNS short name with no `.local`
    /// suffix — confirmed directly: this Mac's own printer reported plain
    /// `brotherlaserprinter`, which fails to resolve at all as reported
    /// (`ping brotherlaserprinter` returns "No route to host" immediately,
    /// no address even attempted), while `ping brotherlaserprinter.local`
    /// resolves correctly to the real address via macOS's built-in mDNS
    /// responder. A real IPv4 address needs no help; anything else gets
    /// `.local` appended unless it already has one.
    private static func resolvedHost(from rawHost: String) -> String {
        guard SubnetCalculator.packedIPv4(rawHost) == nil, !rawHost.hasSuffix(".local") else {
            return rawHost
        }
        return "\(rawHost).local"
    }
}
