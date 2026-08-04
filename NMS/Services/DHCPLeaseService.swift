import Foundation

/// Reads the last successful DHCP lease `configd` has cached for an
/// interface, via `ipconfig getpacket <interface>` — a purely local read
/// (no network I/O), unlike forcing a fresh negotiation (`ipconfig set
/// <if> DHCP`), which is disruptive and can drop the live connection. See
/// DESIGN-NOTES.md's "DHCP lease tracking" for why this approach was
/// chosen over that and over hand-rolling DHCPINFORM (no bundled macOS
/// tool for it).
struct DHCPLeaseService {
    private static let executablePath = "/usr/sbin/ipconfig"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// `nil` covers every "not applicable" case alike: a statically
    /// configured interface, one with no lease at all, or one that doesn't
    /// exist (confirmed directly: `ipconfig getpacket` exits 1 with stdout
    /// empty and the reason on stderr in all three cases) — none of them
    /// is a DHCP *failure* worth alarming about, so callers don't need to
    /// tell them apart either.
    func currentLease(interface: String) -> DHCPLeaseInfo? {
        guard Self.isAvailable else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = ["getpacket", interface]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let trace = SubprocessTracer.begin(process.executableURL!.path, process.arguments ?? [])
        do {
            try process.run()
        } catch {
            SubprocessTracer.end(trace, exitCode: nil, byteCount: 0)
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: data.count)
        guard process.terminationStatus == 0 else { return nil }

        return Self.parse(String(data: data, encoding: .utf8) ?? "", interface: interface, checkedAt: Date())
    }

    /// Parses `ipconfig getpacket`'s two-section text dump: a flat
    /// `key = value` header (where `xid` and the granted address, `yiaddr`,
    /// live) followed by an `key (type): value` options list. Verified
    /// against real output rather than assumed from documentation — e.g.
    /// `lease_time (uint32): 0x15180`, a raw hex `uint32`, not the
    /// human-readable "86400s (24h)" form some descriptions imply.
    static func parse(_ output: String, interface: String, checkedAt: Date) -> DHCPLeaseInfo? {
        var xid: String?
        var yiaddr: String?
        var chaddr: String?
        var options: [String: String] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("xid = ") {
                xid = String(trimmed.dropFirst("xid = ".count))
            } else if trimmed.hasPrefix("yiaddr = ") {
                yiaddr = String(trimmed.dropFirst("yiaddr = ".count))
            } else if trimmed.hasPrefix("chaddr = ") {
                chaddr = String(trimmed.dropFirst("chaddr = ".count))
            } else if let parenStart = trimmed.firstIndex(of: "("), let colonEnd = trimmed.range(of: "): ") {
                let key = String(trimmed[..<parenStart]).trimmingCharacters(in: .whitespaces)
                // Capped here, at the parsing boundary, so every option
                // value is bounded uniformly — not just `domain_name`, the
                // one currently read downstream, but any option added
                // later too. See `UntrustedText`.
                options[key] = UntrustedText.capped(String(trimmed[colonEnd.upperBound...]))
            }
        }

        // `dhcp_message_type` present is the signal this is a real DHCP
        // lease at all — absent for a statically configured or down
        // interface, which is "not applicable," not a failure.
        guard
            let xid, let yiaddr,
            options["dhcp_message_type"] != nil,
            let serverIdentifier = options["server_identifier"],
            let leaseSeconds = hexUInt(options["lease_time"]),
            let t1Seconds = hexUInt(options["renewal_t1_time_value"]),
            let t2Seconds = hexUInt(options["rebinding_t2_time_value"])
        else {
            return nil
        }

        return DHCPLeaseInfo(
            interfaceName: interface,
            serverIdentifier: serverIdentifier,
            assignedAddress: yiaddr,
            subnetMask: options["subnet_mask"],
            broadcastAddress: options["broadcast_address"],
            router: ipList(options["router"])?.first,
            dnsServers: ipList(options["domain_name_server"]) ?? [],
            domainName: options["domain_name"],
            leaseSeconds: leaseSeconds,
            t1Seconds: t1Seconds,
            t2Seconds: t2Seconds,
            transactionID: xid,
            clientHardwareAddress: chaddr,
            checkedAt: checkedAt
        )
    }

    /// Forces a fresh DHCP negotiation on `interface`, the same mechanism
    /// System Settings' own "Renew DHCP Lease" button uses (confirmed by
    /// testing live: two calls a few minutes apart on this Mac only
    /// triggered one macOS administrator-authorization prompt, and the
    /// resulting lease's `xid` changed, confirming a real renewal rather
    /// than a no-op).
    ///
    /// **Disruptive, unlike `currentLease` above** — this briefly tears
    /// down and re-establishes the interface's network configuration, and
    /// (for anything but a fully local admin session) surfaces macOS's own
    /// system authorization dialog. Callers must get explicit user
    /// confirmation first; this makes no attempt to gate that itself. See
    /// `PUNCHLIST.md`'s DHCP renew entry for the full research trail —
    /// `ipconfig set <if> DHCP` was the first candidate and was rejected:
    /// it flatly requires `sudo`/root, with no equivalent to the caching
    /// behavior confirmed here.
    ///
    /// Returns whether the `scutil` process itself exited cleanly — not
    /// proof the renewal succeeded (a denied authorization prompt or a
    /// server that's since gone away both still exit 0, since `scutil`
    /// only *requests* the re-evaluation). Callers should re-check the
    /// lease afterward (a fresh `xid`) to confirm it actually changed.
    func renew(interface: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--renew", interface]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let trace = SubprocessTracer.begin(process.executableURL!.path, process.arguments ?? [])
        do {
            try process.run()
        } catch {
            SubprocessTracer.end(trace, exitCode: nil, byteCount: 0)
            return false
        }
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: 0)
        return process.terminationStatus == 0
    }

    private static func hexUInt(_ value: String?) -> Int? {
        guard let value, value.hasPrefix("0x") else { return nil }
        return Int(value.dropFirst(2), radix: 16)
    }

    /// `ip_mult` values print as `{10.0.0.1}` or `{10.0.0.1, 10.0.0.2}`.
    private static func ipList(_ value: String?) -> [String]? {
        guard let value, value.hasPrefix("{"), value.hasSuffix("}") else { return nil }
        let items = value.dropFirst().dropLast()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return items.isEmpty ? nil : items
    }
}
