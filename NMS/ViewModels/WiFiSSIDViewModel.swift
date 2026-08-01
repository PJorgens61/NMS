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
    @Published private(set) var currentRSSI: Int?
    @Published private(set) var currentNoise: Int?
    @Published private(set) var currentChannelNumber: Int?
    @Published private(set) var currentChannelBand: String?
    @Published private(set) var currentPHYRateMbps: Double?
    @Published private(set) var currentSecurity: String?
    /// Newest-first, for `ContentView`'s Wi-Fi history — see
    /// `SnapshotStore.fetchWiFiSampleHistory`.
    @Published private(set) var recentSamples: [WiFiSampleRecord] = []

    private let ssidService = WiFiSSIDService()
    private let authService = LocationAuthorizationService()
    private let snapshotStore: SnapshotStore
    private var timer: Timer?

    /// Unlike Network Health's 5-30s connectivity cadence, RSSI/PHY rate
    /// don't need near-real-time tracking — this is a trend over minutes,
    /// not a reachability check. Matches `SNMPViewModel`'s poll interval,
    /// which is in the same "worth sampling periodically, not urgently"
    /// category. `WiFiSampleRecord` joins `SnapshotStore.pruneIfNeeded`'s
    /// retention group from the start (see that method) specifically
    /// because a timer-driven table run at this cadence is exactly the
    /// shape of table that grows unbounded if it doesn't.
    private static let sampleInterval: TimeInterval = 60

    /// The last Wi-Fi network actually seen, which is *not* the same as the
    /// previous value of `currentSSID`: that goes nil every time Ethernet
    /// takes over (see `refresh`), and a transient nil mid-handoff is
    /// normal. Comparing against the last real network instead means
    /// Thistle → Ethernet → Thistle is correctly silent, while
    /// Thistle → Ethernet → ThistleGuest still reports the change.
    private var lastKnownSSID: String?

    /// The `isWiFi` most recently passed to `refresh`, captured
    /// synchronously — not the same as "is `currentSSID` non-nil," which
    /// only updates once `sample()` actually runs. Exists purely to guard
    /// `refresh`'s own authorization completion below against a real race:
    /// requesting authorization defers its completion through a `Task`
    /// even when already granted, and on a network that flaps Wi-Fi↔Ethernet
    /// quickly (confirmed live — see BUGS.md), a `refresh(isWiFi: false)`
    /// can land in that gap. Without this guard the stale completion still
    /// runs, re-populating `currentSSID` from the radio (which stays
    /// associated with a network in the background even once Ethernet
    /// takes over as primary) and restarting the sampling timer — showing
    /// Wi-Fi details while on Ethernet, contradicting `ContentView`'s own
    /// "hidden outright on Ethernet" section gating.
    private var lastRequestedIsWiFi = false

    /// Fired when a `wifiNetworkChanged` event is logged, so the event log
    /// view refreshes — mirrors the other view models' hook.
    var onEventLogged: (() -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    deinit {
        timer?.invalidate()
    }

    /// Re-reads Wi-Fi state if `isWiFi`, requesting Core Location
    /// authorization first if it hasn't been granted yet. Pass `false` for
    /// Ethernet/no-connection so stale Wi-Fi state doesn't linger in the UI
    /// after switching away from Wi-Fi — this also stops the periodic
    /// sampling timer, since sampling a radio that isn't in use would just
    /// record the same "not connected" reading every interval.
    ///
    /// `departingNetworkFingerprint` is for `NMSApp`'s topology-change
    /// wiring only — see `logNetworkChangeIfNeeded` for why a network-
    /// change event needs it. `nil` (every other caller, including the
    /// popover's manual Refresh button) means "no override, tag with
    /// whatever's live," today's existing behavior.
    func refresh(isWiFi: Bool, departingNetworkFingerprint: String? = nil) {
        lastRequestedIsWiFi = isWiFi
        guard isWiFi else {
            currentSSID = nil
            currentBSSID = nil
            currentRSSI = nil
            currentNoise = nil
            currentChannelNumber = nil
            currentChannelBand = nil
            currentPHYRateMbps = nil
            currentSecurity = nil
            timer?.invalidate()
            timer = nil
            return
        }
        authService.requestAuthorization { [weak self] in
            // CLLocationManagerDelegate callbacks aren't guaranteed to land
            // on the main thread, so hop back explicitly before touching
            // @Published state.
            Task { @MainActor in
                // See `lastRequestedIsWiFi`'s doc comment — a `refresh(isWiFi:
                // false)` that landed while this authorization request was
                // pending already cleared everything; applying this stale
                // result now would undo that.
                guard let self, self.lastRequestedIsWiFi else { return }
                self.sample(departingNetworkFingerprint: departingNetworkFingerprint)
                self.startSamplingIfNeeded()
            }
        }
    }

    private func startSamplingIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
    }

    /// Reads current Wi-Fi state, updates the published fields, logs a
    /// network-change event if warranted, and persists the reading —
    /// called immediately on every `refresh(isWiFi: true)` and again every
    /// `sampleInterval` after that while still on Wi-Fi. `departingNetworkFingerprint`
    /// passes straight through from `refresh(isWiFi:departingNetworkFingerprint:)` —
    /// see that parameter's doc comment; the periodic timer in
    /// `startSamplingIfNeeded` always calls this with `nil` (no topology
    /// change involved).
    private func sample(departingNetworkFingerprint: String? = nil) {
        let info = ssidService.currentInfo()
        currentSSID = info.ssid
        currentBSSID = info.bssid
        currentRSSI = info.rssi
        currentNoise = info.noise
        currentChannelNumber = info.channelNumber
        currentChannelBand = info.channelBand
        currentPHYRateMbps = info.phyRateMbps
        currentSecurity = info.security
        logNetworkChangeIfNeeded(to: info.ssid, departingNetworkFingerprint: departingNetworkFingerprint)
        snapshotStore.recordWiFiSample(
            ssid: info.ssid,
            bssid: info.bssid,
            rssi: info.rssi,
            noise: info.noise,
            channelNumber: info.channelNumber,
            channelBand: info.channelBand,
            phyRateMbps: info.phyRateMbps,
            security: info.security
        )
        recentSamples = snapshotStore.fetchWiFiSampleHistory()
    }

    /// Logs only a genuine move between two *named* networks. Joining from
    /// nothing is deliberately silent: `currentSSID` starts nil, so every
    /// launch on Wi-Fi would otherwise log a "joined" event that reports no
    /// change at all — and the Ethernet ↔ Wi-Fi direction is already
    /// covered by `interfaceChanged`, which fires on the same handoff.
    /// What was missing, and all this adds, is the SSID-to-SSID case that
    /// no existing event could see.
    ///
    /// This event describes something that happened *on the network being
    /// left* ("you were on X, and left it for Y"), so `departingNetworkFingerprint`
    /// — captured by `NetworkIdentityViewModel.reset()` before it clears
    /// `SnapshotStore.currentNetworkFingerprint` for the topology change
    /// already in progress — is passed straight to `logEvent` rather than
    /// letting it fall back to the ambient value, which by the time this
    /// runs has already moved on (to `nil`, then to whatever the *new*
    /// network resolves to). Previously this event landed under the
    /// destination network's Events tab instead of the origin's — see
    /// `BUGS.md`'s "A network-transition event can be filed under the
    /// wrong network's Events tab."
    private func logNetworkChangeIfNeeded(to ssid: String?, departingNetworkFingerprint: String?) {
        guard let ssid, !ssid.isEmpty else { return }
        defer { lastKnownSSID = ssid }
        guard let previous = lastKnownSSID, previous != ssid else { return }
        // "X → Y" matches the interfaceChanged message form, which was
        // chosen over "from X to Y" because real names made the longer
        // phrasing truncate in the popover.
        snapshotStore.logEvent(
            .wifiNetworkChanged,
            message: "Wi-Fi network changed: \(previous) → \(ssid)",
            networkFingerprint: departingNetworkFingerprint
        )
        onEventLogged?()
    }
}
