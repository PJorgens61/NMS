import SwiftUI

/// The single green/yellow/red mapping the Network tile's quick-check row
/// and the Apple networkQuality tile's history rows both use — raised
/// directly, so a given RPM number reads the same color in either place
/// rather than each inventing its own cutoffs. Thresholds match
/// `QuickCheckStatus`'s own (the shared source of truth for "what counts
/// as good") rather than duplicating the numbers here.
///
/// Pulled out into its own type once both tiles that need it
/// (`NetworkTile`/`AppleNetworkQualityTile`) became separate `View`
/// types with no natural shared parent — see `PUNCHLIST.md`'s
/// `ContentView` fan-in entry.
enum QuickCheckDisplay {
    static func color(forRPM rpm: Int) -> Color {
        switch QuickCheckStatus(rpm: rpm) {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .red
        }
    }

    /// Rough reference points for "is this RPM number good or bad" —
    /// deliberately a tooltip, not a permanent caption: this is reference
    /// detail for someone who already sees a number and wants to know if
    /// it's good, not a first-contact explanation. Sourced from how
    /// Apple's own tool is characterized in independent write-ups (not
    /// invented here) — see `DESIGN-NOTES.md`'s "Network Quality" section
    /// for the man-page-level description this supplements.
    static let rpmThresholdHelp = """
        RPM (round trips per minute) measures responsiveness under load — \
        higher is better. Roughly: above 2000 is excellent, under 800 \
        suggests bufferbloat.
        """
}
