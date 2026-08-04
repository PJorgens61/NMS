import Foundation

/// Negotiated Ethernet link speed/duplex — see `EthernetLinkService`. No
/// persisted history, no events, no periodic timer of its own: unlike
/// Wi-Fi's RSSI (which drifts continuously and is worth a trend line),
/// link speed only changes on a physical event — a cable swap, a
/// different switch port — which is exactly when `NMSApp`'s
/// topology-change handling already calls `refresh(isEthernet:device:)`
/// again. A timer polling for a value that's otherwise static would just
/// re-read the same answer every interval.
@MainActor
@Observable
final class EthernetLinkViewModel {
    private(set) var currentSpeedMbps: Double? {
        didSet { UIStateLogger.log("EthernetLinkViewModel.currentSpeedMbps", currentSpeedMbps as Any) }
    }
    private(set) var currentDuplex: String?

    private let service = EthernetLinkService()

    /// Re-reads link state if `isEthernet`, else clears it — same
    /// isEthernet/else-clear shape as `WiFiSSIDViewModel.refresh(isWiFi:)`.
    /// `networksetup` blocks like the `ping`/`snmpget`/`arp`/`ipconfig`
    /// shell-outs elsewhere in this app, so it runs off the main thread
    /// even though it's local-only and normally fast — same pattern
    /// `DHCPLeaseViewModel.check()` already uses.
    func refresh(isEthernet: Bool, device: String?) {
        guard isEthernet, let device else {
            currentSpeedMbps = nil
            currentDuplex = nil
            return
        }
        let service = self.service
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = service.currentInfo(device: device)
            Task { @MainActor [weak self] in
                self?.currentSpeedMbps = info.speedMbps
                self?.currentDuplex = info.duplex
            }
        }
    }
}
