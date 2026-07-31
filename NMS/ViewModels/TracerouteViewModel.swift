import Foundation
import Combine

@MainActor
final class TracerouteViewModel: ObservableObject {
    /// Instrumented for the UI state log beyond the original staged five:
    /// diagnosing why the ISP Edge Router check vanished after an upstream
    /// outage required reading source to work out that `monitoredHop` had
    /// been cleared, because none of this was observable. It is now.
    @Published private(set) var hops: [TracerouteHop] = [] {
        didSet { UIStateLogger.log("TracerouteViewModel.hops", hops) }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String? {
        didSet { UIStateLogger.log("TracerouteViewModel.lastError", lastError as Any) }
    }
    @Published private(set) var lastRunAt: Date?
    /// The hop number the user has confirmed as "the" router to monitor —
    /// persisted across launches. `nil` until they confirm one.
    @Published private(set) var monitoredHopNumber: Int? {
        didSet { UIStateLogger.log("TracerouteViewModel.monitoredHopNumber", monitoredHopNumber as Any) }
    }

    private let service = TracerouteService()
    private let reverseDNSService = ReverseDNSService()
    /// Pings each hop directly to get a trustworthy round-trip time — see
    /// `enrichRoundTrips`. The same service `ConnectivityViewModel` uses
    /// for every other ping-based check in this app, not a separate
    /// implementation.
    private let pingService = ConnectivityService()
    private let snapshotStore: SnapshotStore
    private var timer: Timer?
    /// Set when `run()` is called while a trace is already in flight; the
    /// deferred run fires from `finishRun()`. See `run()` for why dropping
    /// the call instead would reintroduce the ISP-Edge-Router-vanishes bug.
    private var rerunRequested = false

    /// Fired once a trace completes, win or lose. Exists specifically for
    /// the launch-time race between this view model and
    /// `ConnectivityViewModel`: both are constructed back-to-back in
    /// `NMSApp.init()`, and `ConnectivityViewModel`'s very first check round
    /// decides whether to include the ISP Edge Router target by reading
    /// `monitoredHop` *at that instant* — before this view model's own
    /// launch-time `run()` (dispatched, not awaited) has had any chance to
    /// resolve it. Without this hook the row is simply absent from Network
    /// Health until the next periodic check, up to 30s later, even though
    /// the trace itself finishes in under a second. `NMSApp` wires this to
    /// `connectivity.runChecks()`.
    var onTraceCompleted: (() -> Void)?

    /// Fired whenever an `AppEventRecord` gets logged (a NAT-layer
    /// change), so the event log view can refresh — mirrors every other
    /// view model's hook. The only event this view model logs.
    var onEventLogged: (() -> Void)?

    /// Whether the last trace found more than one non-internet hop before
    /// reaching the real internet — `nil` until the first trace resolves.
    /// `logAddressingChangeIfNeeded` compares against this to log only on
    /// a genuine change, not on every trace.
    private var lastKnownExtraNATState: Bool?

    private static let target = "1.1.1.1"
    // Traceroute is much heavier than a ping or an HTTP lookup (up to 20
    // hops, each potentially waiting out a timeout), so this runs far less
    // often than connectivity checks or public-IP lookups. This view model
    // is purely discovery now — finding the path and letting you confirm
    // which hop is the ISP edge — not ongoing health monitoring of that
    // hop, which `ConnectivityViewModel` does by ping on its own much
    // faster/reactive cadence (see `OverallStatus.peRouterLabel`). That
    // split is deliberate: re-running a full multi-hop trace just to check
    // whether one already-known address still responds was both slow and
    // the wrong tool for the job.
    private static let runInterval: TimeInterval = 600
    private static let monitoredHopDefaultsKey = "NMS.monitoredHopNumber"

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        monitoredHopNumber = UserDefaults.standard.object(forKey: Self.monitoredHopDefaultsKey) as? Int
        timer = Timer.scheduledTimer(withTimeInterval: FailureInjector.acceleratedInterval(Self.runInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.run()
            }
        }
        run()
    }

    deinit {
        timer?.invalidate()
    }

