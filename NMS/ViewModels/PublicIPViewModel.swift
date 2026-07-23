import Foundation
import Combine

@MainActor
final class PublicIPViewModel: ObservableObject {
    @Published private(set) var currentIP: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isChecking = false

    private let service = PublicIPService()
    private let snapshotStore: SnapshotStore
    private var timer: Timer?

    /// Public IP mostly only changes on ISP lease renewal or a network
    /// switch (the latter already triggers an out-of-band check — see
    /// `NMSApp`), so this doesn't need connectivity-check-level frequency.
    private static let checkInterval: TimeInterval = 300

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        currentIP = snapshotStore.latestPublicIP()?.ipAddress
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.check()
            }
        }
        check()
    }

    deinit {
        timer?.invalidate()
    }

    /// `URLSession`'s async API suspends without blocking the main thread,
    /// so unlike the `ping`/`arp` shell-outs elsewhere in this app, this
    /// doesn't need a background queue hop.
    func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            do {
                let ip = try await service.fetch()
                apply(PublicIPInfo(ipAddress: ip, checkedAt: Date()))
            } catch {
                lastError = error.localizedDescription
                isChecking = false
            }
        }
    }

    private func apply(_ info: PublicIPInfo) {
        currentIP = info.ipAddress
        lastCheckedAt = info.checkedAt
        lastError = nil
        isChecking = false
        snapshotStore.recordPublicIPIfChanged(info)
    }
}
