import Foundation
import Combine

@MainActor
final class WiFiSSIDViewModel: ObservableObject {
    @Published private(set) var currentSSID: String?

    private let ssidService = WiFiSSIDService()
    private let authService = LocationAuthorizationService()

    /// Re-reads the SSID if `isWiFi`, requesting Core Location
    /// authorization first if it hasn't been granted yet. Pass `false` for
    /// Ethernet/no-connection so a stale SSID doesn't linger in the UI
    /// after switching away from Wi-Fi.
    func refresh(isWiFi: Bool) {
        guard isWiFi else {
            currentSSID = nil
            return
        }
        authService.requestAuthorization { [weak self] in
            // CLLocationManagerDelegate callbacks aren't guaranteed to land
            // on the main thread, so hop back explicitly before touching
            // @Published state.
            Task { @MainActor in
                self?.currentSSID = self?.ssidService.currentSSID()
            }
        }
    }
}
