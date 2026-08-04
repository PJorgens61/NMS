import SwiftUI

/// The Wi-Fi tile — current signal/link characteristics for the active
/// access point. Renders nothing at all when there's no association
/// (`currentSSID == nil`) — mutually exclusive with `EthernetTile` by
/// construction (a Mac's default route is either Wi-Fi or Ethernet,
/// never both).
///
/// Second of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry, and `EthernetTile` for the first) — holds only the one
/// view model it actually reads.
struct WiFiTile: View {
    var wifiSSID: WiFiSSIDViewModel

    var body: some View {
        if wifiSSID.currentSSID != nil {
            tile(title: "Wi-Fi", fixedHeight: SectionLayout.wifi.boxHeight) {
                // Shown first, before Signal: it identifies *which*
                // access point, which is the natural thing to read
                // before that AP's own signal/link characteristics
                // below.
                if let bssid = wifiSSID.currentBSSID {
                    row("BSSID", bssid)
                }
                // Not the plain `row(_:_:)` helper, so the sparkline can
                // sit inline between label and value — same layout
                // Network Health's per-layer rows use for their own
                // sparklines.
                HStack {
                    Text("Signal")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if wifiSSID.recentSamples.count > 1 {
                        Sparkline(values: wifiSSID.recentSamples.reversed().map { $0.rssi.map(Double.init) })
                    }
                    Text(signalDetail)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12))
                row("Channel", channelDetail)
                if let rate = wifiSSID.currentPHYRateMbps {
                    row("PHY Rate", "\(Int(rate)) Mbps", help: Self.phyRateHelp)
                }
                if let security = wifiSSID.currentSecurity {
                    row("Security", security)
                }
            }
        }
    }

    /// RSSI plus its trend, with an SNR parenthetical when noise is also
    /// available — "-52 dBm (SNR 38 dB)". Noise isn't always reported
    /// (some adapters/driver states omit it), so the SNR half is
    /// conditional rather than showing a misleading partial calculation.
    private var signalDetail: String {
        guard let rssi = wifiSSID.currentRSSI else { return "—" }
        if let noise = wifiSSID.currentNoise {
            return "\(rssi) dBm (SNR \(rssi - noise) dB)"
        }
        return "\(rssi) dBm"
    }

    private var channelDetail: String {
        guard let number = wifiSSID.currentChannelNumber else { return "—" }
        guard let band = wifiSSID.currentChannelBand else { return "\(number)" }
        return "\(number) (\(band))"
    }

    /// Reference detail for a number that reads as a speed guarantee but
    /// isn't one — raised directly, after a real gap where this row's own
    /// number (a negotiated ceiling) set expectations no measured test
    /// could match, and NMS had nothing here explaining why. Deliberately
    /// doesn't blame the access point, even a good one — the gap is
    /// mostly protocol overhead and, in a crowded environment,
    /// contention with neighboring networks that no local hardware
    /// controls.
    static let phyRateHelp = """
        PHY Rate is the radio's negotiated link speed right now, not a \
        throughput guarantee. Real throughput and responsiveness are \
        always lower — protocol overhead, retries, and, in a crowded \
        area, contention with neighboring networks on the same channel, \
        none of which even a good access point can fully avoid.
        """
}
