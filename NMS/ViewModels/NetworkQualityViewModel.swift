import Foundation
import Combine

/// On-demand only — deliberately no timer, unlike every other view model
/// in this app. `run()` is the sole entry point, triggered by a button
/// press, and must never be wired into `NMSApp`'s launch-time or
/// topology-change kicks the way other checks are: a run costs a real,
/// sizable transfer (50MB+ round trip), so it must never happen without
/// the user explicitly asking. See DESIGN-NOTES.md's "Network Quality"
/// section.
@MainActor
final class NetworkQualityViewModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var recentRuns: [NetworkQualityRecord] = []

    private let service = NetworkQualityService()
    private let appleService = AppleNetworkQualityService()
    private let snapshotStore: SnapshotStore

    var isAppleTestAvailable: Bool { AppleNetworkQualityService.isAvailable }

    /// A floor on how long the "Testing…" button state stays visible —
    /// purely cosmetic, and applied *after* both measurements already
    /// have their final values, so it never touches the actual timed
    /// transfers or the Mbps math derived from them. On a fast connection
    /// (observed directly: well under a second for 50MB round trip total)
    /// the real run finishes before a user can register that "Testing…"
    /// ever appeared, which reads as "did clicking that even do anything?"
    /// rather than as a fast, good result.
    private static let minimumVisibleDuration: TimeInterval = 0.5

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        recentRuns = snapshotStore.fetchNetworkQualityHistory()
    }

    /// Re-reads history scoped to whatever `currentNetworkFingerprint` is
    /// now — this `init` fetch above runs before the first LAN scan
    /// resolves which network we're on, so it comes back empty (or scoped
    /// to `nil`) and nothing re-ran it until now. Same shape as
    /// `DHCPLeaseViewModel.reloadHistory()`; wired to
    /// `NetworkIdentityViewModel.onNetworkRecognized` alongside it in
    /// `NMSApp`.
    func reloadHistory() {
        recentRuns = snapshotStore.fetchNetworkQualityHistory()
    }

    /// Clears a stale error left over from a run attempted during an
    /// outage, once the network is confirmed back up — called from
    /// `connectivity.onInternetReachable`. Reported directly: Ethernet
    /// reconnecting still showed "The Internet connection appears to be
    /// offline." until the user happened to click "Run Speed Test" again,
    /// long after that stopped being true.
    ///
    /// Deliberately does *not* re-run the test itself — a real, sizable
    /// transfer must never happen without the user explicitly asking, per
    /// this type's whole reason for being on-demand only (see the type's
    /// own doc comment). Only the now-stale error text is cleared; the
    /// same "stale-after-recovery" bug class `PublicIPViewModel` already
    /// had, just resolved by clearing here instead of re-fetching, since
    /// re-fetching would cost a real transfer this type must never spend
    /// without being asked.
    func clearStaleErrorOnRecovery() {
        guard !isRunning else { return }
        lastError = nil
    }

    /// Download and upload run sequentially, not concurrently — running
    /// both at once would have them contend for the same pipe and
    /// understate both numbers, which defeats the entire point of a
    /// speed test. Slower overall than running them in parallel, but the
    /// only way to get an accurate independent reading of each direction.
    func run() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        Task {
            let start = Date()
            do {
                let downloadMbps = try await service.measureDownload()
                let uploadMbps = try await service.measureUpload()
                let result = NetworkQualityResult(
                    downloadMbps: downloadMbps,
                    uploadMbps: uploadMbps,
                    downloadResponsivenessRPM: nil,
                    uploadResponsivenessRPM: nil,
                    baseRTTMs: nil,
                    source: .cloudflareEndpoint,
                    testedAt: Date()
                )
                await Self.waitOutMinimumDuration(since: start)
                apply(result)
            } catch {
                await Self.waitOutMinimumDuration(since: start)
                lastError = error.localizedDescription
                isRunning = false
            }
        }
    }

    /// Apple's `networkQuality`, for the RPM/responsiveness-under-load
    /// signal the Cloudflare path above can't produce — see
    /// `AppleNetworkQualityService`. Shares `isRunning` with `run()`
    /// rather than a second flag: running both at once would have them
    /// contend for the same link and understate both, the identical
    /// reasoning `run()` already applies to its own download/upload
    /// ordering.
    ///
    /// `interfaceName` comes from the caller (`ContentView`, reading
    /// `NetworkMonitorViewModel.currentInterface`) rather than a stored
    /// dependency here — this view model otherwise has zero coupling to
    /// interface state, and a single `String?` parameter isn't worth
    /// adding one just to avoid passing it in.
    func runAppleTest(interfaceName: String?) {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        let appleService = self.appleService
        let start = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = appleService.measure(interfaceName: interfaceName)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await Self.waitOutMinimumDuration(since: start)
                switch outcome {
                case let .success(measurement):
                    let result = NetworkQualityResult(
                        downloadMbps: measurement.downloadMbps,
                        uploadMbps: measurement.uploadMbps,
                        downloadResponsivenessRPM: measurement.downloadResponsivenessRPM,
                        uploadResponsivenessRPM: measurement.uploadResponsivenessRPM,
                        baseRTTMs: measurement.baseRTTMs,
                        source: .appleNetworkQuality,
                        testedAt: Date()
                    )
                    self.apply(result)
                case .failure(.unavailable):
                    self.lastError = "networkQuality not found — unavailable on this macOS version."
                    self.isRunning = false
                case let .failure(.processFailed(code)):
                    self.lastError = "networkQuality exited with status \(code)."
                    self.isRunning = false
                case .failure(.unparseable):
                    self.lastError = "networkQuality produced unreadable output."
                    self.isRunning = false
                }
            }
        }
    }

    private static func waitOutMinimumDuration(since start: Date) async {
        let remaining = minimumVisibleDuration - Date().timeIntervalSince(start)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    private func apply(_ result: NetworkQualityResult) {
        isRunning = false
        snapshotStore.recordNetworkQualityResult(result)
        recentRuns = snapshotStore.fetchNetworkQualityHistory()
    }
}
