import Foundation
import Combine

/// On-demand only, like `NetworkQualityViewModel`'s Cloudflare/Apple
/// tests — deliberately no timer, never wired into `NMSApp`'s launch-time
/// or topology-change kicks. A run generates real, deliberate network
/// load (that's the whole point — see `WiFiStressTestService`'s doc
/// comment), so it must never happen without the user explicitly asking.
@MainActor
final class WiFiStressTestViewModel: ObservableObject {
    @Published private(set) var isRunning = false {
        didSet { UIStateLogger.log("WiFiStressTestViewModel.isRunning", isRunning) }
    }
    @Published private(set) var lastError: String? {
        didSet { UIStateLogger.log("WiFiStressTestViewModel.lastError", lastError as Any) }
    }
    @Published private(set) var recentRuns: [WiFiStressTestRecord] = [] {
        didSet { UIStateLogger.log("WiFiStressTestViewModel.recentRuns", recentRuns) }
    }

    private let service = WiFiStressTestService()
    private let snapshotStore: SnapshotStore

    /// Real, empirically-checked concurrency defaults (see
    /// `PUNCHLIST.md`) — not user-configurable in v1. Wi-Fi's lower
    /// bandwidth ceiling saturates around ~20-30 concurrent streams;
    /// Ethernet's much higher (gigabit-class) ceiling needs more
    /// concurrency to meaningfully load it, which also happens to be a
    /// way to see whether this Mac's own CPU/fork-exec rate becomes the
    /// limiting factor before the network does — see `avgCPUPercent`/
    /// `peakCPUPercent` on each run.
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
                routerAddress: routerAddress,
                isWiFi: isWiFi,
                testedAt: Date()
            )
            snapshotStore.recordWiFiStressTestResult(result)
            recentRuns = snapshotStore.fetchWiFiStressTestHistory()
        }
    }
}
