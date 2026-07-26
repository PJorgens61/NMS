import AppKit
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
        // This app runs with `.accessory` activation policy (no Dock icon,
        // never the foreground app), and the first call to this happens
        // synchronously from `NMSApp.init()` — before AppKit's shared
        // application instance is fully spun up. The bare `NSApp` global
        // is nil at that point (confirmed directly: crashed on first
        // launch), so `NSApplication.shared` is used instead, a proper
        // lazy singleton. Dispatching to the next run-loop turn instead of
        // calling `activate`/`requestWhenInUseAuthorization` immediately
        // gives AppKit's startup a moment to finish — without a brief
        // activation, the system permission dialog can otherwise fail to
        // surface at all for a background/agent app that's never been
        // foregrounded, which is indistinguishable from "no prompt" and
        // leaves `authorizationStatus` stuck at `.notDetermined` forever.
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isAuthorized, let callback = pendingCallback else { return }
        pendingCallback = nil
        callback()
    }
}
