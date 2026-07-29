import Foundation
import Combine

@MainActor
final class NetworkMonitorViewModel: ObservableObject {
    @Published private(set) var currentInterface: NetworkInterfaceInfo? {
        didSet { UIStateLogger.log("NetworkMonitorViewModel.currentInterface", currentInterface as Any) }
    }
    @Published private(set) var lastUpdated: Date?

    private let service = SystemConfigurationService()
    private let snapshotStore: SnapshotStore

    /// Fired with the newly-saved snapshot right after an observed change is
    /// persisted, so other services (e.g. LAN discovery) can tie their own
    /// work to the same topology-change event.
    var onChangePersisted: ((NetworkSnapshot) -> Void)?

    /// Fired whenever an `AppEventRecord` gets logged (interface down or back
    /// up), so the event log view can refresh.
    var onEventLogged: (() -> Void)?

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
        currentInterface = readInterface()
        lastUpdated = Date()
    }

    /// The single place the interface is read, so debug injection applies
    /// to both this and the change-observer path — see `FailureInjector`.
    /// No-op unless the debug defaults key is set.
    private func readInterface() -> NetworkInterfaceInfo? {
        FailureInjector.applyInterfaceDown(to: service.currentPrimaryInterface())
    }

    /// Called only from the `observeChanges` callback — this is the actual
    /// "something changed" signal, so it's the point at which we persist a
    /// snapshot, as opposed to `refresh()` which just re-reads current state
    /// (e.g. for the manual Refresh button).
    private func handleObservedChange() {
        let updated = readInterface()
        let didChange = updated != currentInterface
        let previous = currentInterface
        currentInterface = updated
        lastUpdated = Date()
        guard didChange else { return }

        if let updated {
            let snapshot = snapshotStore.save(updated)
            onChangePersisted?(snapshot)
            if previous == nil {
                // Recovering from having no connection at all — pairs with
                // the interfaceDown event logged when that happened, so the
                // log shows outage start and end, not just start.
                let label = updated.displayName ?? updated.interfaceName
                snapshotStore.logEvent(.interfaceUp, message: "Interface back up (\(label))")
                onEventLogged?()
            } else if let previous, previous.interfaceName != updated.interfaceName {
                // A different physical interface took over as primary (e.g.
                // Ethernet <-> Wi-Fi failover) without ever fully losing
                // connectivity in between — macOS prefers Ethernet whenever
                // it's available, so this handoff can happen fast enough
                // that `currentInterface` never actually goes nil, and
                // interfaceDown/interfaceUp never fire around it. Worth its
                // own event since that failover is exactly the kind of
                // change worth noticing.
                let fromLabel = previous.displayName ?? previous.interfaceName
                let toLabel = updated.displayName ?? updated.interfaceName
                // "X → Y" instead of "from X to Y" — measured directly:
                // real adapter display names (e.g. "Thunderbolt Ethernet")
                // made the longer phrasing truncate in practice (only
                // ~6pt of margin against the popover's width budget); the
                // arrow form leaves real headroom (~32pt) for the same
                // real-world case.
                snapshotStore.logEvent(.interfaceChanged, message: "Interface changed: \(fromLabel) → \(toLabel)")
                onEventLogged?()
            }
        } else if let previous {
            // Transitioned from having a connection to having none — this
            // was previously silently dropped (the old code only handled
            // the `let updated` case), so "interface went down" never made
            // it into any persisted history at all.
            let label = previous.displayName ?? previous.interfaceName
            snapshotStore.logEvent(.interfaceDown, message: "Interface went down (was \(label))")
            onEventLogged?()
        }
    }

    var statusSymbolName: String {
        guard let currentInterface else { return "wifi.slash" }
        return currentInterface.isWiFi ? "wifi" : "cable.connector"
    }
}
