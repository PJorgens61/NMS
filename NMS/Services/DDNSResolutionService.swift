import Foundation

/// Resolves a user-configured DDNS hostname by shelling out to
/// `/usr/bin/dig` against an explicit public resolver, not
/// `getaddrinfo` — see `DDNSViewModel` for why this exists at all.
///
/// `DNSResolutionService`'s own anti-caching trick (a freshly randomized
/// subdomain, to defeat the system resolver's negative caching) can't
/// apply here: the hostname being checked is fixed by the user's own
/// DDNS provider, not something this app can vary. A plain `getaddrinfo`
/// call risks reading a *cached* answer from the local resolver rather
/// than the DDNS provider's actual current record — which could report a
/// false "stale" moments after a real, successful update, worse than not
/// checking at all.
///
/// `dig` sidesteps this because it implements its own minimal stub
/// resolver and talks straight to whatever nameserver is given
/// (`@1.1.1.1` here — Cloudflare's public resolver), never going through
/// macOS's system resolver daemon (mDNSResponder) in either direction —
/// exactly the trade-off `DESIGN-NOTES.md`'s "DNS testing: is `dig` an
/// alternative to `getaddrinfo`?" section evaluated and set aside for
/// the *main* connectivity check (for availability reasons — `dig` has
/// been trimmed from macOS across past releases, same concern already
/// flagged for `snmpget` in `SNMPService`), while flagging it as "a
/// legitimate additional check" for precisely this scenario: a specific,
/// known, non-randomizable hostname where bypassing the local cache
/// entirely is the whole point.
nonisolated struct DDNSResolutionService {
    enum ResolutionError: Error {
        case unavailable
        case noAnswer

        /// Human-readable, for direct display (`DDNSViewModel.Status
        /// .lastError`) — reported directly after a real NXDOMAIN showed
        /// up in the UI as the bare case name "noAnswer" instead of an
        /// explanation. Deliberately doesn't distinguish NXDOMAIN from a
        /// malformed/unexpected answer — both mean the same thing to a
        /// user checking this: nothing usable came back for this
        /// hostname right now.
        var displayMessage: String {
            switch self {
            case .unavailable:
                return "dig is not available on this Mac"
            case .noAnswer:
                return "No DNS record found for this hostname"
            }
        }
    }

    private static let executablePath = "/usr/bin/dig"
    private static let resolverAddress = "1.1.1.1"
    private static let timeoutSeconds = 3

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// Returns the resolved IPv4 address, or throws if `dig` can't
    /// produce one (NXDOMAIN, no path to the resolver, a malformed
    /// answer). `+time=3 +tries=1` bounds this to a single ~3s attempt —
    /// the same "no unbounded subprocess timeout" discipline
    /// `SNMPService`/`ConnectivityService` already apply elsewhere.
    func resolve(hostname: String) -> Result<String, ResolutionError> {
        guard Self.isAvailable else { return .failure(.unavailable) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = [
            "@\(Self.resolverAddress)", hostname, "A", "+short",
            "+time=\(Self.timeoutSeconds)", "+tries=1"
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let trace = SubprocessTracer.begin(process.executableURL!.path, process.arguments ?? [])
        do {
            try process.run()
        } catch {
            SubprocessTracer.end(trace, exitCode: nil, byteCount: 0)
            return .failure(.unavailable)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: data.count)

        // `+short` on an `A` query prints one name/address per line,
        // ending in the final IPv4 answer — intermediate lines only
        // appear for a CNAME chain, so the last non-empty line is always
        // the one that matters.
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last, SubnetCalculator.packedIPv4(last) != nil else {
            return .failure(.noAnswer)
        }
        return .success(last)
    }

    /// Resolves every hostname concurrently — same bounded-blocking shape
    /// `SNMPService.sweep(targets:)` uses (`DispatchGroup`/`NSLock` over
    /// `DispatchQueue.global`, not Swift structured concurrency): `resolve`
    /// blocks the calling thread on `Process.waitUntilExit()`, and handing
    /// that to `withTaskGroup` would block a thread out of Swift's
    /// cooperative pool rather than a plain dispatch queue's, the same
    /// starvation risk `DNSResolutionService`'s own doc comment describes
    /// for a different queue. Blocking — call it off the main thread.
    /// Result order matches `hostnames`, not completion order.
    func resolveAll(hostnames: [String]) -> [String: Result<String, ResolutionError>] {
        guard !hostnames.isEmpty else { return [:] }

        var results: [String: Result<String, ResolutionError>] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .utility)

        for hostname in hostnames {
            group.enter()
            queue.async {
                let result = self.resolve(hostname: hostname)
                lock.lock()
                results[hostname] = result
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return results
    }
}
