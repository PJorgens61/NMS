import Foundation

@MainActor
@Observable
final class TracerouteViewModel {
    /// Instrumented for the UI state log beyond the original staged five:
    /// diagnosing why the ISP Edge Router check vanished after an upstream
    /// outage required reading source to work out that `monitoredHop` had
    /// been cleared, because none of this was observable. It is now.
    private(set) var hops: [TracerouteHop] = [] {
        didSet { UIStateLogger.log("TracerouteViewModel.hops", hops) }
    }
    private(set) var isRunning = false
    private(set) var lastError: String? {
        didSet { UIStateLogger.log("TracerouteViewModel.lastError", lastError as Any) }
    }
    private(set) var lastRunAt: Date?
    /// The hop number the user has confirmed as "the" router to monitor —
    /// persisted per network (`SnapshotStore.confirmedEdgeHopNumber`), not
    /// globally. `nil` until they confirm one *on this network*; see
    /// `reloadMonitoredHop`.
    private(set) var monitoredHopNumber: Int? {
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

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        // Comes back `nil` here — `currentNetworkFingerprint` isn't
        // resolved yet this early in launch (same as every other
        // per-network fetch in `init`, e.g. `EventLogViewModel`). Corrected
        // once recognition completes, via `reloadMonitoredHop()` wired to
        // `NetworkIdentityViewModel.onNetworkRecognized` in `NMSApp`.
        monitoredHopNumber = snapshotStore.confirmedEdgeHopNumber()
        timer = Timer.scheduledTimer(withTimeInterval: FailureInjector.acceleratedInterval(Self.runInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.run()
            }
        }
        run()
    }

