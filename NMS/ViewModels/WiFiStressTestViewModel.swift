import Foundation

/// On-demand only, like `NetworkQualityViewModel`'s Cloudflare/Apple
/// tests — deliberately no timer, never wired into `NMSApp`'s launch-time
/// or topology-change kicks. A run generates real, deliberate network
/// load (that's the whole point — see `WiFiStressTestService`'s doc
/// comment), so it must never happen without the user explicitly asking.
@MainActor
@Observable
final class WiFiStressTestViewModel {
    private(set) var isRunning = false {
        didSet { UIStateLogger.log("WiFiStressTestViewModel.isRunning", isRunning) }
    }
    private(set) var lastError: String? {
        didSet { UIStateLogger.log("WiFiStressTestViewModel.lastError", lastError as Any) }
    }
    private(set) var recentRuns: [WiFiStressTestRecord] = [] {
        didSet { UIStateLogger.log("WiFiStressTestViewModel.recentRuns", recentRuns) }
    }

    private let service = WiFiStressTestService()
    private let snapshotStore: SnapshotStore

    /// Real, empirically-checked concurrency defaults (see
    /// `PUNCHLIST.md` and `WiFiStressTestService`'s own doc comment for
    /// the one-process-per-stream mechanism these were measured against).
    /// On this Mac's Wi-Fi, 24 streams reached ~4800 attempted pings/sec
    /// (~58 Mbps) at ~40% system-wide CPU, with real (if small, ~0.1%)
    /// packet loss starting to appear -- a genuine link-side signal, not
    /// this Mac's own fork/exec rate maxing out the way the old
    /// one-shot-per-packet design did by 200 streams. `ethernetStreamCount`
    /// is carried over unchanged from the old mechanism's tuning and
    /// still needs its own real-hardware Ethernet measurement (this Mac
    /// was Wi-Fi-connected for all of the above) -- see `PUNCHLIST.md`.
    static let wifiStreamCount = 24
    static let ethernetStreamCount = 100
    static let burstDuration: TimeInterval = 1.0

    /// One-time "this generates real traffic" acknowledgment — a plain
    /// view-model-owned `UserDefaults` key, not a `FeatureFlags` entry:
    /// this isn't an on/off feature to gate, just a confirmation that
    /// only needs to happen once, ever, the same way `FailureInjector`'s
    /// debug overrides live directly in `UserDefaults` rather than going
    /// through that enum.
    private static let hasConfirmedKey = "WiFiStressTestHasConfirmed"
    var hasConfirmedBefore: Bool { UserDefaults.standard.bool(forKey: Self.hasConfirmedKey) }
    func markConfirmed() { UserDefaults.standard.set(true, forKey: Self.hasConfirmedKey) }

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        recentRuns = snapshotStore.fetchWiFiStressTestHistory()
    }

    /// Re-reads history scoped to whatever `currentNetworkFingerprint` is
    /// now — this `init` fetch above runs before the first LAN scan
    /// resolves which network we're on, so it comes back empty (or scoped
    /// to `nil`) and nothing re-ran it until now. Same shape as
    /// `NetworkQualityViewModel.reloadHistory()`/`DHCPLeaseViewModel
    /// .reloadHistory()`; wired to `NetworkIdentityViewModel
    /// .onNetworkRecognized` alongside them in `NMSApp`.
    func reloadHistory() {
        recentRuns = snapshotStore.fetchWiFiStressTestHistory()
    }

    /// Fires the burst against `routerAddress` and persists the result.
    /// `isWiFi` picks which concurrency tier applies — see
    /// `wifiStreamCount`/`ethernetStreamCount`'s own doc comment.
    func run(routerAddress: String, isWiFi: Bool) {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        let streamCount = isWiFi ? Self.wifiStreamCount : Self.ethernetStreamCount
        Task {
            let stats = await service.runBurst(host: routerAddress, streamCount: streamCount, duration: Self.burstDuration)
            isRunning = false
            let result = WiFiStressTestResult(
                streamCount: streamCount,
                packetsSent: stats.packetsSent,
                packetsReceived: stats.packetsReceived,
                packetLossPercent: stats.packetLossPercent,
                minRTTMs: stats.minRTTMs,
                avgRTTMs: stats.avgRTTMs,
                maxRTTMs: stats.maxRTTMs,
                stddevRTTMs: stats.stddevRTTMs,
                peakCPUPercent: stats.peakCPUPercent,
                avgCPUPercent: stats.avgCPUPercent,
                packetsPerSecond: stats.packetsPerSecond,
                megabitsPerSecond: stats.megabitsPerSecond,
                routerAddress: routerAddress,
                isWiFi: isWiFi,
                testedAt: Date()
            )
            snapshotStore.recordWiFiStressTestResult(result)
            recentRuns = snapshotStore.fetchWiFiStressTestHistory()
        }
    }
}
