import Foundation
import Combine

@MainActor
final class NetworkMonitorViewModel: ObservableObject {
    @Published private(set) var currentInterface: NetworkInterfaceInfo?
    @Published private(set) var lastUpdated: Date?

    private let service = SystemConfigurationService()
    private let snapshotStore: SnapshotStore

    /// Fired with the newly-saved snapshot right after an observed change is
    /// persisted, so other services (e.g. LAN discovery) can tie their own
    /// work to the same topology-change event.
    var onChangePersisted: ((NetworkSnapshot) -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        refresh()
        service.observeChanges { [weak self] in
            // The SCDynamicStore callback can land on a background thread
            // depending on run loop context, so hop back to main.
            Task { @MainActor in
                self?.handleObservedChange()
            }
        }
    }

    func refresh() {
        currentInterface = service.currentPrimaryInterface()
        lastUpdated = Date()
    }

    /// Called only from the `observeChanges` callback — this is the actual
    /// "something changed" signal, so it's the point at which we persist a
    /// snapshot, as opposed to `refresh()` which just re-reads current state
    /// (e.g. for the manual Refresh button).
    private func handleObservedChange() {
        let updated = service.currentPrimaryInterface()
        let didChange = updated != currentInterface
        currentInterface = updated
        lastUpdated = Date()
        if didChange, let updated {
            let snapshot = snapshotStore.save(updated)
            onChangePersisted?(snapshot)
        }
    }

    var statusSymbolName: String {
        guard let currentInterface else { return "wifi.slash" }
        return currentInterface.isWiFi ? "wifi" : "cable.connector"
    }
}
