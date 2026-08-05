import CoreGraphics

/// Every `ContentView` section with its own fixed-height `tile()` box —
/// declared here so the height lives in one place rather than scattered
/// across `tile(fixedHeight:)` call sites.
///
/// **Not every section is listed.** Network, Path to Internet, Speed
/// Test, and Apple networkQuality are all unconditional tiles sharing
/// `ContentView.tileHeight` directly — nothing to declare here. These six
/// used to get their own box via a separate `scrollBox()` helper (removed
/// — its width behavior diverged from `tile()`'s in a way that let
/// content overflow past every other tile's edge, confirmed live; see
/// `ContentView.scrollableContent`'s doc comment for the full story) and
/// now go through `tile(fixedHeight:)` too, just each with its own height
/// from here instead of the shared constant.
enum SectionLayout: String, CaseIterable, Sendable {
    case events
    case snmpDevices
    case dhcpHistory
    case wifi
    case ethernetLink
    case saasMonitoring
    case firewallVisibility

    /// Fixed, not `maxHeight` — a `maxHeight` alone lets the scroll view
    /// shrink to fit however few rows currently exist, which made a
    /// single-entry list look identical to having no box at all, and
    /// could collapse to zero visible height even with real content
    /// (confirmed directly).
    ///
    /// None of these need to match each other — none sit side by side
    /// with another the way the top tile row does (see
    /// `ContentView.tileHeight`), so there's no alignment bug forcing one
    /// shared number. A box the window always scrolls doesn't need to be
    /// measured to fit any particular row count exactly (a lease count, a
    /// device count) either — picked generously round instead, each
    /// independently, rather than trimmed to the row count on hand at the
    /// time.
    var boxHeight: CGFloat {
        switch self {
        case .events: return 350
        case .snmpDevices: return 300
        case .dhcpHistory: return 150
        case .wifi: return 130
        // Two rows (Speed, Duplex) — no signal-strength sparkline, no
        // BSSID/channel/security the way Wi-Fi's box has, so it needs
        // nowhere near as much room. **Was 60** — never checked against
        // a real render; `tile()`'s shared header overhead alone is
        // ~45pt, leaving only ~15pt of content area, not enough for
        // even one 12pt-font row. Confirmed live: only "Speed" showed,
        // "Duplex" was clipped out entirely. 80 leaves ~35pt of content
        // — comfortable room for both rows with a little breathing
        // room, still clearly smaller than Wi-Fi's 130.
        case .ethernetLink: return 80
        case .saasMonitoring: return 150
        // Same generous-round-number reasoning as every other case here
        // — a history list plus a status line, roughly `dhcpHistory`'s
        // shape (also a timestamped history list), sized a bit taller
        // since each row shows a port count rather than fitting on one
        // line like a lease's `primaryDetail`.
        case .firewallVisibility: return 180
        }
    }
}
