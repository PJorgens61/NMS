import CoreLocation

/// Requests Core Location "when in use" authorization, which macOS uses to
/// gate Wi-Fi SSID access via CoreWLAN (network names can reveal physical
/// location through SSID-to-location databases). This app has no other use
/// for location data — the request exists purely to unlock
/// `CWInterface.ssid()`.
final class LocationAuthorizationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pendingCallback: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    /// Calls `onAuthorized` immediately if already granted; otherwise
    /// triggers the system permission prompt and calls it once the user
    /// responds affirmatively. If the user denies it, `onAuthorized` is
    /// simply never called — callers should treat "no SSID" as the steady
    /// state rather than an error.
    func requestAuthorization(onAuthorized: @escaping () -> Void) {
        if isAuthorized {
            onAuthorized()
            return
        }
        pendingCallback = onAuthorized
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isAuthorized, let callback = pendingCallback else { return }
        pendingCallback = nil
        callback()
    }
}
