import Foundation

/// Periodically resolves every user-configured DDNS hostname
/// (`FeatureFlags.ddnsHostnames`, set via `PreferencesView`) and compares
/// it against this Mac's own public IP — catching the real-world failure
/// where a DDNS client (on the router, a NAS, a cron job) silently stops
/// updating, and anything relying on that hostname (a VPN peer config, a
/// port-forwarded service, a friend's bookmark) becomes unreachable from
/// outside with nothing on this Mac visibly broken. See
/// `DDNSResolutionService` for why resolution goes through `dig` against
/// an explicit resolver rather than `getaddrinfo`.
///
/// Gated on more than just the hostname list being non-empty: checking
/// only runs while the current network is the one marked home (a button
/// in `KnownNetworksView`; see `SnapshotStore.isCurrentNetworkHome`).
/// Confirmed live (2026-08-04, off-site): without this, a hostname
/// configured for a home DDNS record reads `.stale` on every other
/// network it's checked from — technically correct (the record really
/// doesn't match a non-home network's public IP) but reads as a false
/// alarm, and worse, keeps displaying the home network's own DDNS setup
/// while connected somewhere else entirely. Away from home, `statuses`
/// just goes empty instead of comparing against the wrong network.
@MainActor
@Observable
final class DDNSViewModel {
    enum SyncState: Equatable {
        case current
        case stale
        /// The network is confirmed carrier-grade NAT'd — see
        /// `syncState(resolvedIP:publicIP:isCGNAT:)`'s doc comment for why
        /// this preempts a plain current/stale verdict rather than
        /// supplementing it.
        case blockedByCGNAT
    }

    struct Status: Identifiable, Equatable {
        var id: String { hostname }
        let hostname: String
        let resolvedIP: String?
        /// `nil` means "not yet determined" — either this Mac's own
        /// public IP isn't known yet, or the last resolution attempt
        /// failed (see `lastError`), not "checked and found in sync."
        let syncState: SyncState?
        let lastCheckedAt: Date?
        let lastError: String?
    }

    private(set) var statuses: [Status] = [] {
        didSet { UIStateLogger.log("DDNSViewModel.statuses", statuses) }
    }
    private(set) var isChecking = false

    /// Fired when an `AppEventRecord` gets logged, so the event log view
    /// can refresh — same convention every other view model here uses.
    var onEventLogged: (() -> Void)?

    private let service = DDNSResolutionService()
    private let snapshotStore: SnapshotStore
    private let publicIP: PublicIPViewModel
    private let traceroute: TracerouteViewModel
    private var timer: Timer?
    private var lastKnownHostnames: [FeatureFlags.DDNSHostname] = []
    private var lastKnownInterval: TimeInterval = FeatureFlags.ddnsCheckInterval
    /// Keyed by hostname, so each configured hostname's own transition is
    /// tracked independently — same shape
    /// `SaaSMonitoringViewModel.previousIndicators` uses per service.
    /// `nil` (absent key) means "no prior check this session," which
    /// deliberately logs nothing the first time a hostname resolves —
    /// same "don't report launch as a baseline" convention every other
    /// check in this app follows.
    private var lastKnownSyncStates: [String: SyncState] = [:]
    private var featureFlagObserver: NSObjectProtocol?

    init(snapshotStore: SnapshotStore, publicIP: PublicIPViewModel, traceroute: TracerouteViewModel) {
        self.snapshotStore = snapshotStore
        self.publicIP = publicIP
        self.traceroute = traceroute
        lastKnownHostnames = FeatureFlags.ddnsHostnames
        if !lastKnownHostnames.isEmpty {
            activate()
        }
        observeFeatureFlagChanges()
    }

