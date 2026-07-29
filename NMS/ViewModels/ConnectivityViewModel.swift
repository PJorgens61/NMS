import Foundation
import Combine

@MainActor
final class ConnectivityViewModel: ObservableObject {
    @Published private(set) var checks: [ConnectivityCheck] = [] {
        didSet { UIStateLogger.log("ConnectivityViewModel.checks", checks) }
    }
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isChecking = false

    private let service = ConnectivityService()
    private let dnsService = DNSResolutionService()
    private let httpService = HTTPCheckService()
    private let snapshotStore: SnapshotStore
    private weak var networkMonitor: NetworkMonitorViewModel?
    private weak var lanDiscovery: LANDiscoveryViewModel?
    private weak var traceroute: TracerouteViewModel?
    private weak var snmp: SNMPViewModel?
    private weak var publicIP: PublicIPViewModel?
    /// Set when `runChecks()` is called while a round is already in flight;
    /// the deferred round fires from `finishChecking()`. Needed because
    /// `TracerouteViewModel.onTraceCompleted` can land while the very first
    /// launch-time round (started synchronously from `init()`) is still
    /// running its own async pings — dropping that call instead of
    /// deferring it would silently reintroduce the up-to-30s gap this
    /// exists to close.
    private var recheckRequested = false
    /// The previous round's `anyUnhealthy`, so `apply(_:)` can tell a fresh
    /// transition into failure apart from an outage that's already been
    /// detected and is just continuing.
    private var wasUnhealthy = false
    private var timer: Timer?

    /// Labels of the infrastructure (SNMP) devices in the current round, so
    /// `logTransitions` can log events for them without hardcoding their
    /// names the way the fixed router/internet/DNS/HTTP labels are.
    private var infrastructureLabels: Set<String> = []

    private static let checkInterval: TimeInterval = 30
    /// While anything (router/internet/DNS/HTTP) is currently unhealthy,
    /// poll this often instead — so Network Health picks up a recovery (or
    /// confirms it's still down) much sooner than the normal 30s cadence.
    /// Still cheap enough at this cadence: one ping, one DNS query, one
    /// HTTP fetch, all short-timeout.
    private static let fastCheckInterval: TimeInterval = 5
    private static let internetHost = "1.1.1.1"
    /// Caps how many infrastructure devices get pinged per round, so a
    /// network with a lot of managed gear doesn't turn every 5s round into
    /// a sweep of its own.
    private static let maxInfrastructureTargets = 6

    /// Fired whenever an `AppEventRecord` gets logged (router/internet/DNS/
    /// HTTP became unreachable, or became reachable again), so the event
    /// log view can refresh.
    var onEventLogged: (() -> Void)?

    /// Fired specifically when the raw IP-layer check (ping to `1.1.1.1`)
    /// transitions to unreachable — not for router/DNS/HTTP, and not for
    /// recoveries. This is the earliest, strongest signal that something
    /// *upstream* of the local router broke (e.g. a switch between it and
    /// the ISP) — exactly the case `TracerouteViewModel` exists to
    /// pinpoint, but which wouldn't otherwise prompt a re-trace for up to
    /// 10 minutes, since it doesn't touch the Mac's own interface/IP/router.
    var onInternetUnreachable: (() -> Void)?

    /// The recovery counterpart, and not merely for symmetry — without it
    /// the ISP Edge Router check silently disappears for up to 10 minutes
    /// after any upstream outage. Observed in a real test (an uplink pulled
    /// between a desktop switch and the switch above it): the outage fires
    /// `onInternetUnreachable`, that re-trace fails while the path is down,
    /// `TracerouteViewModel.monitoredHop` goes nil, and the PE target
    /// vanishes from `buildTargets()` — so when connectivity returns there
    /// is no PE check left to recover, and `peRouterUnreachable` never gets
    /// its matching `peRouterReachable`. Nothing else re-runs a trace here,
    /// since an upstream break never touches the Mac's own interface and so
    /// never fires `onChangePersisted`. Re-tracing on recovery repopulates
    /// `monitoredHop` and restores the check.
    var onInternetReachable: (() -> Void)?

    init(
        networkMonitor: NetworkMonitorViewModel,
        lanDiscovery: LANDiscoveryViewModel,
        traceroute: TracerouteViewModel,
        publicIP: PublicIPViewModel,
        snapshotStore: SnapshotStore
    ) {
        self.networkMonitor = networkMonitor
        self.lanDiscovery = lanDiscovery
        self.traceroute = traceroute
        self.publicIP = publicIP
        self.snapshotStore = snapshotStore
        runChecks()
    }

