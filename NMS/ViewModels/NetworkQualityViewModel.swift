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
    private let snapshotStore: SnapshotStore

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
                let result = NetworkQualityResult(downloadMbps: downloadMbps, uploadMbps: uploadMbps, testedAt: Date())
                await Self.waitOutMinimumDuration(since: start)
                apply(result)
            } catch {
                await Self.waitOutMinimumDuration(since: start)
                lastError = error.localizedDescription
                isRunning = false
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
