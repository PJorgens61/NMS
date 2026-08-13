import Foundation

/// Requests and tracks FW (github.com/PJorgens61/FW) scans — what's
/// actually reachable on this Mac's own public IP from outside. Mirrors
/// `DDNSViewModel`'s shape closely: both are "test something about this
/// connection from the network's own perspective, only while the current
/// network is marked home" checks, gated the same way
/// (`snapshotStore.isCurrentNetworkHome()`).
///
/// `FeatureFlags.firewallVisibility` being on is the consent for
/// everything here, including the scheduled and SNMP-triggered scans —
/// same shape `saasMonitoring` already uses (the flag itself is the
/// opt-in, not a second per-run confirmation). Off, or unconfigured
/// (`FWClient(baseURLString:token:)` returns `nil`), this view model is
/// fully inert: no timer, no scans, `scanNow()` sets `lastError` and
/// returns.
@MainActor
@Observable
final class FirewallVisibilityViewModel {
    private(set) var latestScan: FirewallScanRecord?
    private(set) var history: [FirewallScanRecord] = []
    private(set) var isScanning = false
    private(set) var lastError: String?

    private let snapshotStore: SnapshotStore
    private var timer: Timer?
    private var featureFlagObserver: NSObjectProtocol?

    /// A scan run automatically at least this often, while the flag is on
    /// and the current network is home — on top of the on-demand button
    /// and the SNMP-triggered case below. Daily, not configurable yet:
    /// FW's own per-token rate limit is one scan per 10 seconds, so
    /// there's no real server-side reason to keep this tight; daily is
    /// enough to catch a firewall config drifting without scanning more
    /// than there's ever likely to be anything new to find.
    static let scheduledInterval: TimeInterval = 24 * 60 * 60

