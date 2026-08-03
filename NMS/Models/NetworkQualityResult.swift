import Foundation

/// One speed-test run's result. Unlike almost everything else this app
/// persists, a run is never deduplicated against the previous one (see
/// DESIGN-NOTES.md's "Why this doesn't fit the existing change-log
/// pattern") — every run is an intentional, standalone data point the
/// user wants to compare against past ones, not a change to detect.
///
/// Two independent measurement methods feed the same result shape and the
/// same history list, distinguished by `source` — see
/// `AppleNetworkQualityService`/`NetworkQualityService`. Neither
/// supersedes the other: Cloudflare's endpoint is quick (~1s here) and
/// throughput-only; Apple's `networkQuality` is slow (~25-30s) but adds
/// RPM/responsiveness under load, a signal nothing else in this app
/// measures.
struct NetworkQualityResult: Equatable, Codable {
    enum Source: String, Codable {
        case cloudflareEndpoint
        case appleNetworkQuality
    }

    let downloadMbps: Double
    let uploadMbps: Double
    /// RPM under load, split by direction — only ever set by
    /// `AppleNetworkQualityService`'s sequential-mode run. `nil` for a
    /// Cloudflare-endpoint result, which is a plain file transfer with no
    /// equivalent signal, not a missing measurement.
    let downloadResponsivenessRPM: Int?
    let uploadResponsivenessRPM: Int?
    /// Idle latency, as `networkQuality` measures it before applying
    /// load. `nil` for a Cloudflare-endpoint result, same reasoning as
    /// the RPM fields above.
    let baseRTTMs: Double?
    /// Real, exact byte counts from `networkQuality`'s own JSON output
    /// (`dl_bytes_transferred`/`ul_bytes_transferred` — undocumented in
    /// the man page, confirmed present in every real run regardless),
    /// not derived from throughput × elapsed time. `nil` for a
    /// Cloudflare-endpoint result, same reasoning as the RPM fields
    /// above — though notably, unlike RPM, that's a real gap rather than
    /// "no equivalent": NMS already knows exactly how many bytes it
    /// requested for a Cloudflare run (it chose the size itself), that
    /// figure just isn't threaded into this type yet. Raised directly:
    /// showing this lets a user judge whether to run the test again on a
    /// metered or limited connection, rather than guessing from "~30s."
    let downloadBytesTransferred: Int?
    let uploadBytesTransferred: Int?
    let source: Source
    let testedAt: Date
}
