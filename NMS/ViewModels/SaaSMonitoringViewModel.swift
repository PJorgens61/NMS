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
    }

    @Published private(set) var statuses: [ServiceStatus] = [] {
        didSet { UIStateLogger.log("SaaSMonitoringViewModel.statuses", statuses) }
    }

    private let service = SaaSStatusService()
    private let snapshotStore: SnapshotStore
    private var timer: Timer?
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
        // Inert if the flag is off — no timer, no checks, not just a
        // hidden UI section. Same convention as `SNMPViewModel.init()`:
        // this reaches out to third parties periodically, which a fresh
        // install shouldn't do without explicit opt-in.
        guard FeatureFlags.saasMonitoring else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
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
        let services = SaaSStatusService.monitoredServices
        Task { @MainActor [weak self] in
            let results = await withTaskGroup(of: (offset: Int, status: ServiceStatus).self) { group in
                for (index, monitored) in services.enumerated() {
                    group.addTask {
                        do {
                            let result = try await service.checkStatus(monitored)
                            return (index, ServiceStatus(name: monitored.name, indicator: result.indicator, description: result.description))
                        } catch {
                            return (index, ServiceStatus(name: monitored.name, indicator: .unknown, description: "Could not check status"))
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
        statuses = results
        var loggedAny = false
        for result in results {
            if let previous = previousIndicators[result.name] {
                let wasDown = previous != .none
                let isDown = result.indicator != .none
                if isDown, !wasDown {
                    snapshotStore.logEvent(.saasServiceDown, message: "\(result.name): \(result.description)")
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
