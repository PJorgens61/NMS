import Foundation
import Combine

@MainActor
final class TracerouteViewModel: ObservableObject {
    @Published private(set) var hops: [TracerouteHop] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRunAt: Date?
    /// The hop number the user has confirmed as "the" router to monitor —
    /// persisted across launches. `nil` until they confirm one.
    @Published private(set) var monitoredHopNumber: Int?

    private let service = TracerouteService()
    private let snapshotStore: SnapshotStore
    private var timer: Timer?

    private static let target = "1.1.1.1"
    // Traceroute is much heavier than a ping or an HTTP lookup (up to 20
    // hops, each potentially waiting out a timeout), so this runs far less
    // often than connectivity checks or public-IP lookups. This view model
    // is purely discovery now — finding the path and letting you confirm
    // which hop is the ISP edge — not ongoing health monitoring of that
    // hop, which `ConnectivityViewModel` does by ping on its own much
    // faster/reactive cadence (see `OverallStatus.peRouterLabel`). That
    // split is deliberate: re-running a full multi-hop trace just to check
    // whether one already-known address still responds was both slow and
    // the wrong tool for the job.
    private static let runInterval: TimeInterval = 600
    private static let monitoredHopDefaultsKey = "NMS.monitoredHopNumber"

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        monitoredHopNumber = UserDefaults.standard.object(forKey: Self.monitoredHopDefaultsKey) as? Int
        timer = Timer.scheduledTimer(withTimeInterval: Self.runInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.run()
            }
        }
        run()
    }

    deinit {
        timer?.invalidate()
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        let service = self.service
        let target = Self.target
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let result = try service.trace(to: target)
                Task { @MainActor in
                    self?.apply(result)
                }
            } catch {
                Task { @MainActor in
                    self?.lastError = error.localizedDescription
                    self?.isRunning = false
                }
            }
        }
    }

    /// A suggestion only — the first non-RFC1918 hop. Reliable for a simple
    /// single-NAT home network (verified against a real home traceroute),
    /// but on a campus/enterprise network the organization's own border
    /// router often has a public IP long before traffic actually reaches
    /// the ISP, so this can point at the wrong hop. It's a starting point
    /// for you to confirm via `monitorHop(_:)`, not something to trust
    /// blindly on unfamiliar topologies.
    var suggestedEdgeHop: TracerouteHop? {
        hops.first { $0.isLocal == false }
    }

    /// The hop the user has actually confirmed, looked up fresh from the
    /// latest trace by hop number.
    var monitoredHop: TracerouteHop? {
        guard let monitoredHopNumber else { return nil }
        return hops.first { $0.hopNumber == monitoredHopNumber }
    }

    /// Confirms which hop is "the" router to monitor going forward, by
    /// position in the path. Pass `nil` to clear the selection and fall
    /// back to `suggestedEdgeHop`.
    func monitorHop(_ hopNumber: Int?) {
        monitoredHopNumber = hopNumber
        if let hopNumber {
            UserDefaults.standard.set(hopNumber, forKey: Self.monitoredHopDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.monitoredHopDefaultsKey)
        }
        persistMonitoredHopIfNeeded()
    }

    private func apply(_ result: [TracerouteHop]) {
        hops = result
        lastRunAt = Date()
        isRunning = false
        lastError = nil
        persistMonitoredHopIfNeeded()
    }

    /// Like `PublicIPRecord`, only persists a row when the monitored hop's
    /// address actually changed — a change timeline, not a per-run log.
    private func persistMonitoredHopIfNeeded() {
        guard let hop = monitoredHop, let address = hop.address else { return }
        snapshotStore.recordProviderEdgeIfChanged(address: address, hostname: hop.hostname)
    }
}
