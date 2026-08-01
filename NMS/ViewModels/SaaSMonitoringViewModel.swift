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
    /// Re-read on every `checkAll()` round rather than resolved once —
    /// `nil` from `FeatureFlags.saasEnabledServices` means every service
    /// (never customized), otherwise exactly the ones left checked (which
    /// can be empty). A computed property rather than a stored `let`
    /// specifically so a live change to the Preferences picker is picked
    /// up by the *next* round automatically, with no separate live-update
    /// plumbing needed — `checkAll()` already re-reads this fresh every
    /// time it runs.
    private var activeServices: [SaaSStatusService.MonitoredService] {
        let allServices = SaaSStatusService.monitoredServices
        guard let enabled = FeatureFlags.saasEnabledServices else { return allServices }
        return allServices.filter { enabled.contains($0.name) }
    }
    /// So `observeFeatureFlagChanges` can tell a real flip of
    /// `FeatureFlags.saasMonitoring` from `UserDefaults.didChangeNotification`
    /// firing for an unrelated key — see `SNMPViewModel`'s identical
    /// property for the full reasoning, mirrored here.
    private var isActive = false
    private var featureFlagObserver: NSObjectProtocol?
    /// Previous round's indicator per service name, so a transition (up →
    /// down, or back) logs once instead of every round a state persists —
    /// same convention every other event-logging check in this app
    /// follows. `nil` for a service not yet checked this launch, which is
    /// what lets the very first check stay silent (see `apply`).
    private var previousIndicators: [String: SaaSStatusService.Indicator] = [:]
    /// Whether a round is already in flight — see `checkAll` for the real
    /// race this closes. Every other periodic-check view model in this
    /// app (`ConnectivityViewModel`, `SNMPViewModel`, `LANDiscoveryViewModel`,
    /// `NetworkQualityViewModel`, `PublicIPViewModel`, `DHCPLeaseViewModel`)
    /// already guards this way; this one didn't.
    private var isChecking = false

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
        if FeatureFlags.saasMonitoring {
            activate()
        }
        observeFeatureFlagChanges()
    }

    deinit {
        timer?.invalidate()
        if let featureFlagObserver {
            NotificationCenter.default.removeObserver(featureFlagObserver)
        }
    }

    /// Everything `init()` used to do inline, gated on the flag being on —
    /// factored out so toggling the flag on live (see
    /// `observeFeatureFlagChanges`) runs the exact same startup sequence a
    /// fresh launch would. Mirrors `SNMPViewModel.activate()`.
    private func activate() {
        isActive = true
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

    /// The flag flipping off live, mirroring `activate()`. Stops the
    /// timer — no further outbound requests to any third party, the
    /// actual reason this is off by default — but leaves `statuses` as
    /// whatever it last reported rather than clearing it, same reasoning
    /// `SNMPViewModel.deactivate()` gives for its own device list: this
    /// data was legitimately fetched while the feature was on, and
    /// blanking it the instant someone unchecks a box reads as data loss,
    /// not as the feature turning off.
    private func deactivate() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }

    /// See `SNMPViewModel.observeFeatureFlagChanges()` for the full
    /// reasoning — identical shape, watching `FeatureFlags.saasMonitoring`
    /// instead.
    private func observeFeatureFlagChanges() {
        featureFlagObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let shouldBeActive = FeatureFlags.saasMonitoring
            if shouldBeActive, !self.isActive {
                self.activate()
            } else if !shouldBeActive, self.isActive {
                self.deactivate()
            }
        }
    }

    /// Checks every monitored service concurrently — same task-group
    /// shape as `ConnectivityService.check(targets:)`, so three WAN
    /// fetches are bounded by the slowest one, not their sum. A single
    /// service's fetch failing (timeout, malformed JSON, a non-200) is
    /// reported as `.unknown` for that service alone rather than losing
    /// the whole round — one flaky status page shouldn't hide the other
    /// two.
    ///
    /// **Overlapping rounds are dropped, not queued.** Reasoned through
    /// rather than hit live: under `NMSPollSpeedup`, `checkInterval` can
    /// shrink below the time three concurrent WAN fetches actually take,
    /// letting a second round start while the first is still in flight.
    /// With no ordering guarantee between two rounds' real network
    /// fetches, the older round's `apply(_:)` could land *after* the
    /// newer one's — overwriting fresher `previousIndicators` state with
    /// stale data, which can spuriously re-log a transition that already
    /// happened or silently swallow a real one. The next timer tick
    /// re-checks regardless, so dropping a round here is harmless.
    func checkAll() {
        guard !isChecking else { return }
        isChecking = true
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
            self?.isChecking = false
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
