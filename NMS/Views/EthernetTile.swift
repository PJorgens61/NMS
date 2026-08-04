import SwiftUI

/// The Ethernet tile — window-only, boxed via `tile()`. Just two rows: no
/// signal to chart, no BSSID/channel/security the way a Wi-Fi radio has,
/// since a wired link has none of those concepts. Renders nothing at all
/// when there's no negotiated link (`currentSpeedMbps == nil`) —
/// mutually exclusive with the Wi-Fi tile by construction (a Mac's
/// default route is either Wi-Fi or Ethernet, never both).
///
/// First of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry) — holds only the one `@ObservedObject` it actually
/// reads, so a change to any of `ContentView`'s other sixteen view
/// models no longer re-evaluates this tile's body at all.
struct EthernetTile: View {
    @ObservedObject var ethernetLink: EthernetLinkViewModel

    var body: some View {
        if let speed = ethernetLink.currentSpeedMbps {
            tile(title: "Ethernet", fixedHeight: SectionLayout.ethernetLink.boxHeight) {
                row("Speed", "\(Int(speed)) Mbps")
                if let duplex = ethernetLink.currentDuplex {
                    row("Duplex", duplex)
                }
            }
        }
    }
}
