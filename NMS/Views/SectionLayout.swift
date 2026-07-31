import CoreGraphics

/// Which of the app's two UI surfaces a `ContentView` is rendering into.
///
/// Replaces the `isInWindow: Bool` this used to be. The boolean started
/// life as a pure *sizing* flag ("same content, taller boxes here") and
/// quietly grew into a *product* flag — four sections are now window-only
/// outright — which a `Bool` can't express: `isInWindow ? 200 : 123`
/// reads as "two sizes of the same thing" even when the popover value is
/// unreachable, and it silently defaults every new section into the
/// popover's scarcest resource. See `SectionLayout` for what replaced
/// that.
enum Surface: String, CaseIterable, Sendable {
    case popover
    case window
}

/// Every `ContentView` section whose vertical space is budgeted — which
/// surfaces it appears on, and how tall its fixed-height scroll box is on
/// each.
///
/// **Why this exists as data rather than inline numbers.** The popover's
/// height ceiling is the constraint this app has fought hardest (see
/// DESIGN-NOTES.md's "The MacBook Air height constraint"), and it kept
/// recurring because there was no way to see the budget as a whole: each
/// section carried its own `isInWindow ? tall : short` pair next to its
/// own hand-written justification, so "what does the popover actually
/// cost?" could only be answered by reading six scattered comments and
/// adding them up by hand. Two consequences showed up in the real code
/// before this table existed:
///
/// 1. **Dead popover heights.** `SNMP Devices` (123pt) and `DHCP History`
///    (56pt) both kept carefully-trimmed popover values, and detailed
///    comments explaining the trims, long after both sections became
///    window-only — roughly 180pt of popover budget that a future trim
///    would have reasoned about and found wasn't there.
/// 2. **Six different policies for one pattern.** Scroll thresholds had
///    drifted to three different values (none, >2, >3) across six
///    sections with no single place saying what the rule was.
///
/// Declared here, the popover's cost is arithmetic — `popoverBoxTotal`
/// sums it, and a plain unit test asserts it against `popoverBoxBudget`
/// without needing to render anything. That's the piece that turns this
/// from "trim again when someone notices" into "the build tells you."
///
/// **Not every section is listed.** Network Health and Info are
/// unconditional label/value tiles with no fixed-height box — nothing to
/// declare and nothing to budget. Only sections that are either
/// surface-conditional or box-bearing appear here.
enum SectionLayout: String, CaseIterable, Sendable {
    case pathToInternet
    case speedTest
    case events
    case wifi
    case snmpDevices
    case dhcpHistory
    case printerAlerts

    /// The confirmed per-row height for these lists — **measured, not
    /// estimated**. Two real desktop screenshots bracketing commit
    /// `41e169c` showed 10 event rows in a 170pt box and 8 rows in a 136pt
    /// box; both compute to exactly 17pt/row. Every height below that's
    /// expressed as a row count derives from this.
    static let rowHeight: CGFloat = 17

    /// Which surfaces this section renders on at all.
    ///
    /// The window-only entries here were each moved out of the popover
    /// deliberately, for the same reason: they're scrollable history or
    /// niche per-device detail, cheap to reach via "Open in Window" and
    /// expensive to keep paying for in every popover-height trim. Stating
    /// it as data rather than an `if isInWindow` at the call site is what
    /// makes the popover's contents a closed, checkable list instead of
    /// "everything, minus whatever exclusions someone remembered."
    var surfaces: Set<Surface> {
        switch self {
        case .pathToInternet, .speedTest, .events:
            return [.popover, .window]
        case .wifi, .snmpDevices, .dhcpHistory, .printerAlerts:
            return [.window]
        }
    }

    func appears(on surface: Surface) -> Bool {
        surfaces.contains(surface)
    }

