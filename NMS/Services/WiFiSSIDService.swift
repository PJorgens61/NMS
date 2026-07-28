import CoreWLAN

/// Reads the current Wi-Fi network's name and access point identity via
/// CoreWLAN. Returns `nil` fields if not connected to Wi-Fi, or if Core
/// Location hasn't authorized this process yet (see
/// `LocationAuthorizationService`) — Apple gates both SSID and BSSID behind
/// location permission, since either can reveal physical location.
struct WiFiSSIDService {
    struct Info {
        let ssid: String?
        /// The associated access point's own MAC address — distinct from
        /// the network's SSID, which several physical APs can share (e.g. a
        /// VRRP-style pair). Read alongside `ssid` from the same
        /// `CWInterface` lookup rather than a separate call, so the two
        /// can't describe two different moments if the association changes
        /// in between.
        let bssid: String?
    }

    func currentInfo() -> Info {
        let interface = CWWiFiClient.shared().interface()
        return Info(ssid: interface?.ssid(), bssid: interface?.bssid())
    }
}
