import Foundation
import Combine

@MainActor
final class WiFiSSIDViewModel: ObservableObject {
    @Published private(set) var currentSSID: String? {
        didSet { UIStateLogger.log("WiFiSSIDViewModel.currentSSID", currentSSID as Any) }
    }
    /// The associated access point's MAC address — shown so a VRRP-style
    /// AP pair sharing one SSID can be told apart at a glance, without
    /// cross-referencing the SNMP device list.
    @Published private(set) var currentBSSID: String? {
        didSet { UIStateLogger.log("WiFiSSIDViewModel.currentBSSID", currentBSSID as Any) }
    }

    private let ssidService = WiFiSSIDService()
    private let authService = LocationAuthorizationService()
    private let snapshotStore: SnapshotStore

    /// The last Wi-Fi network actually seen, which is *not* the same as the
    /// previous value of `currentSSID`: that goes nil every time Ethernet
    /// takes over (see `refresh`), and a transient nil mid-handoff is
    /// normal. Comparing against the last real network instead means
    /// Thistle → Ethernet → Thistle is correctly silent, while
    /// Thistle → Ethernet → ThistleGuest still reports the change.
    private var lastKnownSSID: String?

    /// Fired when a `wifiNetworkChanged` event is logged, so the event log
    /// view refreshes — mirrors the other view models' hook.
    var onEventLogged: (() -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    /// Re-reads the SSID if `isWiFi`, requesting Core Location
    /// authorization first if it hasn't been granted yet. Pass `false` for
    /// Ethernet/no-connection so a stale SSID doesn't linger in the UI
    /// after switching away from Wi-Fi.
    func refresh(isWiFi: Bool) {
        guard isWiFi else {
            currentSSID = nil
            currentBSSID = nil
            return
        }
        authService.requestAuthorization { [weak self] in
            // CLLocationManagerDelegate callbacks aren't guaranteed to land
            // on the main thread, so hop back explicitly before touching
            // @Published state.
            Task { @MainActor in
                guard let self else { return }
                let info = self.ssidService.currentInfo()
                self.currentSSID = info.ssid
                self.currentBSSID = info.bssid
                self.logNetworkChangeIfNeeded(to: info.ssid)
            }
        }
    }

    /// Logs only a genuine move between two *named* networks. Joining from
    /// nothing is deliberately silent: `currentSSID` starts nil, so every
    /// launch on Wi-Fi would otherwise log a "joined" event that reports no
    /// change at all — and the Ethernet ↔ Wi-Fi direction is already
    /// covered by `interfaceChanged`, which fires on the same handoff.
    /// What was missing, and all this adds, is the SSID-to-SSID case that
    /// no existing event could see.
    private func logNetworkChangeIfNeeded(to ssid: String?) {
        guard let ssid, !ssid.isEmpty else { return }
        defer { lastKnownSSID = ssid }
        guard let previous = lastKnownSSID, previous != ssid else { return }
        // "X → Y" matches the interfaceChanged message form, which was
        // chosen over "from X to Y" because real names made the longer
        // phrasing truncate in the popover.
        snapshotStore.logEvent(.wifiNetworkChanged, message: "Wi-Fi network changed: \(previous) → \(ssid)")
        onEventLogged?()
    }
}
