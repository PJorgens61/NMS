import Foundation

/// Best-effort reverse DNS (PTR) lookup for a single IPv4 address — used to
/// enrich traceroute hops with a hostname *after* the fact, kept entirely
/// separate from the trace itself. `TracerouteService` now always runs with
/// `-n` specifically so a slow or absent PTR record can never make tracing
/// itself slower; this service exists to claw the hostname back afterward,
/// on its own time, without that risk.
///
/// Bounded with an explicit timeout for the same reason
/// `DNSResolutionService.probe()` is: `getnameinfo` is a blocking POSIX
/// call with no timeout parameter of its own, and this app has already
/// been bitten once by trusting an OS resolver call to fail fast on its
/// own (the DNS-check bug where `getaddrinfo` blocked for ~30s during a
/// real outage). A hung reverse lookup here should just mean "no hostname
/// this time," never a stuck enrichment task.
struct ReverseDNSService {
    private static let timeout: TimeInterval = 2

    /// Returns `nil` for anything short of a genuine PTR record — no
    /// record, a malformed address, or timing out — never throws, since
    /// this is enrichment, not a health check with a failure state worth
    /// reporting.
    func hostname(for ipAddress: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        DispatchQueue.global(qos: .utility).async {
            result = Self.lookup(ipAddress)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + Self.timeout) == .success else { return nil }
        return result
    }

    private static func lookup(_ ipAddress: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, ipAddress, &addr.sin_addr) == 1 else { return nil }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        // Captured before `withUnsafePointer` below, not read from `addr`
        // inside the closure — Swift's exclusivity checking flags reading
        // another property of the same variable a pointer is currently
        // exclusively bound to.
        let addrLen = socklen_t(addr.sin_len)
        // NI_NAMEREQD: fail outright when there's no PTR record, rather
        // than silently "succeeding" with the numeric address handed back
        // as if it were a real hostname.
        let status = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getnameinfo(sockaddrPtr, addrLen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        return String(cString: hostBuffer)
    }
}
