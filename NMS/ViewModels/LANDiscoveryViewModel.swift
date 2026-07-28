import Foundation
import Combine

@MainActor
final class LANDiscoveryViewModel: ObservableObject {
    /// Instrumented so the `arp -n` + async-enrichment change is verifiable
    /// from the log: hostnames now arrive *after* the scan rather than with
    /// it, which is exactly the kind of thing worth being able to confirm.
    @Published private(set) var devices: [DiscoveredDevice] = [] {
        didSet { UIStateLogger.log("LANDiscoveryViewModel.devices", devices) }
    }
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?

    private let discoveryService = LANDiscoveryService()
    private let reverseDNSService = ReverseDNSService()
    private let snapshotStore: SnapshotStore
    /// Guards against piling up overlapping `arp` subprocesses if topology
    /// changes arrive faster than a scan completes.
    private var isScanning = false

    /// Fired with the freshly-scanned devices after every scan (automatic or
    /// manual) — this is what lets `NetworkIdentityViewModel` find the
    /// router's MAC without a second `arp` call.
    var onScanCompleted: (([DiscoveredDevice]) -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    /// Scans the ARP table and persists the results tied to `snapshot`
    /// (falling back to the most recently saved snapshot if none is given,
    /// e.g. for a manual scan that isn't reacting to a fresh change).
    /// Runs off the main thread. This used to call `discoveryService.scan()`
    /// inline, which meant a subprocess pipe read on `@MainActor` — and a
    /// beachballed menu bar for as long as `arp` took, observed in practice
    /// at nearly four minutes. Every other view model doing subprocess work
    /// (SNMP, traceroute, connectivity) already dispatches; this was the
    /// one that didn't. Fixing `arp` to `-n` removes the known cause, and
    /// dispatching removes the whole class of it.
    func scan(for snapshot: NetworkSnapshot? = nil) {
        guard !isScanning else { return }
        isScanning = true
        let service = discoveryService
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try service.scan() }
            Task { @MainActor in
                self?.apply(result, for: snapshot)
            }
        }
    }

    private func apply(_ result: Result<[DiscoveredDevice], Error>, for snapshot: NetworkSnapshot?) {
        isScanning = false
        switch result {
        case let .success(found):
            devices = found
            lastScanAt = Date()
            lastError = nil
            snapshotStore.saveDiscoveredDevices(found, for: snapshot ?? snapshotStore.latestSnapshot())
            onScanCompleted?(found)
            enrichHostnames(for: found)
        case let .failure(error):
            lastError = error.localizedDescription
        }
    }

    /// Restores the hostnames that `arp -n` deliberately no longer resolves,
    /// each on its own background lookup with `ReverseDNSService`'s timeout
    /// — so a device with no PTR record costs a bounded wait off the main
    /// thread instead of an unbounded one on it. Mirrors
    /// `TracerouteViewModel.enrichHostnames`.
    private func enrichHostnames(for scanned: [DiscoveredDevice]) {
        let service = reverseDNSService
        for device in scanned {
            let address = device.ipAddress
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let hostname = service.hostname(for: address) else { return }
                Task { @MainActor in
                    guard let self else { return }
                    // A later scan may already have replaced `devices`, so
                    // only apply if this address is still present and still
                    // unnamed — never overwrite a fresher result.
                    guard
                        let index = self.devices.firstIndex(where: { $0.ipAddress == address }),
                        self.devices[index].hostname == nil
                    else { return }
                    self.devices[index].hostname = hostname
                }
            }
        }
    }
}
