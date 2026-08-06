import Foundation

#if DEBUG
/// Converts a completed FW (`FWClient`) traceroute into the same shape
/// Globalping's own probe results use (`GlobalpingReverseTraceService
/// .ProbeTraceResult`), so it can be spliced into Path Discovery's
/// `results` array as one more corroborating source —
/// `TopologyBuilder`/the comparison table don't need to know or care
/// where a trace came from, since they already treat each entry
/// generically. See `PJorgens61/NMS#6` and `PJorgens61/FW#1` for the
/// full reasoning: FW gives Path Discovery a stable, always-present
/// vantage point, alongside Globalping's randomly-drawn pool.
///
/// The one place allowed to know about both `FWClient` and
/// `GlobalpingReverseTraceService.ProbeTraceResult` — keeps that
/// coupling contained here rather than leaking Globalping's shape into
/// `FWClient`, which stays a plain, Globalping-agnostic HTTP client.
///
/// `#if DEBUG`, same guard as `GlobalpingReverseTraceService`/
/// `TopologyBuilder` — Path Discovery's own UI is Debug-only, so nothing
/// here is ever compiled into a Release build.
enum FWTraceService {
    enum FWTraceError: Error {
        case didNotComplete
    }

    /// Poll loop mirrors `FirewallVisibilityViewModel.runScan`'s own —
    /// same bounded-not-indefinite reasoning (a misbehaving or
    /// unreachable server can't leave this hanging forever), same
    /// `poll_after_ms`-driven spacing.
    static func run(client: FWClient, target: String) async throws -> GlobalpingReverseTraceService.ProbeTraceResult {
        var job = try await client.startTrace(target: target)
        var attempts = 0
        while job.status != "complete", attempts < 30 {
            try await Task.sleep(nanoseconds: UInt64(job.pollAfterMs) * 1_000_000)
            job = try await client.pollTraceJob(id: job.id)
            attempts += 1
        }
        guard job.status == "complete" else {
            throw FWTraceError.didNotComplete
        }
        return convert(job, target: target, serverHost: URL(string: FeatureFlags.firewallServerURL ?? "")?.host)
    }

    /// Pure and testable against a fixture `FWClient.TraceJob`, same
    /// discipline `FWClient.decodeStartTraceResponse`/
    /// `decodeTraceStatusResponse` already follow for their own layer —
    /// `serverHost` passed in explicitly rather than read from
    /// `FeatureFlags` here, so a test doesn't depend on whatever happens
    /// to be configured on the machine running it.
    static func convert(_ job: FWClient.TraceJob, target: String, serverHost: String?) -> GlobalpingReverseTraceService.ProbeTraceResult {
        let hops = job.hops.enumerated().map { index, hop in
            GlobalpingReverseTraceService.ProbeTraceResult.Hop(
                hopNumber: index + 1,
                address: hop.address,
                hostname: hop.hostname,
                roundTripTimesMs: hop.rttMs.map { [$0] } ?? []
            )
        }
        return GlobalpingReverseTraceService.ProbeTraceResult(
            // Not a real city -- deliberately readable, honest labeling
            // (see `TopologyBuilder.sourceLabel`'s join logic): renders
            // as "Firewall Visibility · <host>", visibly distinct from
            // Globalping's "City, Country · Provider · ASN" sources, so
            // it's obvious in the diagram this one is fixed/known rather
            // than randomly drawn.
            city: "Firewall Visibility",
            country: nil,
            network: serverHost,
            asn: nil,
            status: job.status,
            // Mirrors how a completed Globalping probe's own
            // `resolvedAddress` is the destination it reached.
            resolvedAddress: target,
            hops: hops
        )
    }
}
#endif
