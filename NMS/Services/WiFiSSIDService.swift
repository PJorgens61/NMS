import CoreWLAN

/// Reads the current Wi-Fi network's identity and radio characteristics
/// via CoreWLAN. Returns `nil` fields if not connected to Wi-Fi, or if Core
/// Location hasn't authorized this process yet (see
/// `LocationAuthorizationService`) — Apple gates SSID/BSSID behind
/// location permission, since either can reveal physical location. The
/// signal/link fields (RSSI, channel, PHY rate, security) aren't
/// location-sensitive the same way, but come from the same `CWInterface`
/// lookup, so they're read together rather than with a separate call.
nonisolated struct WiFiSSIDService {
    struct Info {
        let ssid: String?
        /// The associated access point's own MAC address — distinct from
        /// the network's SSID, which several physical APs can share (e.g. a
        /// VRRP-style pair).
        let bssid: String?
        /// dBm, typically -30 (excellent) to -90 (unusable).
        let rssi: Int?
        /// dBm — read alongside `rssi` so an SNR is derivable from one
        /// lookup rather than two calls at different moments.
        let noise: Int?
        let channelNumber: Int?
        /// Human-readable ("2 GHz"/"5 GHz"/"6 GHz"/"Unknown"), not the raw
        /// `CWChannelBand` — nothing downstream needs the enum itself.
        let channelBand: String?
        /// Negotiated PHY rate in Mbps.
        let phyRateMbps: Double?
        /// Human-readable ("WPA3 Personal", etc.), not the raw
        /// `CWSecurity` — same reasoning as `channelBand`.
        let security: String?
    }

    func currentInfo() -> Info {
        let interface = CWWiFiClient.shared().interface()
        return Info(
            ssid: interface?.ssid(),
            bssid: interface?.bssid(),
            rssi: interface.map { $0.rssiValue() },
            noise: interface.map { $0.noiseMeasurement() },
            channelNumber: interface?.wlanChannel()?.channelNumber,
            channelBand: interface?.wlanChannel().map(Self.bandLabel(for:)),
            phyRateMbps: interface.map { $0.transmitRate() },
            security: interface.map { Self.securityLabel(for: $0.security()) }
        )
    }

    private static func bandLabel(for channel: CWChannel) -> String {
        switch channel.channelBand {
        case .band2GHz: return "2 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        case .bandUnknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    /// Only the cases realistically seen on a modern Mac's own connection
    /// get a specific label; anything else (legacy/enterprise variants)
    /// falls back to a generic description rather than an exhaustive
    /// switch over `CWSecurity`'s full, largely-legacy case list.
    private static func securityLabel(for security: CWSecurity) -> String {
        switch security {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed: return "WPA Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .dynamicWEP: return "Dynamic WEP"
        default: return "Unknown"
        }
    }
}
