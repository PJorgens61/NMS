import Foundation
import Combine

@MainActor
final class ConnectivityViewModel: ObservableObject {
    @Published private(set) var checks: [ConnectivityCheck] = []
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

    init(networkMonitor: NetworkMonitorViewModel, lanDiscovery: LANDiscoveryViewModel, traceroute: TracerouteViewModel, snapshotStore: SnapshotStore) {
        self.networkMonitor = networkMonitor
        self.lanDiscovery = lanDiscovery
        self.traceroute = traceroute
        self.snapshotStore = snapshotStore
        runChecks()
    }

    /// Set after init — `SNMPViewModel` depends on several view models that
    /// are themselves constructed alongside this one, so the reference is
    /// injected once the graph is fully built (see `NMSApp.init`).
    func attach(snmp: SNMPViewModel) {
        self.snmp = snmp
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
            Task { @MainActor in
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
        guard !isChecking else { return }
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
            if let address = traceroute?.monitoredHop?.address {
                results.append(ConnectivityCheck(label: OverallStatus.peRouterLabel, target: address, success: false, latencyMs: nil, checkedAt: now))
            }
            apply(results)
            return
        }

        let targets = buildTargets()
        guard !targets.isEmpty else {
            isChecking = false
            return
        }
        let service = self.service
        let dnsService = self.dnsService
        let httpService = self.httpService

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var results = service.check(targets: targets)
            results.append(Self.runDNSCheck(dnsService))

            Task { @MainActor in
                guard let self else { return }
                let httpResult = await Self.runHTTPCheck(httpService)
                results.append(httpResult)
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
        let previous = checks
        checks = snapshotStore.saveConnectivityChecks(results)
        lastCheckedAt = Date()
        isChecking = false
        logTransitions(previous: previous, current: checks)

        // Scoped to router/internet/DNS/HTTP specifically (the ones Network
        // Health actually shows) — not the LAN device checks also in
        // `checks`, since a single sleeping/offline LAN device could pin
        // this to the fast interval indefinitely for something that isn't
        // a real outage.
        let anyUnhealthy = checks.contains { OverallStatus.criticalLabels.contains($0.label) && !$0.success }
        scheduleNextCheck(after: anyUnhealthy ? Self.fastCheckInterval : Self.checkInterval)
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
                snapshotStore.logEvent(kinds.failure, message: "\(check.label) became unreachable")
                loggedAny = true
                if check.label == OverallStatus.internetLabel {
                    onInternetUnreachable?()
                }
            } else if check.success, wasFailing {
                snapshotStore.logEvent(kinds.recovery, message: "\(check.label) reachable again")
                loggedAny = true
            }
        }
        if loggedAny {
            onEventLogged?()
        }
    }

    private func buildTargets() -> [ConnectivityService.Target] {
        var targets: [ConnectivityService.Target] = []

        if let router = networkMonitor?.currentInterface?.routerAddress {
            targets.append(ConnectivityService.Target(label: OverallStatus.routerLabel, host: router))
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
        if let address = traceroute?.monitoredHop?.address {
            targets.append(ConnectivityService.Target(label: OverallStatus.peRouterLabel, host: address))
        }

        return targets
    }
}
