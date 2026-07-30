import Foundation
import SwiftData

/// One periodic reading of the current Wi-Fi radio's signal/link
/// characteristics — a genuine time series (mirrors `NetworkQualityRecord`),
/// not a change-log, so every sample gets a row regardless of whether
/// values differ from the last one. Scoped per network like
/// Events/DHCP/SNMP — see `SnapshotStore.currentNetworkFingerprint`.
@Model
final class WiFiSampleRecord {
    var sampledAt: Date
    var ssid: String?
    var bssid: String?
    /// dBm, typically -30 (excellent) to -90 (unusable).
    var rssi: Int?
    /// dBm — read alongside RSSI so an SNR (RSSI - noise) is derivable
    /// without a second `CWInterface` call at a different moment.
    var noise: Int?
    var channelNumber: Int?
    /// Human-readable ("2 GHz"/"5 GHz"/"6 GHz"), not the raw
    /// `CWChannelBand` — this is a display value, and the raw enum isn't
    /// meaningfully more useful stored than its label.
    var channelBand: String?
    var phyRateMbps: Double?
    /// Human-readable ("WPA3 Personal", etc.), same reasoning as
    /// `channelBand`.
    var security: String?
    /// `nil` only in the same narrow launch-time window every other
    /// per-network table's `nil` covers — see `AppEventRecord
    /// .networkFingerprint`.
    var networkFingerprint: String?

    init(
        sampledAt: Date = Date(),
        ssid: String?,
        bssid: String?,
        rssi: Int?,
        noise: Int?,
        channelNumber: Int?,
        channelBand: String?,
        phyRateMbps: Double?,
        security: String?,
        networkFingerprint: String?
    ) {
        self.sampledAt = sampledAt
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.channelNumber = channelNumber
        self.channelBand = channelBand
        self.phyRateMbps = phyRateMbps
        self.security = security
        self.networkFingerprint = networkFingerprint
    }
}
