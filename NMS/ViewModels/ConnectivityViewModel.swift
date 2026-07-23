import Foundation
import Combine

@MainActor
final class ConnectivityViewModel: ObservableObject {
    @Published private(set) var checks: [ConnectivityCheck] = []
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isChecking = false

    private let service = ConnectivityService()
    private let snapshotStore: SnapshotStore
    private weak var networkMonitor: NetworkMonitorViewModel?
    private weak var lanDiscovery: LANDiscoveryViewModel?
    private var timer: Timer?

    private static let checkInterval: TimeInterval = 30
    private static let internetHost = "1.1.1.1"
    private static let maxLocalDeviceTargets = 2

    init(networkMonitor: NetworkMonitorViewModel, lanDiscovery: LANDiscoveryViewModel, snapshotStore: SnapshotStore) {
        self.networkMonitor = networkMonitor
        self.lanDiscovery = lanDiscovery
        self.snapshotStore = snapshotStore
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runChecks()
            }
        }
        runChecks()
    }

    deinit {
        timer?.invalidate()
    }

    /// Runs a round of checks against the router, a couple of known local
    /// devices, and a known internet host. Pinging blocks for up to ~2s per
    /// target, so the actual `ping` calls happen off the main thread and
    /// only the result hops back to update published state.
    func runChecks() {
        guard !isChecking else { return }
        let targets = buildTargets()
        guard !targets.isEmpty else { return }

        isChecking = true
        let service = self.service
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let results = service.check(targets: targets)
            Task { @MainActor in
                self?.apply(results)
            }
        }
    }

    private func apply(_ results: [ConnectivityCheck]) {
        checks = snapshotStore.saveConnectivityChecks(results)
        lastCheckedAt = Date()
        isChecking = false
    }

    private func buildTargets() -> [ConnectivityService.Target] {
        var targets: [ConnectivityService.Target] = []

        if let router = networkMonitor?.currentInterface?.routerAddress {
            targets.append(ConnectivityService.Target(label: "Router", host: router))
        }
        for device in (lanDiscovery?.devices ?? []).prefix(Self.maxLocalDeviceTargets) {
            targets.append(ConnectivityService.Target(label: device.hostname ?? device.ipAddress, host: device.ipAddress))
        }
        targets.append(ConnectivityService.Target(label: "Internet", host: Self.internetHost))

        return targets
    }
}
