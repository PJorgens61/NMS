import Foundation

/// Queries SNMP devices by shelling out to `/usr/bin/snmpget` — macOS
/// bundles net-snmp, so this needs no third-party dependency and no
/// hand-rolled ASN.1/UDP, the same free ride this app already takes with
/// `ping`/`arp`/`traceroute`.
///
/// Two things learned by measuring the real tool before writing this:
/// - **The default timeout is ~6s per unresponsive host** (1s × 5 retries),
///   which across a 254-host sweep would be unusable. `-t 1 -r 1` brings it
///   to ~2s. This app has already been bitten three separate times by
///   unbounded timeouts (DNS, HTTP, sequential pings), so the flags are not
///   optional.
/// - **`-Oqvt` is the parse-friendly output**: values only, no OID prefix,
///   no type prefix, and TimeTicks as a raw integer instead of
///   "33 days, 5:52:37.22" — verified against a real device. Values come
///   back one per line in the order the OIDs were requested; on failure
///   stdout is empty, the error goes to stderr, and the exit code is 1.
///
/// Caveat worth knowing: the bundled net-snmp is 5.6.2.1 (~2011) and Apple
/// hasn't updated it in over a decade — it's been deprecation-listed for a
/// while. `isAvailable` exists so the feature can degrade to "no SNMP"
/// rather than silently break if a future macOS drops it.
struct SNMPService {
    private static let executablePath = "/usr/bin/snmpget"

    /// The three OIDs this app cares about, requested in one GET.
    /// - `1.3.6.1.2.1.1.1.0` — sysDescr (model + software version)
    /// - `1.3.6.1.2.1.1.5.0` — sysName (configured hostname)
    /// - `1.3.6.1.2.1.1.3.0` — sysUpTime (restart detection)
    private static let oids = [
        "1.3.6.1.2.1.1.1.0",
        "1.3.6.1.2.1.1.5.0",
        "1.3.6.1.2.1.1.3.0"
    ]

    /// How many probes run at once during a sweep. Each probe is a forked
    /// `snmpget` process, so this is a deliberate ceiling on process count,
    /// not on network traffic — every concurrent probe targets a
    /// *different* address, so raising this doesn't risk hammering any
    /// single device, only running more `snmpget`s at once. At 64, a
    /// 254-host /24 takes roughly 4 waves × ~2s ≈ 8s worst case (nearly
    /// all hosts silent) — times the number of community strings
    /// configured, since a silent host has to time out on each one before
    /// it can be ruled out. The now-1024-host `SubnetCalculator
    /// .maxSweepHosts` ceiling (a real /22) is ~32s worst case at 64,
    /// down from ~64s at the previous 32 — real measured response times
    /// on this Mac's own network (~130-155ms per answering device, see
    /// `ui-state.log`) leave plenty of headroom below that.
    static let sweepConcurrency = 64

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// Tries each community in order, returning on the first that answers.
    /// Order matters: put the one most of your gear uses first, since every
    /// string ahead of the right one costs a full ~2s timeout on a silent
    /// host and typically leaves an `authenticationFailure` entry in the
    /// logs of a device that *is* listening but rejects it.
    func probe(ipAddress: String, communities: [String]) -> SNMPDevice? {
        for community in communities {
            if let device = probe(ipAddress: ipAddress, community: community) {
                return device
            }
        }
        return nil
    }

    /// Returns `nil` for anything that isn't a clean, complete SNMP answer —
    /// no response, a non-zero exit, or fewer values than OIDs requested.
    /// A device that doesn't speak SNMP is the overwhelmingly common case
    /// here (most addresses in a sweep), not an error worth surfacing.
    func probe(ipAddress: String, community: String) -> SNMPDevice? {
        guard Self.isAvailable else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = ["-v2c", "-c", community, "-t", "1", "-r", "1", "-Oqvt", ipAddress] + Self.oids

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

        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3, let uptimeTicks = Int(lines[2]) else { return nil }

        let sysDescr = Self.unquoted(lines[0])
        guard !sysDescr.isEmpty else { return nil }
        let sysName = Self.unquoted(lines[1])

        return SNMPDevice(
            ipAddress: ipAddress,
            sysDescr: sysDescr,
            sysName: sysName.isEmpty ? nil : sysName,
            uptimeTicks: uptimeTicks,
            community: community,
            polledAt: Date()
        )
    }

    /// One address and the community strings to try for it. Discovery
    /// passes every configured string; a re-poll of an already-known device
    /// passes just the one it answered on last time.
    struct SweepTarget {
        let ipAddress: String
        let communities: [String]
    }

    /// Probes every target concurrently (bounded by `sweepConcurrency`) and
    /// returns only the responders, sorted by address. Blocking — call it
    /// off the main thread.
    func sweep(targets: [SweepTarget]) -> [SNMPDevice] {
        guard Self.isAvailable, !targets.isEmpty else { return [] }

        var found: [SNMPDevice] = []
        let lock = NSLock()
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: Self.sweepConcurrency)
        let queue = DispatchQueue.global(qos: .utility)

        for target in targets {
            slots.wait()
            group.enter()
            queue.async {
                defer {
                    slots.signal()
                    group.leave()
                }
                guard let device = self.probe(ipAddress: target.ipAddress, communities: target.communities) else { return }
                lock.lock()
                found.append(device)
                lock.unlock()
            }
        }
        group.wait()

        return found.sorted {
            (SubnetCalculator.packedIPv4($0.ipAddress) ?? 0) < (SubnetCalculator.packedIPv4($1.ipAddress) ?? 0)
        }
    }

    /// net-snmp renders string values with surrounding quotes in some
    /// configurations even under `-Oq`; strip them so a quoted and an
    /// unquoted `sysDescr` don't look like a software change to the
    /// change detection in `SNMPViewModel`.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