    /// Mirrors FW's own `docs/default-ports.md` — a curated set spanning
    /// macOS's built-in sharing services, common dev-server defaults left
    /// running unauthenticated, a few homelab admin ports, and the
    /// audio/video services this app's own users are likely to actually
    /// run (Roon ARC, Plex, Jellyfin/Emby). Keep in sync with that file
    /// if it changes — this is deliberately a copy, not a live fetch,
    /// since the point is testing a fixed, known-interesting set, not
    /// whatever FW happens to ship next.
    static let defaultPorts = [
        22, 5900, 3283, 445, 548, 631, 3689,
        6379, 27017, 9200, 5432, 3306, 11211, 3000, 5000, 8000, 8080,
        2375, 8123, 1883,
        55000, 32400, 8096,
        25565, 27015
    ]

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        if FeatureFlags.firewallVisibility {
            activate()
        }
        observeFeatureFlagChanges()
    }

    // `deinit` is nonisolated even on a `@MainActor` class -- see
    // `DDNSViewModel`'s own doc comment for why `MainActor.assumeIsolated`
    // is needed here rather than a plain synchronous body.
    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            if let featureFlagObserver {
                NotificationCenter.default.removeObserver(featureFlagObserver)
            }
        }
    }

    private func activate() {
        history = snapshotStore.fetchFirewallScanHistory()
        latestScan = history.first
        timer = Timer.scheduledTimer(withTimeInterval: FailureInjector.acceleratedInterval(Self.scheduledInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scanNow()
            }
        }
    }

    private func deactivate() {
        timer?.invalidate()
        timer = nil
        latestScan = nil
        history = []
        lastError = nil
    }

    /// Same on/off-watching shape `DDNSViewModel.observeFeatureFlagChanges`
    /// uses — a fresh install has this flag off, so this is what actually
    /// starts the feature the moment someone flips it on in Preferences,
    /// without a relaunch.
    private func observeFeatureFlagChanges() {
        featureFlagObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let isOn = FeatureFlags.firewallVisibility
            let isActive = self.timer != nil
            if isOn, !isActive {
                self.activate()
            } else if !isOn, isActive {
                self.deactivate()
            }
        }
    }

    /// The on-demand path — a button in the Firewall Visibility section.
    /// Also what the scheduled timer and `handleRouterSignal(_:)` below
    /// both call; there's only one scan flow, not a separate "manual"
    /// vs. "automatic" implementation.
    func scanNow() {
        guard !isScanning else { return }
        guard FeatureFlags.firewallVisibility else {
            lastError = "Firewall Visibility is off."
            return
        }
        guard snapshotStore.isCurrentNetworkHome() else {
            // Same reasoning `DDNSViewModel.checkAll()` gives for its own
            // identical guard: scanning from a coffee shop would test the
            // coffee shop's NAT, not anything this Mac's owner controls.
            lastError = "Only runs on your home network."
            return
        }
        guard let client = FWClient(baseURLString: FeatureFlags.firewallServerURL, token: FWKeychain.token()) else {
            lastError = FWClient.FWClientError.notConfigured.displayMessage
            return
        }

        isScanning = true
        lastError = nil
        Task { [weak self] in
            await self?.runScan(using: client)
        }
    }

    /// Called from `NMSApp`'s wiring when `SNMPViewModel` logs a
    /// `.snmpDeviceRestarted`/`.snmpDeviceSoftwareChanged` event — a
    /// router reboot or firmware change can silently reset or alter
    /// port-forwarding rules, so it's worth re-checking exposure. Not
    /// scoped to specifically the router's own address (nothing in
    /// `SNMPDevice` distinguishes "the router" from any other SNMP-
    /// monitored device today) — any monitored device's software
    /// changing on a home network is a reasonable-enough proxy for
    /// "something at the edge may have changed" to justify a scan,
    /// without inventing new cross-view-model plumbing to identify the
    /// gateway address specifically.
    func handleRouterSignal() {
        guard FeatureFlags.firewallVisibility else { return }
        scanNow()
    }

    private func runScan(using client: FWClient) async {
        do {
            var job = try await client.startScan(ports: Self.defaultPorts)
            // Bounded, not indefinite: a well-behaved server always
            // reaches `complete` within a few seconds for 128 ports (see
            // FW's own dial timeout/concurrency), so 30 polls at
            // poll_after_ms-driven spacing is generous headroom, not a
            // tight budget — this exists purely so a misbehaving or
            // unreachable server can't leave `isScanning` stuck on
            // forever.
            var attempts = 0
            while job.status != "complete", attempts < 30 {
                try await Task.sleep(nanoseconds: UInt64(job.pollAfterMs) * 1_000_000)
                job = try await client.pollJob(id: job.id)
                attempts += 1
            }
            guard job.status == "complete" else {
                lastError = "Scan didn't finish in time."
                isScanning = false
                return
            }
            apply(job)
        } catch let error as FWClient.FWClientError {
            lastError = error.displayMessage
        } catch {
            lastError = error.localizedDescription
        }
        isScanning = false
    }

    private func apply(_ job: FWClient.ScanJob) {
        let previous = latestScan
        let record = snapshotStore.recordFirewallScan(job)
        latestScan = record
        history.insert(record, at: 0)

        let (increased, decreased) = Self.diff(previous: previous?.results, current: record.results)
        for result in increased {
            snapshotStore.logEvent(
                .firewallExposureIncreased,
                message: "Port \(result.port) is now open on \(result.address) — it was closed or filtered on the previous scan."
            )
        }
        for result in decreased {
            snapshotStore.logEvent(
                .firewallExposureDecreased,
                message: "Port \(result.port) on \(result.address) is no longer open."
            )
        }
    }

    /// Pure and `static` so it's directly unit-testable with no live
    /// network call or `ModelContainer` — same testability discipline
    /// `DDNSViewModel.syncState`/`TracerouteViewModel.includesConfirmedCGNAT`
    /// follow. `previous == nil` (first-ever scan on this network) logs
    /// nothing, same "don't report launch as a baseline" convention every
    /// other diff-based check in this app already follows.
    nonisolated static func diff(previous: [FWClient.PortResult]?, current: [FWClient.PortResult]) -> (increased: [FWClient.PortResult], decreased: [FWClient.PortResult]) {
        guard let previous else { return ([], []) }
        func isOpen(_ result: FWClient.PortResult) -> Bool { result.state == "open" }

        func key(_ result: FWClient.PortResult) -> String { "\(result.address):\(result.port)" }
        let previousByKey = Dictionary(uniqueKeysWithValues: previous.map { (key($0), $0) })
        let currentByKey = Dictionary(uniqueKeysWithValues: current.map { (key($0), $0) })

        let increased = current.filter { result in
            guard isOpen(result) else { return false }
            let wasOpen = previousByKey[key(result)].map(isOpen) ?? false
            return !wasOpen
        }
        let decreased = previous.filter { result in
            guard isOpen(result) else { return false }
            let stillOpen = currentByKey[key(result)].map(isOpen) ?? false
            return !stillOpen
        }
        return (increased, decreased)
    }
}
