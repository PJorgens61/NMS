import Foundation

/// Periodically checks a small, fixed list of business SaaS services'
/// status pages — see `SaaSStatusService` and DESIGN-NOTES.md's "Business
/// SaaS monitoring". Deliberately independent of `ConnectivityViewModel`:
/// this is a WAN fetch to third parties on its own low-frequency cadence,
/// not another LAN reachability target, and (for this prototype) doesn't
/// feed `OverallStatus`/the menu-bar color at all — see the plan this
/// shipped from for why that's a deliberate scope cut, not an oversight.
@MainActor
@Observable
final class SaaSMonitoringViewModel {
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

    private(set) var statuses: [ServiceStatus] = [] {
        didSet { UIStateLogger.log("SaaSMonitoringViewModel.statuses", statuses) }
    }
    /// The user's own added sites (Preferences), checked for plain
    /// reachability — deliberately a separate list from `statuses`
    /// above, not merged in, so the UI can render them visually distinct
    /// from the curated table. See `checkUserAddedSites`'s doc comment
    /// for why.
    private(set) var userAddedStatuses: [ServiceStatus] = [] {
        didSet { UIStateLogger.log("SaaSMonitoringViewModel.userAddedStatuses", userAddedStatuses) }
    }

    private let service = SaaSStatusService()
    private let snapshotStore: SnapshotStore
    private var timer: Timer?
    /// Re-read on every `checkAll()` round rather than resolved once —
    /// `nil` from `FeatureFlags.saasEnabledServices` means every service
    /// (never customized), otherwise exactly the ones left checked (which
    /// can be empty). A computed property rather than a stored `let` is
    /// what lets `checkAll()` read the current selection with no separate
    /// plumbing; `observeFeatureFlagChanges` is what makes a changed
    /// selection actually trigger a fresh round immediately, rather than
    /// only being correct whenever the next scheduled round happened to
    /// land.
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
    /// Same reasoning as `isActive`, one level down: lets
    /// `observeFeatureFlagChanges` tell an actual change to *which*
    /// services are enabled from the notification firing for an unrelated
    /// key. Without this, `activeServices` being a computed property was
    /// only "live" in the sense of being correct on the *next* scheduled
    /// round — a real gap, since nothing prompted an immediate one the
    /// way toggling the feature on/off already does via `activate()`.
    private var lastKnownEnabledServices: Set<String>?
    /// Same reasoning as `lastKnownEnabledServices`, for the user-added
    /// site list instead of the curated selection.
    private var lastKnownUserAddedSites: [FeatureFlags.UserAddedSaaSSite] = []
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
    /// Same reasoning as `isChecking`, for `checkUserAddedSites`'s own
    /// independent task group.
    private var isCheckingUserAdded = false

    /// A third-party API on the other end, same reasoning
    /// `PublicIPViewModel.checkInterval` gives for its own 300s: politeness
    /// matters, and a status-page change doesn't need sub-minute detection
    /// the way a LAN outage does.
    private static let checkInterval: TimeInterval = 300

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

