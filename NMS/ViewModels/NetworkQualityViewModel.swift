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
    /// Which source is currently running, `nil` if neither is — replaces a
    /// plain `isRunning: Bool` now that Cloudflare throughput and Apple's
    /// `networkQuality` live in separate tiles (`PUNCHLIST.md`'s "Give
    /// Apple's networkQuality its own tile"). Still exactly one flag, not
    /// two independent ones: the two sources still can't usefully run
    /// concurrently (see `run()`/`runAppleTest(interfaceName:)`'s own
    /// comments — they'd contend for the same link and understate both),
    /// so this stays the single source of truth for "is a test running at
    /// all," while also letting each tile show "Testing…" only when *it*
    /// is the one running, rather than both tiles claiming that at once.
    ///
    /// Instrumented for the UI state log — see BUGS.md's "Speed Test times
    /// out... with no telemetry to say why." Before this, a real timeout
    /// left no trace of which stage (probe or full transfer) was in
    /// flight, or how far it got, in `ui-state.log`/state dumps/bug
    /// reports — every other check in this app logs its running/error
    /// state this way already.
    @Published private(set) var runningSource: NetworkQualityResult.Source? {
        didSet { UIStateLogger.log("NetworkQualityViewModel.runningSource", runningSource?.rawValue as Any) }
    }
    @Published private(set) var lastError: String? {
        didSet { UIStateLogger.log("NetworkQualityViewModel.lastError", lastError as Any) }
    }
    @Published private(set) var recentRuns: [NetworkQualityRecord] = [] {
        didSet { UIStateLogger.log("NetworkQualityViewModel.recentRuns", recentRuns) }
    }

    /// The most recent Apple `networkQuality` run's full `-v` report, for
    /// the "View Full Report" button — raised directly, experts want more
    /// than this app's own summary. In-memory only, not persisted
    /// alongside `NetworkQualityRecord`: every historical run's full
    /// verbose text would be a meaningfully larger, unbounded-growth
    /// column for a detail nobody browses historically, only right after
    /// running it. Overwritten by each new run, `nil` again after a
    /// network change (`reloadHistory` doesn't touch this — it's tied to
    /// "the last thing this session actually ran," not per-network state).
    @Published private(set) var latestAppleVerboseOutput: String?

    /// Whether *either* source is running — the shared mutual-exclusion
    /// guard both `run()` and `runAppleTest(interfaceName:)` check, and
    /// what both tiles' buttons disable on, so starting one test always
    /// disables the other's button too.
    var isRunning: Bool { runningSource != nil }

    /// Cloudflare-endpoint runs only, newest first — what the Speed Test
    /// tile's history shows now that Apple's runs have their own tile and
    /// their own filtered list (`appleRuns`) instead of one shared,
    /// source-tagged feed.
    var cloudflareRuns: [NetworkQualityRecord] {
        recentRuns.filter { $0.source == NetworkQualityResult.Source.cloudflareEndpoint.rawValue }
    }

    /// Apple `networkQuality` runs only, newest first — see `cloudflareRuns`.
    var appleRuns: [NetworkQualityRecord] {
        recentRuns.filter { $0.source == NetworkQualityResult.Source.appleNetworkQuality.rawValue }
    }

    /// The popover's ~5s quick check — raised directly, for a business
    /// user who wants "is this OK for a call right now" without the full
    /// test's ~30s/GB-scale cost. Independent of `runningSource` — still
    /// mutually exclusive with both other sources (see `runQuickCheck`'s
    /// own doc comment), just tracked separately since it isn't one of
    /// the two `NetworkQualityResult.Source` cases `runningSource`
    /// itself is typed over.
    @Published private(set) var isRunningQuickCheck = false {
        didSet { UIStateLogger.log("NetworkQualityViewModel.isRunningQuickCheck", isRunningQuickCheck) }
    }
    @Published private(set) var quickCheckStatus: QuickCheckStatus?
    @Published private(set) var quickCheckError: String?
    /// Newest first, `.quickCheck`-source rows only — backs the merged
    /// Network tile's dot-history row (see `PUNCHLIST.md`'s "Network
    /// Health and Info tiles" item). `quickCheckStatus` above stays the
    /// separate, ephemeral "what did the very last run say" value the
    /// row's trailing text already used before this existed; this is
    /// additive, not a replacement.
    @Published private(set) var quickCheckHistory: [NetworkQualityRecord] = []

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
        quickCheckHistory = snapshotStore.fetchQuickCheckHistory()
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
        quickCheckHistory = snapshotStore.fetchQuickCheckHistory()
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
    ///
    /// Also guarded against the popover's quick check
    /// (`isRunningQuickCheck`) — three different tests, but all three
    /// contend for the same link, so any two running at once would
    /// understate/pollute both readings.
    func run() {
        guard !isRunning, !isRunningQuickCheck else { return }
        runningSource = .cloudflareEndpoint
        lastError = nil
        Task {
            let start = Date()
            do {
                let download = try await service.measureDownload()
                let upload = try await service.measureUpload()
                let result = NetworkQualityResult(
                    downloadMbps: download.mbps,
                    uploadMbps: upload.mbps,
                    downloadResponsivenessRPM: nil,
                    uploadResponsivenessRPM: nil,
                    combinedResponsivenessRPM: nil,
                    baseRTTMs: nil,
                    downloadBytesTransferred: download.bytes,
                    uploadBytesTransferred: upload.bytes,
                    source: .cloudflareEndpoint,
                    testedAt: Date()
                )
                await Self.waitOutMinimumDuration(since: start)
                apply(result)
            } catch {
                await Self.waitOutMinimumDuration(since: start)
                lastError = error.localizedDescription
                runningSource = nil
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
        guard !isRunning, !isRunningQuickCheck else { return }
        runningSource = .appleNetworkQuality
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
                        combinedResponsivenessRPM: nil,
                        baseRTTMs: measurement.baseRTTMs,
                        downloadBytesTransferred: measurement.downloadBytesTransferred,
                        uploadBytesTransferred: measurement.uploadBytesTransferred,
                        source: .appleNetworkQuality,
                        testedAt: Date()
                    )
                    self.latestAppleVerboseOutput = measurement.verboseOutput
                    self.apply(result)
                case .failure(.unavailable):
                    self.lastError = "networkQuality not found — unavailable on this macOS version."
                    self.runningSource = nil
                case let .failure(.processFailed(code)):
                    self.lastError = "networkQuality exited with status \(code)."
                    self.runningSource = nil
                case .failure(.unparseable):
                    self.lastError = "networkQuality produced unreadable output."
                    self.runningSource = nil
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
        runningSource = nil
        snapshotStore.recordNetworkQualityResult(result)
        recentRuns = snapshotStore.fetchNetworkQualityHistory()
    }

    /// The popover's own on-demand check — see `isRunningQuickCheck`'s
    /// doc comment for why this is guarded against `run()`/
    /// `runAppleTest(interfaceName:)` too, not just re-entrance against
    /// itself. No `waitOutMinimumDuration` floor the way the other two
    /// have: at a real ~5s runtime, there's no risk of finishing too fast
    /// to register as "it did something" the way a sub-second Cloudflare
    /// probe could.
    func runQuickCheck(interfaceName: String?) {
        guard !isRunning, !isRunningQuickCheck else { return }
        isRunningQuickCheck = true
        quickCheckError = nil
        let appleService = self.appleService
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = appleService.measureQuick(interfaceName: interfaceName)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunningQuickCheck = false
                switch outcome {
                case let .success(rpm):
                    self.quickCheckStatus = QuickCheckStatus(rpm: rpm)
                    // Persisted as its own `.quickCheck`-source row —
                    // see `NetworkQualityResult.Source.quickCheck`'s doc
                    // comment. Bypasses `apply(_:)` deliberately: that
                    // helper also clears `runningSource`, which this path
                    // never set in the first place (`isRunningQuickCheck`
                    // is its own flag).
                    let result = NetworkQualityResult(
                        downloadMbps: nil,
                        uploadMbps: nil,
                        downloadResponsivenessRPM: nil,
                        uploadResponsivenessRPM: nil,
                        combinedResponsivenessRPM: rpm,
                        baseRTTMs: nil,
                        downloadBytesTransferred: nil,
                        uploadBytesTransferred: nil,
                        source: .quickCheck,
                        testedAt: Date()
                    )
                    self.snapshotStore.recordNetworkQualityResult(result)
                    self.quickCheckHistory = self.snapshotStore.fetchQuickCheckHistory()
                case .failure(.unavailable):
                    self.quickCheckError = "networkQuality unavailable"
                case let .failure(.processFailed(code)):
                    self.quickCheckError = "check failed (status \(code))"
                case .failure(.unparseable):
                    self.quickCheckError = "check produced unreadable output"
                }
            }
        }
    }
}

/// A ~5s popover check's verdict — see
/// `AppleNetworkQualityService.measureQuick(interfaceName:)`. Thresholds
/// match the same RPM reference points already sourced for the Apple
/// networkQuality tile's own tooltip
/// (`ContentView+Window.rpmThresholdHelp`): above ~2000 is excellent,
/// under ~800 suggests bufferbloat — kept identical rather than inventing
/// a second set of cutoffs for what's fundamentally the same signal at a
/// shorter runtime.
enum QuickCheckStatus {
    case good(rpm: Int)
    case fair(rpm: Int)
    case poor(rpm: Int)

    init(rpm: Int) {
        switch rpm {
        case 2000...: self = .good(rpm: rpm)
        case 800..<2000: self = .fair(rpm: rpm)
        default: self = .poor(rpm: rpm)
        }
    }

    var rpm: Int {
        switch self {
        case let .good(rpm), let .fair(rpm), let .poor(rpm): return rpm
        }
    }

    var label: String {
        switch self {
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        }
    }
}
