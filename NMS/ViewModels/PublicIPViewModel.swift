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

    /// Fired when an `AppEventRecord` gets logged (public IP changed), so
    /// the event log view can refresh.
    var onEventLogged: (() -> Void)?

    /// Fired when `currentIP` actually changes — including nil → a value,
    /// which is the case that matters most.
    ///
    /// `ConnectivityViewModel.buildTargets` reads `publicIP?.currentIP` to
    /// decide whether to include the Public IP ping target, and `check()` is
    /// an async network fetch, so the target is simply absent from every
    /// round until it resolves. Observed directly: absent for the first two
    /// check rounds at launch, present only at the third — 30 seconds later,
    /// once the periodic timer happened to recompute targets rather than
    /// anything actually noticing `check()` had finished. This is the fourth
    /// instance of the same shape (`traceroute.monitoredHop`,
    /// `snmp.devices`, now this) — every optional-chained dependency
    /// `ConnectivityViewModel.buildTargets` reads is now covered by exactly
    /// this kind of edge.
    var onCurrentIPChanged: (() -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        currentIP = snapshotStore.latestPublicIP()?.ipAddress
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
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
        // Captured before `currentIP` is overwritten below — `nil` means
        // this is a genuinely first-ever check (nothing to compare
        // against yet, so no event), handled by the `let previousIP` guard
        // below. Only used as an existence check now; the message itself
        // only reports the new value, not the old one, to keep it short.
        let previousIP = currentIP
        currentIP = info.ipAddress
        lastCheckedAt = info.checkedAt
        lastError = nil
        isChecking = false

        if previousIP != currentIP {
            onCurrentIPChanged?()
        }

        let changed = snapshotStore.recordPublicIPIfChanged(info)
        if changed, previousIP != nil {
            snapshotStore.logEvent(.publicIPChanged, message: "Public IP changed to \(info.ipAddress)")
            onEventLogged?()
        }
    }
}