    // `deinit` is nonisolated even on a `@MainActor` class -- reading
    // `@Observable`-tracked stored properties from it needs
    // `MainActor.assumeIsolated`, safe here since every instance of this
    // class is only ever created/held on the main actor (see `NMSApp`).
    // `ObservableObject` didn't surface this same diagnostic;
    // `@Observable`'s macro-generated accessors do.
    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            if let featureFlagObserver {
                NotificationCenter.default.removeObserver(featureFlagObserver)
            }
        }
    }

    /// Everything `init()` used to do inline, gated on the flag being on —
    /// factored out so toggling the flag on live (see
    /// `observeFeatureFlagChanges`) runs the exact same startup sequence a
    /// fresh launch would. Mirrors `SNMPViewModel.activate()`.
    private func activate() {
        isActive = true
        lastKnownEnabledServices = FeatureFlags.saasEnabledServices
        lastKnownUserAddedSites = FeatureFlags.userAddedSaaSSites
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
                self?.checkUserAddedSites()
            }
        }
        checkAll()
        checkUserAddedSites()
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

    /// See `SNMPViewModel.observeFeatureFlagChanges()` for the base
    /// reasoning — identical shape, watching `FeatureFlags.saasMonitoring`
    /// for the on/off flip. Extended one step further here, since this
    /// view model has a second, finer-grained live preference
    /// `SNMPViewModel` doesn't: *which* services are enabled. `activate()`
    /// already re-checks immediately when the feature turns on, so the
    /// `else if` below only needs to cover the case where the feature was
    /// already on and just the selection changed — an `else if`, not a
    /// separate `if`, specifically so a simultaneous "turn on" doesn't
    /// also trigger this branch and run `checkAll()` twice in one event.
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
            } else if self.isActive, FeatureFlags.saasEnabledServices != self.lastKnownEnabledServices {
                self.lastKnownEnabledServices = FeatureFlags.saasEnabledServices
                self.checkAll()
            } else if self.isActive, FeatureFlags.userAddedSaaSSites != self.lastKnownUserAddedSites {
                self.lastKnownUserAddedSites = FeatureFlags.userAddedSaaSSites
                self.checkUserAddedSites()
            }
        }
    }

    /// How many `checkStatus` calls run at once, shared by `checkAll()`
    /// and `checkUserAddedSites()`. Added 2026-08-08, alongside the same
    /// day's `SNMPService.sweepConcurrency` reduction — see that
    /// constant's own doc comment for the real iMac hang that motivated
    /// both. `checkAll()`'s own built-in list is a fixed, small 17
    /// entries, never the standout risk here on its own; `checkUserAddedSites()`
    /// has no such ceiling at all today — a user could add an unbounded
    /// number of sites in Preferences, each fetched via `URLSession
    /// .shared.data(for:)`, which always buffers the *entire* response
    /// body regardless of `.reachabilityOnly` only needing the status
    /// code (see `GitHub#18`) — so an unbounded fan-out there is the more
    /// plausible risk of the two, not just a symmetry choice.
    private static let maxConcurrentChecks = 8

    /// Runs `checkStatus` for every item in `services`, at most
    /// `maxConcurrentChecks` at a time, returning results in the same
    /// order as `services` — same ordered-by-offset shape `checkAll()`/
    /// `checkUserAddedSites()` both already used before this was factored
    /// out, just with a real ceiling on how many run at once instead of
    /// firing the whole list into one `TaskGroup` immediately. Refills a
    /// task as soon as one finishes, not in fixed batches, so a handful of
    /// slow services can't stall the rest behind them the way waiting for
    /// a whole batch to complete would.
    private static func checkBounded(
        _ items: [SaaSStatusService.MonitoredService],
        service: SaaSStatusService,
        onFailure: @escaping (SaaSStatusService.MonitoredService) -> ServiceStatus
    ) async -> [ServiceStatus] {
        await withTaskGroup(of: (offset: Int, status: ServiceStatus).self) { group in
            var nextIndex = 0
            func addNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                let item = items[index]
                nextIndex += 1
                group.addTask {
                    do {
                        let result = try await service.checkStatus(item)
                        return (index, ServiceStatus(name: item.name, indicator: result.indicator, description: result.description, url: result.url))
                    } catch {
                        return (index, onFailure(item))
                    }
                }
            }
            for _ in 0..<min(maxConcurrentChecks, items.count) { addNext() }
            var ordered = [ServiceStatus?](repeating: nil, count: items.count)
            for await result in group {
                ordered[result.offset] = result.status
                addNext()
            }
            return ordered.compactMap { $0 }
        }
    }

    /// Checks every monitored service concurrently, bounded by
    /// `maxConcurrentChecks` — same task-group shape as
    /// `ConnectivityService.check(targets:)`, so three WAN fetches are
    /// bounded by the slowest one, not their sum. A single service's
    /// fetch failing (timeout, malformed JSON, a non-200) is reported as
    /// `.unknown` for that service alone rather than losing the whole
    /// round — one flaky status page shouldn't hide the other
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
            let results = await Self.checkBounded(services, service: service) { monitored in
                // Still a real link, same reasoning as every other
                // fallback here: this Mac failing to reach the endpoint
                // says nothing about whether the status page itself is up.
                let fallbackURL = SaaSStatusService.generalStatusPageURL(for: monitored)
                return ServiceStatus(name: monitored.name, indicator: .unknown, description: "Could not check status", url: fallbackURL)
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
        for result in results {
            if let previous = previousIndicators[result.name] {
                let wasDown = previous != .none
                let isDown = result.indicator != .none
                if isDown, !wasDown {
                    let prefix = FailureInjector.isSaaSForced(result.name) ? "[injected] " : ""
                    // Carried as `url:`, not baked into `message` as
                    // trailing text — this event record is the durable,
                    // findable copy (the live status row disappears the
                    // moment the service recovers), so it's the one place
                    // a link needs to survive for later reading, and a
                    // real field lets it render as an actual clickable
                    // link instead of text `eventRows` would truncate.
                    snapshotStore.logEvent(.saasServiceDown, message: "\(prefix)\(result.name): \(result.description)", url: result.url)
                } else if !isDown, wasDown {
                    snapshotStore.logEvent(.saasServiceRecovered, message: "\(result.name) recovered")
                }
            }
            // `previous == nil` (first check for this service this
            // launch) deliberately logs nothing — same "don't report
            // launch as a baseline" convention every other check in this
            // app follows (e.g. `DHCPLeaseViewModel`'s `isFirstEver`).
            previousIndicators[result.name] = result.indicator
        }
    }

    /// Checks the user's own added sites (Preferences) for plain
    /// reachability — deliberately separate from `checkAll()`/`apply()`
    /// above rather than merged into the curated list's task group, for
    /// a real reason, not just code organization: per DESIGN-NOTES.md's
    /// "Does this vary by network?", a vendor's own status-page result
    /// is a global fact (true everywhere at once), but a plain
    /// reachability check to an arbitrary site is genuinely
    /// network-dependent — a restrictive office network or a captive
    /// portal can make this fail with nothing actually wrong with the
    /// site itself. Logging an Events entry the way `apply()` does for
    /// the curated list would risk exactly the misreport DESIGN-NOTES.md
    /// warned about: "blocked here" read as "this site is down," then
    /// "recovered" once roaming to a network where it was never blocked
    /// — a false transition pair for a site that never actually changed.
    /// So this never logs anything and never tracks a previous-indicator
    /// transition; `userAddedStatuses` is purely a live, in-the-moment
    /// reading.
    ///
    /// Reuses `SaaSStatusService.checkStatus` for the actual fetch (via
    /// the `.reachabilityOnly` shape) — same task-group shape as
    /// `checkAll()`, just without the parts that shape doesn't need.
    func checkUserAddedSites() {
        guard !isCheckingUserAdded else { return }
        let sites = FeatureFlags.userAddedSaaSSites
        guard !sites.isEmpty else {
            userAddedStatuses = []
            return
        }
        let monitored = sites.compactMap { site -> SaaSStatusService.MonitoredService? in
            guard let url = URL(string: site.url) else { return nil }
            return SaaSStatusService.MonitoredService(name: site.nickname, endpoint: url, shape: .reachabilityOnly)
        }
        isCheckingUserAdded = true
        let service = self.service
        Task { @MainActor [weak self] in
            let results = await Self.checkBounded(monitored, service: service) { site in
                ServiceStatus(name: site.name, indicator: .unknown, description: "Not reachable", url: site.endpoint.absoluteString)
            }
            self?.isCheckingUserAdded = false
            self?.userAddedStatuses = results
        }
    }
}