    /// Set after init — `SNMPViewModel` depends on several view models that
    /// are themselves constructed alongside this one, so the reference is
    /// injected once the graph is fully built (see `NMSApp.init`).
    func attach(snmp: SNMPViewModel) {
        self.snmp = snmp
    }

    /// Recent latency per Network Health layer, keyed by
    /// `ConnectionLayer.id`, for the row sparklines.
    ///
    /// Only the five layers that actually produce a timed probe. Network
    /// and Interface are connectivity/identity state with no latency
    /// concept, so they get no sparkline rather than an empty one.
    ///
    /// Fetched on demand rather than maintained continuously: the
    /// popover is closed almost all the time, so keeping a live chart
    /// buffer updated every check round would be work nobody is looking
    /// at. Called from `.task` when the section actually appears.
    func latencyHistory(limit: Int = 30) -> [String: [LatencySample]] {
        let layers: [(id: String, label: String)] = [
            ("localRouter", OverallStatus.routerLabel),
            ("publicIP", OverallStatus.publicIPLabel),
            ("peRouter", OverallStatus.peRouterLabel),
            ("internet", OverallStatus.internetLabel),
            ("dns", OverallStatus.dnsLabel),
            ("http", OverallStatus.httpLabel)
        ]
        return layers.reduce(into: [:]) { result, layer in
            result[layer.id] = snapshotStore.fetchLatencyHistory(label: layer.label, limit: limit)
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// Replaces a fixed repeating timer — the interval before the *next*
    /// round depends on whether anything's currently unhealthy, so this is
    /// a one-shot timer that reschedules itself after every round instead.
    private func scheduleNextCheck(after interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runChecks()
            }
        }
    }