    // `deinit` is nonisolated even on a `@MainActor` class -- reading an
    // `@Observable`-tracked stored property from it needs
    // `MainActor.assumeIsolated`, safe here since every instance is only
    // ever created/held on the main actor (see `NMSApp`).
    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
        }
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

    /// A suggestion — the first non-local hop, where "local" already
    /// accounts for CGNAT as well as RFC 1918 (see `TracerouteHop
    /// .isLocal`'s own doc comment for why that matters). Reliable for a
    /// simple single-NAT home network (verified against a real home
    /// traceroute), but on a campus/enterprise network the organization's
    /// own border router often has a public IP long before traffic
    /// actually reaches the ISP, so this can point at the wrong hop.
    ///
    /// Trusted automatically exactly once per network, by
    /// `autoConfirmEdgeHopIfNeeded()` below — every trace after that,
    /// it's still shown as a fallback suggestion in the UI (the arrow in
    /// `PathToInternetTile`'s hop rows) for whenever nothing's confirmed,
    /// but nothing acts on it again without you.
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

    /// A small, supplementary "is the access circuit alive at all" signal —
    /// additive to, not a replacement for, the confirmed-hop model above.
    /// Raised directly after a full field-testing session kept finding
    /// real cases where trusting *one* hop as "the" edge is fragile: a
    /// residential ISP's edge redundantly alternating between two real
    /// routers, a confirmed hop whose owner didn't match the presumed ISP
    /// at all. See `PUNCHLIST.md`'s "monitor every hop" entry for the full
    /// discussion, including why this stays additive rather than replacing
    /// `monitoredHopAddress`: that property's own history
    /// (`ProviderEdgeRecord`) is what made the redundant-router discovery
    /// possible in the first place, and would need rebuilding per-hop to
    /// give up nothing by going wider.
    ///
    /// Deliberately `Bool?`, and deliberately never set back to `false`
    /// (see `ConnectivityViewModel.runChecks()`, the only writer) — an
    /// asymmetry raised directly ("i assume that if an isp router
    /// responded to pings yesterday it will today... any responds =
    /// up"): one candidate hop answering is real proof the circuit is up,
    /// but every candidate staying silent doesn't safely prove it's down,
    /// since ICMP can be selectively deprioritized at an individual
    /// router even on an otherwise-healthy path (same reasoning already
    /// behind `isLikelyLocalPingFailure` elsewhere in this app). `nil`
    /// means "no candidates yet, or not checked this network" — reset in
    /// `reloadMonitoredHop()`, the same two-beat network-switch hook
    /// every other per-network signal in this view model already uses.
    private(set) var accessCircuitReachable: Bool? = nil {
        didSet { UIStateLogger.log("TracerouteViewModel.accessCircuitReachable", accessCircuitReachable as Any) }
    }

    /// Up to 3 hop addresses past the home router (hop 1), used as the
    /// ping targets for `accessCircuitReachable` above. Positional (hop
    /// 2/3/4), not address-pinned — matching `monitorHop`'s own
    /// reasoning: a specific IP can rotate (confirmed live, a residential
    /// ISP's edge alternating between two real routers within minutes)
    /// while the hop *position* stays a meaningful, stable thing to poll.
    /// Sourced from `hops`, which already refreshes on its own 10-minute
    /// discovery cadence — no new traceroute needed for this.
    var accessCircuitCandidateAddresses: [String] {
        Array(hops.filter { $0.hopNumber > 1 }.compactMap(\.address).prefix(3))
    }

    /// The most recent Path Discovery (`GlobalpingReverseTraceService`)
    /// run's result against the currently confirmed PE address, straight
    /// from `ProviderEdgeRecord` — `nil` means no run has happened yet
    /// for this address, distinct from a run that found zero
    /// corroboration (`corroboratingCount == 0`, real information worth
    /// showing, not the same as "never checked").
    var externalCorroboration: (probeCount: Int, corroboratingCount: Int, corroboratedAt: Date?)? {
        guard let edge = snapshotStore.latestProviderEdge(),
              let probeCount = edge.pathDiscoveryProbeCount,
              let corroboratingCount = edge.pathDiscoveryCorroboratingCount
        else { return nil }
        return (probeCount, corroboratingCount, edge.externallyCorroboratedAt)
    }

    /// Whether a reverse-trace's last hop before reaching its own
    /// destination matches `confirmedAddress` — the corroboration check
    /// Path Discovery uses to decide whether an external vantage point's
    /// trace actually confirms the currently-confirmed PE hop. The
    /// destination itself is excluded from consideration: Globalping's
    /// hop list includes the target address as its own final hop (see
    /// `GlobalpingReverseTraceService`'s doc comment), which is this
    /// Mac's own address, never the PE's.
    ///
    /// `nonisolated static`, pure, for the same directly-unit-testable
    /// reasoning as `leadingNonInternetHopCount`/`includesConfirmedCGNAT`
    /// above — no live network call or `SnapshotStore` needed to test
    /// the actual matching logic.
    ///
    /// `#if DEBUG` because it references
    /// `GlobalpingReverseTraceService.ProbeTraceResult.Hop`, which only
    /// exists in debug builds (Path Discovery is debug-only tooling, same
    /// tier as `LocalDiagnosticServer`) — this file itself isn't
    /// debug-gated, so the function referencing that type has to be,
    /// same class of fix as `ContentView.snapshotStore`'s own doc
    /// comment already documents for the equivalent problem there.
    #if DEBUG
    /// The ISP-edge candidate from one probe's perspective — the last
    /// real hop before its own destination. Factored out of
    /// `reverseTraceCorroborates` once Path Discovery's own results page
    /// needed the same extraction for its probe-comparison table, not
    /// just a yes/no match.
    nonisolated static func lastHopBeforeDestination(
        _ hops: [GlobalpingReverseTraceService.ProbeTraceResult.Hop],
        destination: String?
    ) -> GlobalpingReverseTraceService.ProbeTraceResult.Hop? {
        hops.last(where: { $0.address != nil && $0.address != destination })
    }

    /// Whether the hop *immediately before* the destination (by array
    /// position, not by "last one that replied") simply didn't reply —
    /// found live (2026-08-04): one probe's own edge candidate looked
    /// like a genuinely different device than four others', but the
    /// device it landed on had shown up as the *known predecessor* of
    /// the majority device in every other trace that same session. The
    /// real explanation: the usual edge device just didn't answer that
    /// one probe's packets, so `lastHopBeforeDestination` correctly fell
    /// back one hop earlier — not a real topology divergence, a gap in
    /// the reply chain. When this is `true`, whatever
    /// `lastHopBeforeDestination` returns should be shown as "likely
    /// continues past here, no reply" rather than presented as a
    /// confident final answer.
    nonisolated static func hasGapBeforeDestination(
        _ hops: [GlobalpingReverseTraceService.ProbeTraceResult.Hop],
        destination: String?
    ) -> Bool {
        guard let destination,
              let destinationIndex = hops.firstIndex(where: { $0.address == destination }),
              destinationIndex > 0
        else { return false }
        return hops[destinationIndex - 1].address == nil
    }

    /// Exact-address match first; falls back to a device-stem match
    /// (`GlobalpingReverseTraceService.deviceStem`) when both hostnames
    /// are known and resolve to the same stem — a real gap found live
    /// (2026-08-06, mixing international Path Discovery probes in for
    /// the first time): Falkenstein/Ashburn's own last hop before their
    /// destination was `198.27.244.58 (ae0.eo-sw1-2.snfcca05.sonic.net)`,
    /// a genuinely different device one hop further out than the
    /// confirmed edge — but Buffalo/LA's was `157.131.209.36
    /// (305.ae0.bng3.snfcca05.sonic.net)`, the *same physical router* as
    /// the confirmed `75.101.33.52 (bng3.snfcca05.sonic.net)`, just
    /// answering on a different interface for that inbound path. Exact-
    /// address matching alone read both as equally "no match," losing
    /// the distinction a multi-homed edge router's sibling interfaces
    /// need. `confirmedHostname: nil` (the default) falls back to
    /// address-only matching, same as before this existed — this is
    /// genuinely unknowable, not a shim, for any caller that hasn't
    /// resolved the confirmed hop's hostname.
    nonisolated static func reverseTraceCorroborates(
        _ hops: [GlobalpingReverseTraceService.ProbeTraceResult.Hop],
        destination: String?,
        confirmedAddress: String,
        confirmedHostname: String? = nil
    ) -> Bool {
        guard let hop = lastHopBeforeDestination(hops, destination: destination) else { return false }
        if hop.address == confirmedAddress { return true }
        guard let confirmedHostname, let hopHostname = hop.hostname,
              let confirmedStem = GlobalpingReverseTraceService.deviceStem(fromHostname: confirmedHostname),
              let hopStem = GlobalpingReverseTraceService.deviceStem(fromHostname: hopHostname)
        else { return false }
        return confirmedStem == hopStem
    }

    /// Gap-aware summary across a full Path Discovery run. Probes with a
    /// reply gap right before their own destination
    /// (`hasGapBeforeDestination`) are excluded entirely — not counted
    /// against corroboration — since a gap means that probe's real edge
    /// candidate is unknown, not that it saw a genuinely different
    /// device. Before this, `DebugToolsView.runPathDiscovery` counted
    /// gapped probes as plain non-matches, so the persisted
    /// `ProviderEdgeRecord.pathDiscoveryProbeCount`/
    /// `pathDiscoveryCorroboratingCount` (and anything logged from them)
    /// could understate corroboration purely from a reply gap — the same
    /// false-negative shape as the real Ashburn case above, just in the
    /// persisted numbers instead of the results-table UI.
    nonisolated static func corroboratingSummary(
        _ results: [GlobalpingReverseTraceService.ProbeTraceResult],
        confirmedAddress: String,
        confirmedHostname: String? = nil
    ) -> (effectiveProbeCount: Int, corroboratingCount: Int) {
        let effective = results.filter { !hasGapBeforeDestination($0.hops, destination: $0.resolvedAddress) }
        let corroborating = effective.filter {
            reverseTraceCorroborates($0.hops, destination: $0.resolvedAddress, confirmedAddress: confirmedAddress, confirmedHostname: confirmedHostname)
        }.count
        return (effective.count, corroborating)
    }
    #endif

    /// Confirms which hop is "the" router to monitor going forward, by
    /// position in the path. Pass `nil` to clear the selection and fall
    /// back to `suggestedEdgeHop`.
    func monitorHop(_ hopNumber: Int?) {
        monitoredHopNumber = hopNumber
        snapshotStore.setConfirmedEdgeHopNumber(hopNumber)
        persistMonitoredHopIfNeeded()
    }

    /// Auto-confirms `suggestedEdgeHop` the first time a network ever
    /// gets a trace with a usable suggestion — raised directly ("can
    /// these process all happen automatically as internet access is
    /// established?"), after a real, confirmed case of a network
    /// (Sonic, this session) sitting at "Not confirmed" indefinitely:
    /// tracing itself was already fully automatic (launch, every 10
    /// minutes, every topology change, every reachability transition —
    /// see this class's own `init`/`run` and `NMSApp`'s wiring), but
    /// *confirming* which hop is the edge was not, and nothing ever
    /// promoted a correct, sitting-right-there suggestion into an
    /// actual confirmation.
    ///
    /// Gated on `!snapshotStore.hasDecidedEdgeHop()`, not just
    /// `monitoredHopNumber == nil` — the latter is also true right after
    /// you've deliberately cleared a hop via "Stop monitoring," and this
    /// must never silently re-apply a suggestion you just backed away
    /// from. See `KnownNetwork.hasDecidedEdgeHop`'s own doc comment for
    /// the full reasoning, including the one accepted trade-off (a
    /// network explicitly cleared *before* this field existed reads
    /// identically to one never touched, so it gets one auto-confirm
    /// pass after this ships).
    ///
    /// Called from two places, deliberately -- either alone leaves a real
    /// race window open (see `reloadMonitoredHop`'s own doc comment for
    /// the confirmed case that motivated the second call site):
    ///
    /// 1. `apply(_:)`, after `hops` is set (so `suggestedEdgeHop` sees the
    ///    fresh trace) and before `persistMonitoredHopIfNeeded()` (so a
    ///    hop confirmed here gets persisted to `ProviderEdgeRecord` in the
    ///    same cycle, not one trace later). Handles the common case: a
    ///    trace resolving after the network is already recognized.
    /// 2. `reloadMonitoredHop()`, right as recognition completes. Handles
    ///    the case where a trace already resolved a suggestion *before*
    ///    recognition finished -- the call from `apply(_:)` would have
    ///    hit `setConfirmedEdgeHopNumber`'s no-row-yet guard and silently
    ///    lost the confirmation, so this retries using the same `hops`
    ///    once there's finally a row to attach it to.
    ///
    /// Both go through `monitorHop(_:)` itself rather than duplicating its
    /// two writes, so auto-confirming and manually confirming are
    /// indistinguishable from every other reader's perspective —
    /// including `hasDecidedEdgeHop` itself, which this sets to `true`
    /// the same way a manual confirm would.
    private func autoConfirmEdgeHopIfNeeded() {
        guard monitoredHopNumber == nil,
              !snapshotStore.hasDecidedEdgeHop(),
              let suggested = suggestedEdgeHop
        else { return }
        monitorHop(suggested.hopNumber)
    }

    /// Re-reads the confirmed hop number for whatever network
    /// `currentNetworkFingerprint` currently points at. Called twice per
    /// topology change, same two-beat pattern `ISPIdentityViewModel` uses
    /// for the equivalent problem:
    ///
    /// 1. Right after `NetworkIdentityViewModel.reset()` clears the
    ///    fingerprint to `nil` — this then reads back `nil` too, clearing
    ///    a stale confirmed hop number immediately rather than leaving the
    ///    *previous* network's confirmation displayed (and liable to be
    ///    silently re-persisted against the new network by
    ///    `persistMonitoredHopIfNeeded`, if the new trace happens to
    ///    produce a hop at the same position) while recognition is still
    ///    pending.
    /// 2. Again from `NetworkIdentityViewModel.onNetworkRecognized`, once
    ///    the new network's fingerprint is actually set — this is what
    ///    makes a *different* network's previously-confirmed hop (or lack
    ///    of one) show up correctly, rather than whatever the previous
    ///    network's confirmation happened to be.
    func reloadMonitoredHop() {
        monitoredHopNumber = snapshotStore.confirmedEdgeHopNumber()
        // A network switch's candidate addresses belong to a different
        // path entirely -- a stale "reachable" reading from the previous
        // network would be actively misleading here, not just outdated.
        accessCircuitReachable = nil
        // Real, confirmed race (Sonic, this session): the launch-time
        // trace in `init()` often resolves `suggestedEdgeHop` *before*
        // `NetworkIdentityViewModel` finishes recognizing the network, so
        // the `autoConfirmEdgeHopIfNeeded()` call from that trace's own
        // `apply(_:)` hits `setConfirmedEdgeHopNumber`'s
        // no-KnownNetwork-row-yet guard and silently no-ops -- and this
        // very read, moments later from `onNetworkRecognized`, is what
        // stomps the (already-lost) in-memory confirmation back to `nil`.
        // `recordNetworkSeen` (see `NetworkIdentityViewModel.recognize`)
        // always creates the `KnownNetwork` row *before* calling
        // `setCurrentNetworkFingerprint`, so by the time this runs the row
        // is guaranteed to exist -- retrying here, using whatever `hops`
        // the too-early trace already left behind, closes the race
        // without needing a second trace.
        autoConfirmEdgeHopIfNeeded()
    }

    /// Called by `ConnectivityViewModel.runChecks()` after pinging
    /// `accessCircuitCandidateAddresses` -- the only writer, and the only
    /// direction it ever moves this in (see the property's own doc
    /// comment for why "no one answered" never flips it back to `false`).
    func markAccessCircuitReachable() {
        accessCircuitReachable = true
    }

    private func apply(_ result: [TracerouteHop]) {
        hops = result
        lastRunAt = Date()
        lastError = nil
        autoConfirmEdgeHopIfNeeded()
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

    /// Whether any *leading* hop's address falls in the CGNAT-reserved
    /// range specifically (100.64.0.0/10), as opposed to merely being
    /// RFC 1918 private — evidence strong enough to name the cause
    /// directly ("carrier-grade NAT") rather than the hedged general
    /// wording, since nothing but an ISP's own infrastructure
    /// legitimately uses that range. Martha's trace didn't hit this
    /// (Comcast used plain 10.0.0.0/8 there), so the hedged wording is
    /// what most real traces will actually produce.
    ///
    /// Scoped to the same leading prefix `leadingNonInternetHopCount`
    /// already uses, not the whole trace — a real correctness bug fixed
    /// after direct discussion (2026-08-04): an ISP can legitimately
    /// number its own backbone router-to-router links out of
    /// 100.64.0.0/10 too (the address doesn't need to be public for the
    /// customer traffic it carries, which is routed via BGP-learned
    /// public prefixes — the same reasoning RFC 6598 itself gives for
    /// reserving this range, to avoid colliding with a subscriber's own
    /// already-common RFC 1918 usage). A hop like that can appear well
    /// past the first public hop, with zero bearing on whether *this*
    /// connection is behind CGNAT — before this fix, one unrelated
    /// backbone hop deep in an otherwise-clean trace would have wrongly
    /// upgraded the event wording to "confirmed" CGNAT and wrongly set
    /// `DDNSViewModel.checkAll()`'s `isCGNAT` flag, both of which only
    /// make sense for CGNAT actually sitting on *this* Mac's own path.
    nonisolated static func includesConfirmedCGNAT(_ hops: [TracerouteHop]) -> Bool {
        let sorted = hops.sorted(by: { $0.hopNumber < $1.hopNumber })
        let leadingCount = leadingNonInternetHopCount(hops)
        return sorted.prefix(leadingCount).contains { $0.address.map(IPClassifier.isCGNAT) == true }
    }

    /// Logs `.multipleNATLayersDetected` only on a genuine change in
    /// whether this path has an extra NAT layer — not on every trace
    /// (this view model re-traces every 10 minutes), and not on the very
    /// first trace this session, which has nothing to compare against.
    /// Same reasoning as `WiFiSSIDViewModel.logNetworkChangeIfNeeded`:
    /// every launch on an already-double-NAT'd network would otherwise
    /// log one, and that isn't news, it's just where you already are.
    private func logAddressingChangeIfNeeded(_ hops: [TracerouteHop]) {
        // An empty result means the trace didn't run at all — most often a
        // brief interface-down blip mid network-transition — not that this
        // network genuinely has zero non-internet hops.
        // `leadingNonInternetHopCount([])` can't tell those apart (it just
        // never enters its loop and returns 0), so without this guard a
        // transient empty trace read as "single-NAT" and wrote a false
        // "Back to a single NAT layer" event to the durable Events log,
        // moments before the next (real) trace logged the correct state
        // right back. Returning before touching `lastKnownExtraNATState`
        // leaves it exactly as the last real trace left it, so that next
        // real trace still compares against genuine prior state, not this
        // blip. See BUGS.md's "A brief interface-down blip..." entry.
        guard !hops.isEmpty else { return }
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
