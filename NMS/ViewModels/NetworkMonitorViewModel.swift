import Foundation
import Combine

@MainActor
final class NetworkMonitorViewModel: ObservableObject {
    @Published private(set) var currentInterface: NetworkInterfaceInfo? {
        didSet { UIStateLogger.log("NetworkMonitorViewModel.currentInterface", currentInterface as Any) }
    }
    @Published private(set) var lastUpdated: Date?
    /// When the interface last *actually changed* — `nil` until the first
    /// real change, and untouched by a `refresh()`/observer callback that
    /// finds nothing different (unlike `lastUpdated`, which moves on every
    /// read). `ConnectivityViewModel` reads this to widen its tolerance
    /// for disagreement between ICMP and DNS/HTTP checks right after a
    /// genuine transition — see `isLikelyLocalPingFailure`'s call site.
    /// Logged (unlike `lastUpdated`, which would just add a line on every
    /// routine poll) because that suppression window has already produced
    /// one real incident — six wrongly-suppressed outage events, see
    /// `ConnectivityViewModel.apply(_:)`'s doc comment — and verifying its
    /// 30-second grace period from `ui-state.log` needs to see this value
    /// directly, not infer it from `currentInterface` merely having
    /// changed.
    @Published private(set) var lastChangeAt: Date? {
        didSet { UIStateLogger.log("NetworkMonitorViewModel.lastChangeAt", lastChangeAt as Any) }
    }

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
        // A plain read, not `updateInterface()` — there's no genuine
        // "previous" state to compare against at launch, so this must
        // never log a recovery event the way a real, later transition
        // would. `currentInterface` starting `nil` here is an artifact of
        // not having read yet, not evidence of an outage just recovered
        // from.
        currentInterface = readInterface()
        lastUpdated = Date()
        service.observeChanges { [weak self] in
            // The SCDynamicStore callback can land on a background thread
            // depending on run loop context, so hop back to main.
            Task { @MainActor in
                self?.updateInterface()
            }
        }
    }

    /// Manual re-read (the popover's Refresh button). Runs through the
    /// same change-detection-and-event-logging path a real topology
    /// change does (`updateInterface()`) rather than a bare re-read, so a
    /// Refresh press reacts exactly as a real change would — including
    /// closing a real gap in `FailureInjector`'s interface-down
    /// injection: previously, only the path reachable exclusively from
    /// the real `SCDynamicStore` callback ever logged
    /// `interfaceDown`/`interfaceUp`, and injection has no way to fake
    /// that callback. Forcing the interface down and pressing Refresh
    /// used to silently update `currentInterface` with no event at all;
    /// now the same press produces the real event pair.
    func refresh() {
        updateInterface()
    }

    /// The single place the interface is read, so debug injection applies
    /// to both this and the change-observer path — see `FailureInjector`.
    /// No-op unless the debug defaults key is set.
    private func readInterface() -> NetworkInterfaceInfo? {
        FailureInjector.applyInterfaceDown(to: service.currentPrimaryInterface())
    }

    /// Shared by `refresh()` and the real `observeChanges` callback — the
    /// actual "something changed" signal, so it's the point at which we
    /// persist a snapshot and log events. Merged from what used to be two
    /// separate methods (`refresh()` doing a bare re-read, and a private
    /// `handleObservedChange()` reachable only from the observer) so
    /// event logging is reachable from either path, not just one.
    private func updateInterface() {
        let updated = readInterface()
        let didChange = updated != currentInterface
        let previous = currentInterface
        currentInterface = updated
        lastUpdated = Date()
        guard didChange else { return }
        lastChangeAt = lastUpdated

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
