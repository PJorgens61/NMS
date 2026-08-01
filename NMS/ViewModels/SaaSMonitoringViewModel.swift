import Foundation
import Combine

/// Periodically checks a small, fixed list of business SaaS services'
/// status pages — see `SaaSStatusService` and DESIGN-NOTES.md's "Business
/// SaaS monitoring". Deliberately independent of `ConnectivityViewModel`:
/// this is a WAN fetch to third parties on its own low-frequency cadence,
/// not another LAN reachability target, and (for this prototype) doesn't
/// feed `OverallStatus`/the menu-bar color at all — see the plan this
/// shipped from for why that's a deliberate scope cut, not an oversight.
@MainActor
final class SaaSMonitoringViewModel: ObservableObject {
    struct ServiceStatus: Identifiable {
        var id: String { name }
        let name: String
        let indicator: SaaSStatusService.Indicator
        let description: String
        /// See `SaaSStatusService.CheckResult.url` — always a real link:
        /// the specific incident's page when there is one, the general
        /// status page otherwise, regardless of current health.
        let url: String
    }

    @Published private(set) var statuses: [ServiceStatus] = [] {
        didSet { UIStateLogger.log("SaaSMonitoringViewModel.statuses", statuses) }
    }

    private let service = SaaSStatusService()
    private let snapshotStore: SnapshotStore
    private var timer: Timer?
    /// Resolved once at `init()` from `FeatureFlags.saasEnabledServices`
    /// — every service if that preference has never been customized,
    /// otherwise exactly the ones the user left checked (which can be
    /// empty). Same restart-to-apply convention as every other
    /// `FeatureFlags` read in this app; see that property's doc comment.
    private let activeServices: [SaaSStatusService.MonitoredService]
    /// Previous round's indicator per service name, so a transition (up →
    /// down, or back) logs once instead of every round a state persists —
    /// same convention every other event-logging check in this app
    /// follows. `nil` for a service not yet checked this launch, which is
    /// what lets the very first check stay silent (see `apply`).
    private var previousIndicators: [String: SaaSStatusService.Indicator] = [:]

    /// A third-party API on the other end, same reasoning
    /// `PublicIPViewModel.checkInterval` gives for its own 300s: politeness
    /// matters, and a status-page change doesn't need sub-minute detection
    /// the way a LAN outage does.
    private static let checkInterval: TimeInterval = 300

    /// Fired when an `AppEventRecord` gets logged (a service went down or
    /// recovered), so the event log view can refresh.
    var onEventLogged: (() -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        let allServices = SaaSStatusService.monitoredServices
        if let enabled = FeatureFlags.saasEnabledServices {
            activeServices = allServices.filter { enabled.contains($0.name) }
        } else {
            activeServices = allServices
        }
        // Inert if the flag is off — no timer, no checks, not just a
        // hidden UI section. Same convention as `SNMPViewModel.init()`:
        // this reaches out to third parties periodically, which a fresh
        // install shouldn't do without explicit opt-in.
        guard FeatureFlags.saasMonitoring else { return }
        // Accelerated by NMSPollSpeedup like the connectivity/SNMP/DHCP/
        // traceroute timers, unlike PublicIPViewModel's (whose cadence is
        // "partly politeness," nothing testable depends on its
        // frequency). This one's worth speeding up: combined with
        // FailureInjector.applySaaSChanges, it's what makes the down/
        // recovery transition actually observable in a scripted test
        // instead of waiting up to 300s for the next real tick.
        timer = Timer.scheduledTimer(withTimeInterval: FailureInjector.acceleratedInterval(Self.checkInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAll()
            }
        }
        checkAll()
    }

    deinit {
        timer?.invalidate()
    }

    /// Checks every monitored service concurrently — same task-group
    /// shape as `ConnectivityService.check(targets:)`, so three WAN
    /// fetches are bounded by the slowest one, not their sum. A single
    /// service's fetch failing (timeout, malformed JSON, a non-200) is
    /// reported as `.unknown` for that service alone rather than losing
    /// the whole round — one flaky status page shouldn't hide the other
    /// two.
    func checkAll() {
        let service = self.service
        let services = activeServices
        Task { @MainActor [weak self] in
            let results = await withTaskGroup(of: (offset: Int, status: ServiceStatus).self) { group in
                for (index, monitored) in services.enumerated() {
                    group.addTask {
                        do {
                            let result = try await service.checkStatus(monitored)
                            return (index, ServiceStatus(name: monitored.name, indicator: result.indicator, description: result.description, url: result.url))
                        } catch {
                            // Still a real link, same reasoning as every
                            // other fallback here: this Mac failing to
                            // reach the endpoint says nothing about
                            // whether the status page itself is up.
                            let fallbackURL = SaaSStatusService.generalStatusPageURL(for: monitored)
                            return (index, ServiceStatus(name: monitored.name, indicator: .unknown, description: "Could not check status", url: fallbackURL))
                        }
                    }
                }
                var ordered = [ServiceStatus?](repeating: nil, count: services.count)
                for await result in group {
                    ordered[result.offset] = result.status
                }
                return ordered.compactMap { $0 }
            }
            self?.apply(results)
        }
    }

    private func apply(_ results: [ServiceStatus]) {
        // Injected before anything else sees the results, same convention
        // ConnectivityViewModel.apply/SNMPViewModel.apply already follow —
        // so persistence, event transitions, and the UI all react exactly
        // as they would to a real outage. No-op unless the debug defaults
        // key is set; see FailureInjector.
        let results = FailureInjector.applySaaSChanges(to: results)
        statuses = results
        var loggedAny = false
        for result in results {
            if let previous = previousIndicators[result.name] {
                let wasDown = previous != .none
                let isDown = result.indicator != .none
                if isDown, !wasDown {
                    let prefix = FailureInjector.isSaaSForced(result.name) ? "[injected] " : ""
                    // The URL is appended right in the message — this
                    // event record is the durable, findable copy (the
                    // live status row disappears the moment the service
                    // recovers), so it's the one place a link needs to
                    // survive for later reading.
                    snapshotStore.logEvent(.saasServiceDown, message: "\(prefix)\(result.name): \(result.description) (\(result.url))")
                    loggedAny = true
                } else if !isDown, wasDown {
                    snapshotStore.logEvent(.saasServiceRecovered, message: "\(result.name) recovered")
                    loggedAny = true
                }
            }
            // `previous == nil` (first check for this service this
            // launch) deliberately logs nothing — same "don't report
            // launch as a baseline" convention every other check in this
            // app follows (e.g. `DHCPLeaseViewModel`'s `isFirstEver`).
            previousIndicators[result.name] = result.indicator
        }
        if loggedAny {
            onEventLogged?()
        }
    }
}