    func run() {
        guard !isRunning else {
            // Deferred rather than dropped. The concrete case: an upstream
            // outage fires a trace that fails slowly (every hop timing out),
            // and connectivity returns *before* it finishes — so the
            // recovery re-trace from `onInternetReachable` would hit this
            // guard and be swallowed, leaving the ISP Edge Router check
            // missing for up to 10 minutes. That is precisely the bug the
            // recovery hook exists to fix, so dropping the call here would
            // quietly reintroduce it for any outage shorter than a trace.
            rerunRequested = true
            return
        }
        isRunning = true
        let service = self.service
        let target = Self.target
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let result = try service.trace(to: target)
                Task { @MainActor [weak self] in
                    self?.apply(result)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = error.localizedDescription
                    self?.finishRun()
                }
            }
        }
    }

    /// A suggestion only — the first non-RFC1918 hop. Reliable for a simple
    /// single-NAT home network (verified against a real home traceroute),
    /// but on a campus/enterprise network the organization's own border
    /// router often has a public IP long before traffic actually reaches
    /// the ISP, so this can point at the wrong hop. It's a starting point
    /// for you to confirm via `monitorHop(_:)`, not something to trust
    /// blindly on unfamiliar topologies.
    var suggestedEdgeHop: TracerouteHop? {
        hops.first { $0.isLocal == false }
    }

    /// The hop the user has actually confirmed, looked up fresh from the
    /// latest trace by hop number.
    var monitoredHop: TracerouteHop? {
        guard let monitoredHopNumber else { return nil }
        return hops.first { $0.hopNumber == monitoredHopNumber }
    }

    /// The address `ConnectivityViewModel` should actually ping for the ISP
    /// Edge Router check — `monitoredHop?.address` when the latest trace
    /// resolved it, falling back to the last-persisted `ProviderEdgeRecord`
    /// address when it didn't.
    ///
    /// The fallback matters because a hop that stops responding during a
    /// real outage parses as `address: nil` (see `TracerouteHop.address`),
    /// same as a hop that's simply never been resolved yet — and `apply(_:)`
    /// fully replaces `hops` on every trace, so that one bad attempt erases
    /// the previously-known address outright. Without this, unplugging the
    /// upstream link made the ISP Edge Router row show "Not checked" for
    /// the outage's duration instead of "unreachable": the re-trace
    /// `onInternetUnreachable` fires runs while the path is still down,
    /// times out, and `buildTargets` had nothing left to ping. This mirrors
    /// `persistMonitoredHopIfNeeded`, which already tolerates exactly this
    /// by simply not overwriting the persisted address on a failed
    /// resolution — this extends the same tolerance to the live ping
    /// target, reusing that same persisted value rather than caching a
    /// second copy of it.
    var monitoredHopAddress: String? {
        guard monitoredHopNumber != nil else { return nil }
        return monitoredHop?.address ?? snapshotStore.latestProviderEdge()?.address
    }

    /// Confirms which hop is "the" router to monitor going forward, by
    /// position in the path. Pass `nil` to clear the selection and fall
    /// back to `suggestedEdgeHop`.
    func monitorHop(_ hopNumber: Int?) {
        monitoredHopNumber = hopNumber
        if let hopNumber {
            UserDefaults.standard.set(hopNumber, forKey: Self.monitoredHopDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.monitoredHopDefaultsKey)
        }
        persistMonitoredHopIfNeeded()
    }

    private func apply(_ result: [TracerouteHop]) {
        hops = result
        lastRunAt = Date()
        lastError = nil
        persistMonitoredHopIfNeeded()
        logAddressingChangeIfNeeded(result)
        enrichHostnames(for: result)
        enrichRoundTrips(for: result)
        // Last, not first: the run isn't really over until the monitored
        // hop has been persisted, and `finishRun()` can start the next
        // trace immediately.
        finishRun()
    }

    /// How many hops, starting from hop 1, are private/CGNAT before the
    /// first hop that's genuinely on the internet. A normal single-NAT
    /// home network has exactly one (your own router); more than one
    /// means an extra NAT layer somewhere between this Mac and the real
    /// internet — either the customer's own second router, or the ISP's
    /// own carrier-grade NAT. Traceroute alone can't tell which.
    ///
    /// Confirmed against a real trace (Comcast, at Martha's): two
    /// non-internet hops (the customer's own router, then a private
    /// address with no reverse DNS) before the first genuinely public
    /// one — that's what this is meant to catch.
    ///
    /// Stops at the first hop whose `isLocal` isn't `true` — including a
    /// non-responding hop (`isLocal == nil`), which is genuinely
    /// ambiguous rather than assumed either way. Same "can't tell, don't
    /// act" rule this app already applies elsewhere (`SubnetCalculator`,
    /// `SnapshotStore`'s `nil`-fingerprint handling): a hop that didn't
    /// answer might be private or might be the real internet, and
    /// guessing risks a wrong classification more than under-counting
    /// does. The accepted cost: a hop-1 timeout on an otherwise-stable
    /// double-NAT'd network could misclassify a single trace as
    /// single-NAT — hop 1 (the local router) is the most reliable hop to
    /// reach of any of them, so this is rare, and the next trace
    /// self-corrects since only a genuine *change* logs anything.
    nonisolated static func leadingNonInternetHopCount(_ hops: [TracerouteHop]) -> Int {
        var count = 0
        for hop in hops.sorted(by: { $0.hopNumber < $1.hopNumber }) {
            guard hop.isLocal == true else { break }
            count += 1
        }
        return count
    }

    /// Whether any hop's address falls in the CGNAT-reserved range
    /// specifically (100.64.0.0/10), as opposed to merely being RFC 1918
    /// private — evidence strong enough to name the cause directly
    /// ("carrier-grade NAT") rather than the hedged general wording,
    /// since nothing but an ISP's own infrastructure legitimately uses
    /// that range. Martha's trace didn't hit this (Comcast used plain
    /// 10.0.0.0/8 there), so the hedged wording is what most real traces
    /// will actually produce.
    nonisolated static func includesConfirmedCGNAT(_ hops: [TracerouteHop]) -> Bool {
        hops.contains { $0.address.map(IPClassifier.isCGNAT) == true }
    }

    /// Logs `.multipleNATLayersDetected` only on a genuine change in
    /// whether this path has an extra NAT layer — not on every trace
    /// (this view model re-traces every 10 minutes), and not on the very
    /// first trace this session, which has nothing to compare against.
    /// Same reasoning as `WiFiSSIDViewModel.logNetworkChangeIfNeeded`:
    /// every launch on an already-double-NAT'd network would otherwise
    /// log one, and that isn't news, it's just where you already are.
    private func logAddressingChangeIfNeeded(_ hops: [TracerouteHop]) {
        let count = Self.leadingNonInternetHopCount(hops)
        let isExtraNATed = count > 1
        defer { lastKnownExtraNATState = isExtraNATed }
        guard let previous = lastKnownExtraNATState, previous != isExtraNATed else { return }

        let message: String
        if isExtraNATed {
            message = Self.includesConfirmedCGNAT(hops)
                ? "Carrier-grade NAT (CGNAT) detected — \(count) hops before reaching the internet. Public IP is shared with other customers."
                : "Multiple NAT layers detected — \(count) hops before reaching the internet. Public IP may not be unique to this connection (could be an extra router of yours, or your ISP's — can't tell which from this alone)."
        } else {
            message = "Back to a single NAT layer to the internet."
        }
        snapshotStore.logEvent(.multipleNATLayersDetected, message: message)
        onEventLogged?()
    }

    /// The single place a run ends, so the deferred-rerun check can't be
    /// missed on one of the two completion paths (success and failure).
    /// Recursion is bounded to one extra run — the flag is cleared before
    /// re-entering, so a trace that keeps failing can't chain.
    private func finishRun() {
        isRunning = false
        // Fired here, not just from `apply()`'s success path, so a failed
        // trace notifies too — the failure path (`run()`'s `catch`) calls
        // `finishRun()` as well, and `monitoredHop` may have changed either
        // way.
        onTraceCompleted?()
        guard rerunRequested else { return }
        rerunRequested = false
        run()
    }

    /// Resolves each responsive hop's hostname via reverse DNS, in the
    /// background, independently per hop — deliberately *after* `hops` is
    /// already published above, not before, so the popover shows results
    /// immediately with bare IPs rather than waiting on DNS the way the
    /// trace itself used to. Each hop updates in place as its own lookup
    /// resolves, rather than waiting for all of them.
    private func enrichHostnames(for hopsToEnrich: [TracerouteHop]) {
        let service = reverseDNSService
        for hop in hopsToEnrich {
            guard let address = hop.address else { continue }
            let hopNumber = hop.hopNumber
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let hostname = service.hostname(for: address) else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Guards against a stale enrichment result landing
                    // after a *newer* trace already replaced `hops` with a
                    // different path — only apply if this hop still shows
                    // the same address this lookup was actually for.
                    guard
                        let index = self.hops.firstIndex(where: { $0.hopNumber == hopNumber }),
                        self.hops[index].address == address
                    else { return }
                    self.hops[index].hostname = hostname
                    if self.monitoredHopNumber == hopNumber {
                        self.snapshotStore.updateLatestProviderEdgeHostname(hostname, forAddress: address)
                    }
                }
            }
        }
    }

    /// Pings each responsive hop directly to get a trustworthy round-trip
    /// time, replacing `TracerouteService`'s own single, unretried probe
    /// timing entirely — see `TracerouteHop.roundTripMs`'s doc comment for
    /// why that measurement can't be trusted, not just right after a
    /// topology change (`BUGS.md`'s "First traceroute after joining a
    /// network reports inflated latency"). Uses `ConnectivityService`, the
    /// same mechanism `ConnectivityViewModel` already trusts for the
    /// *confirmed* ISP edge router's ongoing latency, just applied to
    /// every hop in the path rather than only the one being monitored.
    ///
    /// Concurrent across hops (`ConnectivityService.check(targets:)`) —
    /// with at most `TracerouteService`'s 4-hop cap, this costs one more
    /// round of local/near-internet pings, not a meaningful delay. No
    /// custom timeout: a hop deep in the ISP's own network deserves the
    /// same WAN-round-trip tolerance as the default target
    /// (`ConnectivityService.Target`'s 2s), the same allowance that
    /// address would get if it were the confirmed monitored hop.
    ///
    /// Deliberately *after* `hops` is already published, same reasoning as
    /// `enrichHostnames` above: the popover shows traceroute's own rough,
    /// immediately-available timing first, then each hop's number is
    /// replaced with a real ping's the moment it resolves, rather than
    /// holding up the whole trace on pings that could themselves time out.
    private func enrichRoundTrips(for hopsToEnrich: [TracerouteHop]) {
        let entries = hopsToEnrich.compactMap { hop -> (hopNumber: Int, address: String, target: ConnectivityService.Target)? in
            guard let address = hop.address else { return nil }
            return (hop.hopNumber, address, ConnectivityService.Target(label: "\(hop.hopNumber)", host: address))
        }
        guard !entries.isEmpty else { return }
        let service = pingService
        Task { @MainActor [weak self] in
            let checks = await service.check(targets: entries.map(\.target))
            guard let self else { return }
            for (offset, entry) in entries.enumerated() {
                // Same staleness guard as `enrichHostnames`: only apply if
                // this hop still shows the same address this ping was
                // actually for — a newer trace could have already replaced
                // `hops` with a different path by the time this ping round
                // finishes.
                guard
                    let index = self.hops.firstIndex(where: { $0.hopNumber == entry.hopNumber }),
                    self.hops[index].address == entry.address
                else { continue }
                let check = checks[offset]
                self.hops[index].roundTripMs = check.success ? check.latencyMs : nil
            }
        }
    }

    /// Like `PublicIPRecord`, only persists a row when the monitored hop's
    /// address actually changed — a change timeline, not a per-run log.
    /// The timeline itself has no UI (see `PUNCHLIST.md`'s "Provider Edge
    /// History" entry — removed as a display, kept as the mechanism
    /// `monitoredHopAddress`'s outage fallback and hostname enrichment
    /// both depend on `latestProviderEdge()` for).
    private func persistMonitoredHopIfNeeded() {
        guard let hop = monitoredHop, let address = hop.address else { return }
        _ = snapshotStore.recordProviderEdgeIfChanged(address: address, hostname: hop.hostname)
    }
}