    /// Runs a round of checks: ping-based (router, a couple of known local
    /// devices, a known internet host), plus DNS resolution and an HTTP
    /// fetch — the three layers of "is the internet actually usable," which
    /// can fail independently of each other (DNS or HTTP can break while
    /// raw IP connectivity still works). Pinging and DNS resolution block
    /// for up to a couple of seconds each, so they run off the main thread;
    /// the HTTP fetch is genuinely async and doesn't need that.
    func runChecks() {
        guard !isChecking else {
            recheckRequested = true
            return
        }
        isChecking = true

        guard networkMonitor?.currentInterface != nil else {
            // No interface at all: `SCDynamicStore` already tells us
            // definitively there's no connectivity, so there's nothing to
            // gain by actually attempting Internet/DNS/HTTP — and real risk
            // in doing so. Confirmed directly: with zero interfaces up, the
            // DNS probe's `getaddrinfo` call returned a "success"
            // (`EAI_NONAME`) in ~1ms — some local OS-level shortcut taken
            // when there's nothing to even send a query on, not a genuine
            // round trip, but indistinguishable from a real NXDOMAIN by
            // return code alone (this is a variant of the same class of
            // bug as the earlier DNS-caching and HTTP-caching issues: the
            // OS quietly answering "successfully" without ever touching
            // the network). Skip the attempt entirely and report
            // Internet/DNS/HTTP/ISP-edge-router as unreachable immediately.
            let now = Date()
            var results = [
                ConnectivityCheck(label: OverallStatus.internetLabel, target: Self.internetHost, success: false, latencyMs: nil, checkedAt: now),
                ConnectivityCheck(label: OverallStatus.dnsLabel, target: "apple.com (random subdomain probe)", success: false, latencyMs: nil, checkedAt: now),
                ConnectivityCheck(label: OverallStatus.httpLabel, target: "captive.apple.com", success: false, latencyMs: nil, checkedAt: now)
            ]
            if let address = traceroute?.monitoredHopAddress {
                results.append(ConnectivityCheck(label: OverallStatus.peRouterLabel, target: address, success: false, latencyMs: nil, checkedAt: now))
            }
            if let publicIPAddress = publicIP?.currentIP {
                results.append(ConnectivityCheck(label: OverallStatus.publicIPLabel, target: publicIPAddress, success: false, latencyMs: nil, checkedAt: now))
            }
            apply(results)
            return
        }

        let targets = buildTargets()
        guard !targets.isEmpty else {
            finishChecking()
            return
        }
        let service = self.service
        let dnsService = self.dnsService
        let httpService = self.httpService

        // The ping batch, the DNS probe and the HTTP fetch used to run one
        // after another — pings, *then* DNS, *then* HTTP — so during a real
        // outage each one's own timeout stacked on top of the last as pure
        // serial dead time. Measured directly on a failing round: pings
        // (parallel among themselves) took ~2.1s, then DNS's 2s timeout,
        // then HTTP's 2s timeout, landing the round ~4s after the last ping
        // had already finished. All three now start together instead —
        // HTTP is kicked off immediately since it's genuinely `async` and
        // costs nothing to start early; pings and DNS both block their own
        // thread (`Process`/`waitUntilExit` and a semaphore-gated
        // `getaddrinfo`, respectively) so each gets its own queue via a
        // `DispatchGroup`, run concurrently with each other and with HTTP.
        // Worst case is now whichever single one of the three is slowest,
        // not the sum of all three.
        let httpTask = Task { await Self.runHTTPCheck(httpService) }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let group = DispatchGroup()
            var pingResults: [ConnectivityCheck] = []
            var dnsResult: ConnectivityCheck!

            group.enter()
            DispatchQueue.global(qos: .utility).async {
                pingResults = service.check(targets: targets)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                dnsResult = Self.runDNSCheck(dnsService)
                group.leave()
            }
            group.wait()

            var results = pingResults
            results.append(dnsResult)

            Task { @MainActor in
                guard let self else { return }
                results.append(await httpTask.value)
                self.apply(results)
            }
        }
    }

    private static func runDNSCheck(_ service: DNSResolutionService) -> ConnectivityCheck {
        let checkedAt = Date()
        let start = Date()
        let target = "apple.com (random subdomain probe)"
        do {
            try service.probe()
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            return ConnectivityCheck(label: OverallStatus.dnsLabel, target: target, success: true, latencyMs: elapsedMs, checkedAt: checkedAt)
        } catch {
            return ConnectivityCheck(label: OverallStatus.dnsLabel, target: target, success: false, latencyMs: nil, checkedAt: checkedAt)
        }
    }

    private static func runHTTPCheck(_ service: HTTPCheckService) async -> ConnectivityCheck {
        let checkedAt = Date()
        let start = Date()
        let target = "captive.apple.com"
        do {
            try await service.check()
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            return ConnectivityCheck(label: OverallStatus.httpLabel, target: target, success: true, latencyMs: elapsedMs, checkedAt: checkedAt)
        } catch {
            return ConnectivityCheck(label: OverallStatus.httpLabel, target: target, success: false, latencyMs: nil, checkedAt: checkedAt)
        }
    }

    private func apply(_ results: [ConnectivityCheck]) {
        // Injected before anything else sees the results, so persistence,
        // event transitions, cadence and status all react exactly as they
        // would to a real outage — the point being to exercise that whole
        // downstream chain, not just the display. No-op unless the debug
        // defaults key is set; see `FailureInjector`.
        let results = FailureInjector.apply(to: results)
        let previous = checks
        checks = snapshotStore.saveConnectivityChecks(results)
        lastCheckedAt = Date()

        // Measurements are still persisted above — they genuinely
        // happened, and the sparklines should show them — but a round
        // that looks like local interference doesn't get to write
        // outage events or accelerate the cadence. See
        // `isLikelyLocalPingFailure`.
        let localInterference = isLikelyLocalPingFailure(checks)
        if localInterference {
            UIStateLogger.log(
                "ConnectivityViewModel",
                "every ping failed while DNS/HTTP succeeded — treating as local interference, not an outage"
            )
        } else {
            logTransitions(previous: previous, current: checks)
        }

        // Router/internet/DNS/HTTP (the ones Network Health actually shows)
        // plus infrastructure (SNMP-confirmed) devices — a managed switch or
        // AP going quiet is a real event worth the fast cadence too, unlike
        // the arbitrary "first 2 ARP entries" this used to consider before
        // `buildTargets` switched to SNMP-confirmed infrastructure targets
        // (see the comment there): those were dropped deliberately, since a
        // single sleeping/offline random host could pin this to the fast
        // interval indefinitely for something that isn't a real outage.
        let anyUnhealthy = !localInterference && checks.contains {
            (OverallStatus.criticalLabels.contains($0.label) || infrastructureLabels.contains($0.label)) && !$0.success
        }
        // On the very first sign of trouble, don't even wait out the fast
        // interval — every target is already checked together in one round,
        // so "speed up detection" means re-running that whole round right
        // away rather than 5s from now. This settles a full, current picture
        // of the outage sooner (e.g. a device whose ARP/DNS state is
        // momentarily stale right as the failure starts). Only on the
        // transition into failure, not every round an outage continues —
        // otherwise a real, ongoing outage would busy-loop at no delay
        // instead of settling into the fast interval.
        if anyUnhealthy, !wasUnhealthy {
            recheckRequested = true
        }
        wasUnhealthy = anyUnhealthy
        // Both scaled by the same divisor, so the 6:1 ratio between the
        // normal and fast cadence — itself a behaviour under test —
        // survives at any speed. See `FailureInjector.acceleratedInterval`.
        scheduleNextCheck(
            after: FailureInjector.acceleratedInterval(anyUnhealthy ? Self.fastCheckInterval : Self.checkInterval)
        )
        // Last, not first: mirrors `TracerouteViewModel.finishRun()` — the
        // round isn't really over until the next one is scheduled, and this
        // can immediately start a fresh round in its place.
        finishChecking()
    }

    /// Every ping-based check failed, while a check that *doesn't* use
    /// `ping` succeeded — the signature of something local interfering
    /// with the subprocesses rather than the network being down.
    ///
    /// Observed twice in one day, both times during a clean Xcode build:
    /// Router, Public IP, ISP Edge Router, Internet and every
    /// infrastructure device all reported unreachable in the same round,
    /// while DNS and HTTP stayed green — and everything recovered one
    /// second later. Each produced a complete, entirely fictional outage
    /// in the event log.
    ///
    /// The inference is sound rather than heuristic: DNS resolves a
    /// *random* subdomain precisely to defeat caching, and HTTP fetches a
    /// real remote host. Neither can succeed without a working network.
    /// So if either passes while every ICMP probe fails at once, the
    /// network is demonstrably up and the ping results are measuring
    /// something else — CPU starving the forked `ping` processes past
    /// their 1-2s timeouts, most likely, or ICMP being blocked outright.
    ///
    /// Requires at least two ping targets, so a minimal configuration
    /// with a single target can't trip this on one unlucky timeout.
    ///
    /// **The accepted trade-off:** if ICMP is genuinely blocked
    /// network-wide while DNS and HTTP keep working, this suppresses
    /// those outage events indefinitely. That's arguably the right
    /// answer — the network *is* working — but it means Network Health
    /// can show red rows with no corresponding events, so the reason is
    /// written to the state log rather than left silent.
    private func isLikelyLocalPingFailure(_ checks: [ConnectivityCheck]) -> Bool {
        var pingLabels = infrastructureLabels
        pingLabels.formUnion([
            OverallStatus.routerLabel,
            OverallStatus.publicIPLabel,
            OverallStatus.peRouterLabel,
            OverallStatus.internetLabel
        ])

        let pings = checks.filter { pingLabels.contains($0.label) }
        guard pings.count >= 2, pings.allSatisfy({ !$0.success }) else { return false }

        return checks.contains {
            ($0.label == OverallStatus.dnsLabel || $0.label == OverallStatus.httpLabel) && $0.success
        }
    }

    /// The single place a round ends, so a deferred recheck can't be missed
    /// on either completion path (the empty-targets early exit and the
    /// normal ping-results path both call this). Recursion is bounded to
    /// one extra round — the flag is cleared before re-entering.
    private func finishChecking() {
        isChecking = false
        guard recheckRequested else { return }
        recheckRequested = false
        runChecks()
    }

    /// Logs an event only for the router/internet/DNS/HTTP targets (not
    /// arbitrary LAN devices — out of scope for this log), and only on an
    /// actual transition: into failure, or back out of it. Not on every
    /// check while a state persists — otherwise a router down for an hour
    /// would produce one row per 30s check cycle instead of one row for the
    /// whole outage.
    private func logTransitions(previous: [ConnectivityCheck], current: [ConnectivityCheck]) {
        var loggedAny = false
        for check in current {
            let kinds: (failure: AppEventKind, recovery: AppEventKind)
            switch check.label {
            case OverallStatus.routerLabel: kinds = (.routerUnreachable, .routerReachable)
            case OverallStatus.internetLabel: kinds = (.internetUnreachable, .internetReachable)
            case OverallStatus.dnsLabel: kinds = (.dnsUnreachable, .dnsReachable)
            case OverallStatus.httpLabel: kinds = (.httpUnreachable, .httpReachable)
            case OverallStatus.peRouterLabel: kinds = (.peRouterUnreachable, .peRouterReachable)
            case OverallStatus.publicIPLabel: kinds = (.publicIPUnreachable, .publicIPReachable)
            case let label where infrastructureLabels.contains(label):
                kinds = (.infrastructureUnreachable, .infrastructureReachable)
            default: continue
            }

            let wasFailing = previous.first { $0.label == check.label }?.success == false

            if !check.success, !wasFailing {
                // No target/IP in the message — the label alone (Router,
                // Internet, DNS, HTTP) says what broke; the actual target
                // is already visible in Network Health, and dropping it
                // keeps this short enough to fit on one line.
                // Prefixed when forced, so a test outage is never
                // mistaken for a real one weeks later — see
                // `FailureInjector.messagePrefix`. Empty in every normal
                // case, and always empty in release builds.
                snapshotStore.logEvent(
                    kinds.failure,
                    message: "\(FailureInjector.messagePrefix(for: check.label))\(check.label) became unreachable"
                )
                loggedAny = true
                if check.label == OverallStatus.internetLabel {
                    onInternetUnreachable?()
                }
            } else if check.success, wasFailing {
                snapshotStore.logEvent(kinds.recovery, message: "\(check.label) reachable again")
                loggedAny = true
                if check.label == OverallStatus.internetLabel {
                    onInternetReachable?()
                }
            }
        }
        if loggedAny {
            onEventLogged?()
        }
    }

    private func buildTargets() -> [ConnectivityService.Target] {
        var targets: [ConnectivityService.Target] = []

        if let router = networkMonitor?.currentInterface?.routerAddress {
            // 1s, not the shared 2s default: unlike Internet/DNS/HTTP (WAN
            // round trips, where a legitimate response can genuinely take
            // longer), the local router should answer well under a second
            // on a healthy network — a longer wait here just delays
            // detecting a real problem.
            targets.append(ConnectivityService.Target(label: OverallStatus.routerLabel, host: router, timeoutSeconds: 1))
        }
        // Infrastructure (SNMP-confirmed) devices are far better ping
        // targets than the arbitrary "first 2 ARP entries" this used to
        // pick: a managed switch or AP going quiet is a real event, whereas
        // a random laptop from the ARP cache going to sleep is not. The
        // router already has its own dedicated check above, so it's skipped
        // here to avoid pinging it twice per round.
        let routerAddress = networkMonitor?.currentInterface?.routerAddress
        let infrastructure = (snmp?.devices ?? []).filter { $0.ipAddress != routerAddress }
        infrastructureLabels = Set(infrastructure.map(\.displayName))
        for device in infrastructure.prefix(Self.maxInfrastructureTargets) {
            targets.append(ConnectivityService.Target(label: device.displayName, host: device.ipAddress))
        }
        targets.append(ConnectivityService.Target(label: OverallStatus.internetLabel, host: Self.internetHost))
        // The confirmed ISP edge router, monitored by ping on this same
        // fast/reactive cadence — `TracerouteViewModel` only owns finding
        // and confirming *which* hop this is (discovery); actually
        // watching whether it's still reachable belongs here, not in a
        // full re-trace every time (much cheaper, and no longer tied to
        // traceroute's own much slower schedule).
        if let address = traceroute?.monitoredHopAddress {
            targets.append(ConnectivityService.Target(label: OverallStatus.peRouterLabel, host: address))
        }
        // The router's own public/WAN address — pinging it from inside the
        // LAN reaches the gateway's own local stack directly (verified: TTL
        // 64, sub-millisecond RTT — answered locally, not a real round trip
        // to the internet), so this specifically tests whether the WAN
        // side is alive, catching e.g. an ISP modem/ONT losing power that a
        // LAN-side-only check like Router above can't see.
        if let publicIPAddress = publicIP?.currentIP {
            targets.append(ConnectivityService.Target(label: OverallStatus.publicIPLabel, host: publicIPAddress, timeoutSeconds: 1))
        }

        logUnavailableInputs(targetCount: targets.count)
        return targets
    }

    /// Records which inputs weren't available when this round's targets were
    /// built. Every read in `buildTargets` is optional-chained with a silent
    /// fallback, so a dependency that isn't ready yet doesn't error — it just
    /// omits a row, and the omission then persists until the next timer tick.
    /// That is precisely how the ISP Edge Router row went missing for 30
    /// seconds at launch with nothing appearing wrong. Making the omission
    /// visible doesn't prevent it, but turns "why is that row absent?" into a
    /// line you can read.
    ///
    /// Only logged when something is actually missing, so a healthy round
    /// stays silent and this doesn't add a line every 30 seconds.
    private func logUnavailableInputs(targetCount: Int) {
        #if DEBUG
        var unavailable: [String] = []
        if networkMonitor?.currentInterface == nil { unavailable.append("interface") }
        if traceroute?.monitoredHopAddress == nil { unavailable.append("monitoredHop") }
        if (snmp?.devices ?? []).isEmpty { unavailable.append("snmpDevices") }
        if publicIP?.currentIP == nil { unavailable.append("publicIP") }
        guard !unavailable.isEmpty else { return }
        UIStateLogger.log(
            "ConnectivityViewModel.buildTargets",
            "\(targetCount) targets — unavailable: \(unavailable.joined(separator: ", "))"
        )
        #endif
    }
}
