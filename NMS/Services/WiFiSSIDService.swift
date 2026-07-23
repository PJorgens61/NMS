import CoreWLAN

/// Reads the current Wi-Fi network name via CoreWLAN. Returns `nil` if not
/// connected to Wi-Fi, or if Core Location hasn't authorized this process
/// yet (see `LocationAuthorizationService`) — Apple gates SSID behind
/// location permission since network names can reveal physical location.
struct WiFiSSIDService {
    func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }
}
