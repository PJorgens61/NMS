import Foundation

/// Tests DNS resolution via the POSIX `getaddrinfo` call — the system
/// resolver, respecting system DNS settings — isolated from any actual
/// network I/O beyond the lookup itself.
///
/// The original approach (resolve a fixed hostname, e.g. "apple.com", and
/// treat success as "reachable") has a real caching blind spot: macOS's
/// system resolver caches successful answers for their record's TTL, so a
/// later call can be served entirely from that cache with zero actual
/// network traffic — confirmed directly to mask a genuine outage (disabling
/// an upstream switch didn't make this check report unreachable, since
/// "apple.com" had already resolved and cached before the outage started).
///
/// Fix: probe a *freshly randomized* subdomain of a real domain every call,
/// and treat the resulting `EAI_NONAME` (a genuine NXDOMAIN-equivalent) as
/// success, not failure. Two things make this work:
/// - A label that's never been queried before can't possibly be served from
///   a prior cache entry — a cache can only serve a hit for an exact name
///   it's already seen — so this forces a real round trip every time.
/// - `.invalid`/`.test`/`.example` (RFC 2606's reserved-for-failure TLDs)
///   won't do for the base domain: verified empirically that macOS's
///   resolver short-circuits those locally in ~1-2ms with no real network
///   round trip at all, which would report "reachable" identically whether
///   the network is actually up or down. A real, ordinary domain's
///   nonexistent random subdomain took ~5ms in the same test — consistent
///   with an actual round trip to real DNS infrastructure, not a local
///   shortcut.
///
/// That randomized-label fix alone still wasn't enough, though: confirmed
/// directly (real upstream-switch-disabled test) that with no path to any
/// DNS server at all, `getaddrinfo` doesn't fail quickly — it blocked for
/// ~30s (retrying across configured resolvers internally) and *still*
/// ultimately returned `EAI_NONAME`, reporting "reachable" with a ~30000ms
/// latency instead of the failure this exists to catch. Whatever produces
/// that (retry/fallback behavior in the system resolver, possibly
/// interacting with DNSSEC-aware negative caching) isn't something this
/// service can rely on `getaddrinfo`'s return code alone to detect — a real
/// answer should come back in well under a second, so `probe(timeout:)`
/// races the call against an explicit short timeout and treats not
/// finishing in time as failure regardless of what `getaddrinfo`
/// eventually would have returned, the same way `ConnectivityService`
/// already bounds `ping` to 2s rather than trusting its own retry logic.
nonisolated struct DNSResolutionService {
    enum ResolutionError: Error {
        case failed(Int32)
        case timedOut
    }

    private static let probeBaseDomain = "apple.com"
    private static let timeout: TimeInterval = 2

    /// Returns normally when the probe resolves to a genuine, unambiguous
    /// "no such name" (`EAI_NONAME`) within `timeout` — the actual success
    /// case, since only a real, prompt round trip to authority produces
    /// that answer. Throws for anything else: a different status code, the
    /// vanishingly unlikely case where the random label actually resolves
    /// to something, or not finishing within `timeout` at all.
    ///
    /// `getaddrinfo` has no native cancellation, so on a timeout the
    /// underlying call is left to finish on its own in the background —
    /// its result is simply discarded when it eventually arrives.
    ///
    /// Run on a dedicated `Thread`, not `DispatchQueue.global`. That call
    /// was measured directly to block ~30s during a real outage (see above)
    /// rather than failing fast, and `DispatchQueue.global`'s worker
    /// threads are drawn from a small, process-wide pool shared with every
    /// other `.utility` queue in the app. An orphaned call parked there
    /// during a real, sustained outage — fired repeatedly at the 5s fast
    /// poll interval — was the best explanation found for a real 17+ minute
    /// gap in `UIStateLogger`'s output with no crash: enough orphaned
    /// lookups accumulated to starve that shared pool, stalling unrelated
    /// queues drawing from it too. A dedicated thread means an orphaned
    /// call blocks only itself.
    func probe() throws {
        let hostname = "nms-check-\(UUID().uuidString.prefix(12).lowercased()).\(Self.probeBaseDomain)"
        let semaphore = DispatchSemaphore(value: 0)
        var capturedStatus: Int32?

        Thread.detachNewThread {
            var hints = addrinfo(
                ai_flags: 0,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: 0,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var resultPointer: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(hostname, nil, &hints, &resultPointer)
            if let resultPointer {
                freeaddrinfo(resultPointer)
            }
            capturedStatus = status
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + Self.timeout) == .success, let status = capturedStatus else {
            throw ResolutionError.timedOut
        }
        guard status == EAI_NONAME else {
            throw ResolutionError.failed(status)
        }
    }
}
