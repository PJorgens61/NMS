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
    private var timer: Timer?

    private static let checkInterval: TimeInterval = 30
    private static let internetHost = "1.1.1.1"
    private static let dnsTestHost = "apple.com"
    private static let maxLocalDeviceTargets = 2

    /// Fired whenever an `AppEventRecord` gets logged (router/internet/DNS/
    /// HTTP became unreachable, or became reachable again), so the event
    /// log view can refresh.
    var onEventLogged: (() -> Void)?

    init(networkMonitor: NetworkMonitorViewModel, lanDiscovery: LANDiscoveryViewModel, snapshotStore: SnapshotStore) {
        self.networkMonitor = networkMonitor
        self.lanDiscovery = lanDiscovery
        self.snapshotStore = snapshotStore
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runChecks()
            }
        }
        runChecks()
    }

    deinit {
        timer?.invalidate()
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
        let targets = buildTargets()
        guard !targets.isEmpty else { return }

        isChecking = true
        let service = self.service
        let dnsService = self.dnsService
        let httpService = self.httpService
        let dnsTestHost = Self.dnsTestHost

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var results = service.check(targets: targets)
            results.append(Self.runDNSCheck(dnsService, host: dnsTestHost))

            Task { @MainActor in
                guard let self else { return }
                let httpResult = await Self.runHTTPCheck(httpService)
                results.append(httpResult)
                self.apply(results)
            }
        }
    }

    private static func runDNSCheck(_ service: DNSResolutionService, host: String) -> ConnectivityCheck {
        let checkedAt = Date()
        let start = Date()
        do {
            let addresses = try service.resolve(host)
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            return ConnectivityCheck(
                label: OverallStatus.dnsLabel, target: host,
                success: !addresses.isEmpty, latencyMs: elapsedMs, checkedAt: checkedAt
            )
        } catch {
            return ConnectivityCheck(label: OverallStatus.dnsLabel, target: host, success: false, latencyMs: nil, checkedAt: checkedAt)
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
            default: continue
            }

            let wasFailing = previous.first { $0.label == check.label }?.success == false

            if !check.success, !wasFailing {
                snapshotStore.logEvent(kinds.failure, message: "\(check.label) (\(check.target)) became unreachable")
                loggedAny = true
            } else if check.success, wasFailing {
                snapshotStore.logEvent(kinds.recovery, message: "\(check.label) (\(check.target)) reachable again")
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
        for device in (lanDiscovery?.devices ?? []).prefix(Self.maxLocalDeviceTargets) {
            targets.append(ConnectivityService.Target(label: device.hostname ?? device.ipAddress, host: device.ipAddress))
        }
        targets.append(ConnectivityService.Target(label: OverallStatus.internetLabel, host: Self.internetHost))

        return targets
    }
}