    // `deinit` is nonisolated even on a `@MainActor` class -- reading
    // `@Observable`-tracked stored properties from it needs
    // `MainActor.assumeIsolated`, safe here since every instance of this
    // class is only ever created/held on the main actor (see
    // `NMSApp`/`ContentViewPreviewSupport`). `ObservableObject` didn't
    // surface this same diagnostic; `@Observable`'s macro-generated
    // accessors do.
    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            if let featureFlagObserver {
                NotificationCenter.default.removeObserver(featureFlagObserver)
            }
        }
    }

    /// Mirrors `SaaSMonitoringViewModel.activate()` — everything `init()`
    /// does inline, gated on hostnames actually being configured, factored
    /// out so a hostname being added live (see `observeFeatureFlagChanges`)
    /// runs the exact same startup sequence a fresh launch with one
    /// already configured would.
    private func activate() {
        timer = Timer.scheduledTimer(
            withTimeInterval: FailureInjector.acceleratedInterval(FeatureFlags.ddnsCheckInterval),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAll()
            }
        }
        checkAll()
    }

    private func deactivate() {
        timer?.invalidate()
        timer = nil
        statuses = []
    }

    /// Watches for the hostname list going empty ↔ non-empty (mirrors
    /// `SNMPViewModel.observeFeatureFlagChanges()`'s on/off shape), a
    /// change in *which* hostnames are configured while already active
    /// (mirrors `SaaSMonitoringViewModel`'s finer-grained branch for its
    /// own user-added sites), or a changed check interval (rebuilds the
    /// timer so a new interval takes effect immediately rather than
    /// waiting out whatever was left of the old one).
    private func observeFeatureFlagChanges() {
        featureFlagObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let hostnames = FeatureFlags.ddnsHostnames
            let interval = FeatureFlags.ddnsCheckInterval
            let isActive = self.timer != nil
            if !hostnames.isEmpty, !isActive {
                self.lastKnownHostnames = hostnames
                self.lastKnownInterval = interval
                self.activate()
            } else if hostnames.isEmpty, isActive {
                self.lastKnownHostnames = hostnames
                self.deactivate()
            } else if isActive, hostnames != self.lastKnownHostnames || interval != self.lastKnownInterval {
                self.lastKnownHostnames = hostnames
                self.lastKnownInterval = interval
                self.deactivate()
                self.activate()
            }
        }
    }

    /// Resolves every configured hostname concurrently and compares each
    /// against this Mac's current public IP. Callable directly (the
    /// Expert Mode window's own "check now" button), not just from the
    /// timer — mirrors `NetworkQualityViewModel.runQuickCheck`'s
    /// on-demand shape.
    func checkAll() {
        guard !isChecking else { return }
        let hostnames = FeatureFlags.ddnsHostnames
        guard !hostnames.isEmpty else {
            statuses = []
            return
        }
        // See this class's own doc comment for why: DDNS is otherwise the
        // one check in this app not scoped to the current network at all.
        guard snapshotStore.isCurrentNetworkHome() else {
            statuses = []
            return
        }

        isChecking = true
        let service = self.service
        let currentPublicIP = publicIP.currentIP
        let isCGNAT = TracerouteViewModel.includesConfirmedCGNAT(traceroute.hops)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolved = service.resolveAll(hostnames: hostnames.map(\.hostname))
            let now = Date()
            let results: [Status] = hostnames.map { entry in
                switch resolved[entry.hostname] {
                case .success(let ip):
                    let state = currentPublicIP.map {
                        Self.syncState(resolvedIP: ip, publicIP: $0, isCGNAT: isCGNAT)
                    }
                    return Status(hostname: entry.hostname, resolvedIP: ip, syncState: state, lastCheckedAt: now, lastError: nil)
                case .failure(let error):
                    return Status(hostname: entry.hostname, resolvedIP: nil, syncState: nil, lastCheckedAt: now, lastError: error.displayMessage)
                case nil:
                    return Status(hostname: entry.hostname, resolvedIP: nil, syncState: nil, lastCheckedAt: now, lastError: "Not checked")
                }
            }
            Task { @MainActor [weak self] in
                self?.isChecking = false
                self?.apply(results)
            }
        }
    }

    /// Decides what a resolved hostname's state actually means — pure and
    /// `nonisolated` so it's directly unit-testable with no live
    /// subprocess or `ModelContainer`, same testability discipline as
    /// `TracerouteViewModel.includesConfirmedCGNAT`/
    /// `ConnectivityViewModel.shouldSuppressAsLocalInterference`.
    ///
    /// CGNAT preempts the plain comparison rather than supplementing it:
    /// under CGNAT, this Mac's router can only ever report its own
    /// CGNAT-internal WAN address, never the real address shared across
    /// an ISP's customers — so even a "matching" DDNS record is still
    /// fundamentally wrong, not something to report as `.current`.
    nonisolated static func syncState(resolvedIP: String, publicIP: String, isCGNAT: Bool) -> SyncState {
        if isCGNAT { return .blockedByCGNAT }
        return resolvedIP == publicIP ? .current : .stale
    }

    private func apply(_ results: [Status]) {
        // Injected before anything else sees the results, same convention
        // ConnectivityViewModel.apply/SNMPViewModel.apply/
        // SaaSMonitoringViewModel.apply already follow — so the real
        // stale/current transition logic and event logging can be
        // exercised without waiting for or faking a genuine DDNS client
        // failure. No-op unless the debug defaults key is set; see
        // FailureInjector.applyDDNSChanges.
        let results = FailureInjector.applyDDNSChanges(to: results)
        statuses = results
        for result in results {
            guard let state = result.syncState else { continue }
            let previous = lastKnownSyncStates[result.hostname]
            defer { lastKnownSyncStates[result.hostname] = state }
            guard previous != state else { continue }
            // First-ever check for this hostname this session: nothing to
            // have "transitioned" from, so this deliberately logs nothing
            // — same convention `SaaSMonitoringViewModel.apply`'s
            // `previous == nil` guard follows.
            guard previous != nil else { continue }

            let prefix = FailureInjector.isDDNSForced(result.hostname) ? "[injected] " : ""
            let message: String
            let kind: AppEventKind
            switch state {
            case .blockedByCGNAT:
                kind = .ddnsBlockedByCGNAT
                message = "\(prefix)\(result.hostname): this network is behind carrier-grade NAT (CGNAT), so no DDNS record can point at a real, stable public IP here — contact your ISP about a static IP, or use a relay-based remote-access tool instead."
            case .stale:
                kind = .ddnsRecordStale
                message = "\(prefix)\(result.hostname) no longer points at this connection's public IP — the DDNS client responsible for updating it may have stopped working."
            case .current:
                kind = .ddnsRecordCurrent
                message = "\(result.hostname) is back in sync with this connection's public IP."
            }
            snapshotStore.logEvent(kind, message: message)
            onEventLogged?()
        }
    }
}
