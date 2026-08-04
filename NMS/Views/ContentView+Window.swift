import SwiftUI

/// `sysDescrLines` — the one member left here after the `ContentView`
/// fan-in work (see `PUNCHLIST.md`'s entry) moved every actual section
/// out into its own `View` type. Kept in this file, not moved:
/// `NMSTests/NMSTests.swift` calls it directly as
/// `ContentView.sysDescrLines`, which still resolves correctly from here
/// (an `extension ContentView` in any file contributes to the same
/// type), and moving it would only churn that test's imports for no
/// benefit.
///
/// `pathAndSpeedRow`/`tracerouteSection`/`speedTestTileContent`/
/// `appleNetworkQualityTileContent`/`wifiStressTestTileContent`/
/// `wifiSection`/`ethernetLinkSection`/`saasMonitoringSection`/
/// `eventList`/`infrastructureList`/`dhcpHistoryList` all moved out
/// entirely, into `PathToInternetTile.swift`/`SpeedTestTile.swift`/
/// `AppleNetworkQualityTile.swift`/`LocalStressTestTile.swift`/
/// `WiFiTile.swift`/`EthernetTile.swift`/`SaaSStatusTile.swift`/
/// `EventsTile.swift`/`SNMPDevicesTile.swift`/`DHCPHistoryTile.swift` as
/// their own `View` types.
extension ContentView {
    /// Splits `sysDescr` into at most two lines, breaking at the space
    /// nearest the midpoint so neither line is wildly longer than the
    /// other. Short strings (the common case — most devices' `sysDescr`
    /// fits on one line already) come back unsplit: this only kicks in
    /// past a length that's already overflowing one line at this row's
    /// font/width, mirroring the two lines `SNMPDevicesTile`'s own
    /// `sysDescr` case needs (see that file's doc comment for why this
    /// exists instead of a wrapping `Text`).
    // Not `private` — `@testable import NMS` in NMSTests.swift can only
    // reach `internal`, same reason `SaaSStatusService`'s parsers and
    // `NMSApp.openStoreWithFallback` are also plain `static func`.
    static func sysDescrLines(_ text: String) -> [String] {
        guard text.count > 70 else { return [text] }
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        var breakIndex: String.Index?
        var offset = 0
        while breakIndex == nil, offset < text.count / 2 {
            if let before = text.index(mid, offsetBy: -offset, limitedBy: text.startIndex),
               text[before] == " " {
                breakIndex = before
            } else if let after = text.index(mid, offsetBy: offset, limitedBy: text.endIndex),
                      after < text.endIndex, text[after] == " " {
                breakIndex = after
            }
            offset += 1
        }
        guard let breakIndex else { return [text] }
        let first = text[text.startIndex..<breakIndex].trimmingCharacters(in: .whitespaces)
        let second = text[breakIndex...].trimmingCharacters(in: .whitespaces)
        return [first, second]
    }
}