    /// Height of this section's fixed-height scroll box on a given
    /// surface, or `nil` if it has no box there.
    ///
    /// Fixed, not `maxHeight` — a `maxHeight` alone lets the scroll view
    /// shrink to fit however few rows currently exist, which made a
    /// single-entry list look identical to having no box at all, and in
    /// this `MenuBarExtra` context could collapse to zero visible height
    /// even with real content (both confirmed directly).
    func boxHeight(on surface: Surface) -> CGFloat? {
        guard appears(on: surface) else { return nil }
        switch (self, surface) {
        // Sized for the worst case (3+ hops, before an edge hop is
        // confirmed); below the threshold it renders as a plain VStack
        // instead, since a fixed box left visible blank space under the
        // usual 1-2 confirmed hops.
        case (.pathToInternet, .popover): return 60
        case (.pathToInternet, .window): return 150

        // Trimmed 90 → 56 (2 rows) when the popover measured about one
        // line too tall on the M1 Air. Worth knowing before trimming
        // here again: only the first ~17pt actually shortened the
        // popover. Total height is `max(leftColumn, rightColumn)`, and
        // this column (Info + Speed Test) was taller by about one row,
        // so a 34pt cut moved the total by 17 (846 → 829pt, measured via
        // `ContentView.liveHeight`) and left the *other* column binding.
        // Further shaving here buys nothing.
        case (.speedTest, .popover): return 56
        case (.speedTest, .window): return 140

        // 136 = 8 rows. Trimmed from 170 (10 rows) at `41e169c` — the
        // original MacBook Air fix, and the measurement that produced
        // `rowHeight` above.
        case (.events, .popover): return 136
        case (.events, .window): return 300

        // Taller than its neighbours because `sysDescr` wraps instead of
        // truncating and needs the extra room.
        case (.snmpDevices, .window): return 200

        // Only 4 real leases exist on the development network, so this is
        // deliberately short enough to confirm scrolling actually works
        // rather than just having room to spare.
        case (.dhcpHistory, .window): return 100

        // 3 rows, for a section asked to "support 2 printers" — a row of
        // headroom past the exact 2-row boundary rather than landing on
        // it, matching the convention the Speed Test trim above set. The
        // first cut was exactly 2 rows (34pt) and a same-day bug report
        // flagged it as possibly too tight; only 1 real printer was
        // available to test against, so the headroom stands in for the
        // measurement that couldn't be taken.
        case (.printerAlerts, .window): return Self.rowHeight * 3

        // Read-at-a-glance current state, not scrollable history — sizes
        // to its content, no box.
        case (.wifi, _): return nil

        // Unreachable given the `appears(on:)` guard above, but spelled
        // out rather than defaulted so adding a surface to `surfaces`
        // without adding its height fails to compile instead of silently
        // rendering an unboxed section.
        case (.pathToInternet, _), (.speedTest, _), (.events, _),
             (.snmpDevices, _), (.dhcpHistory, _), (.printerAlerts, _):
            return nil
        }
    }

    /// Row count above which this section switches from a plain,
    /// self-sizing `VStack` to its fixed-height scroll box.
    ///
    /// A box only earns its keep once there are more rows than fit —
    /// below that it just adds visible blank space under the real
    /// content. `0` means "always box once non-empty," which is the right
    /// answer for the sections whose row counts are unbounded in practice
    /// (events, discovered devices, configured printers) rather than
    /// typically 1-2 (a confirmed traceroute hop, a first speed test).
    ///
    /// These had drifted to three different values with no single
    /// statement of the rule; collecting them here is what made that
    /// visible. The values are unchanged from what each section did
    /// individually — this is a refactor, not a behaviour change.
    var scrollThreshold: Int {
        switch self {
        case .pathToInternet, .speedTest: return 3
        case .dhcpHistory: return 2
        case .events, .snmpDevices, .printerAlerts, .wifi: return 0
        }
    }

    /// Total fixed-height scroll-box space the popover spends, in points.
    ///
    /// This is the *whole* trimmable budget — everything else on the
    /// popover (the four-tile grid's label/value rows, section headers,
    /// dividers, the footer) has no trim mechanism at all. That's the
    /// arithmetic behind why repeated trimming kept not being enough:
    /// against a last-measured total of 846-860pt, this is the only part
    /// any trim could touch.
    static var popoverBoxTotal: CGFloat {
        allCases.reduce(0) { $0 + ($1.boxHeight(on: .popover) ?? 0) }
    }

    /// The ceiling `popoverBoxTotal` is not allowed to exceed without a
    /// deliberate decision.
    ///
    /// Deliberately a *regression guard*, not a physical limit: it's set
    /// to exactly today's total, so shrinking is free and any growth —
    /// a new popover section, or an existing box getting taller — fails
    /// the test and forces the trade-off to be made explicitly rather
    /// than discovered later on a smaller screen. The real physical
    /// ceiling is still unconfirmed (see `estimatedPopoverCeiling`).
    static let popoverBoxBudget: CGFloat = 252

    /// Rough estimate of a menu-bar popover's usable height on the M1
    /// MacBook Air (1280×800pt logical), the smallest screen this app is
    /// known to run on.
    ///
    /// **Unconfirmed.** Nobody has yet logged a `ContentView.liveHeight`
    /// reading while actually running on that machine, which is the
    /// number that would turn this estimate into a real, enforceable
    /// ceiling. Kept here rather than in a comment so the gap between
    /// "what we measured" and "what we're guessing" stays visible in the
    /// same place as the budget it's meant to inform.
    ///
    /// Note that the last recorded total (846-860pt) predates both DHCP
    /// History and SNMP Devices becoming window-only, so it overstates
    /// the current popover by roughly 90pt of boxes plus their headers
    /// and dividers — re-measuring is worth more than reasoning from it.
    static let estimatedPopoverCeiling: CGFloat = 770
}
