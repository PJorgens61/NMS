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
/// **Now every case is window-only** (see `surfaces`'s doc comment for
/// the audience-split reasoning), so `popoverBoxTotal` is `0` and this
/// table's job for the popover specifically has shifted from "budget the
/// trimmable space" to "confirm there's none left to budget." Kept as a
/// table rather than deleted: window heights and thresholds are still
/// real, still shared, and still worth having in one place rather than
/// scattered back into `ContentView`.
///
/// **Not every section is listed.** Network Health and Info are
/// unconditional label/value tiles with no fixed-height box, rendered on
/// both surfaces all the time — nothing to declare and nothing to
/// budget. Only sections that are either surface-conditional or
/// box-bearing appear here.
enum SectionLayout: String, CaseIterable, Sendable {
    case pathToInternet
    case speedTest
    case events
    case wifi
    case snmpDevices
    case dhcpHistory
    case printerAlerts
    case saasMonitoring

    /// Which surfaces this section renders on at all.
    ///
    /// **The audience split.** Every case here is window-only. The popover
    /// used to carry the full four-tile grid (Network Health, Info, Path
    /// to Internet, Speed Test) plus Events — "the same content, one
    /// surface just has more room." That framing was deliberately
    /// abandoned: the popover is now scoped to "can I work, what's
    /// restricted" (Network Health's status rows, plus Info for which
    /// network you're on), and everything diagnostic — root cause,
    /// history, on-demand tests — lives only in the window. Network
    /// Health and Info aren't listed in this enum precisely because nothing
    /// about them is surface-conditional anymore: they're the two tiles
    /// that render unconditionally in `ContentView.scrollableContent`,
    /// on both surfaces, all the time.
    ///
    /// This is the natural conclusion of a question `DESIGN-NOTES.md`'s
    /// "Business SaaS monitoring" section left half-resolved: a
    /// business-minded read wants "can I work, what's restricted," while
    /// an IT-minded read wants root cause and specificity, and the
    /// original resolution was interaction depth ("headline stays simple,
    /// detail lives one level down via drill-down") within one surface.
    /// Splitting by *surface* instead — popover versus window — is a
    /// cleaner version of that same resolution, not a new idea; see
    /// `PUNCHLIST.md`'s "Split by audience" entry for the full reasoning
    /// and the open questions this closed.
    ///
    /// Stating it as data rather than an `if isInWindow` at the call site
    /// is what makes the popover's contents a closed, checkable list
    /// instead of "everything, minus whatever exclusions someone
    /// remembered" — which is exactly what let SNMP Devices and DHCP
    /// History keep dead popover heights the first time sections moved
    /// window-only (see this type's own history, `git blame`).
    var surfaces: Set<Surface> {
        switch self {
        case .pathToInternet, .speedTest, .events,
             .wifi, .snmpDevices, .dhcpHistory, .printerAlerts, .saasMonitoring:
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
        // No longer boxed via `scrollBox`/this table at all — Network
        // Health, Info, Path to Internet, and Speed Test now all share
        // one fixed height declared once, `ContentView.tileHeight`, with
        // `tile(fixedHeight:)` handling the internal scrolling directly.
        // That single mechanism replaced this table's per-pair-matched
        // 140/140 values (see `ContentView.tileHeight`'s doc comment for
        // the three earlier, more intricate attempts this consolidated),
        // so returning `nil` here is the same "no box declared here"
        // answer `wifi` below already gives, not a new exception.
        case (.pathToInternet, _), (.speedTest, _): return nil

        // These four don't need to match each other — unlike
        // `ContentView.tileHeight`'s pair, none of these sit side by side
        // with another, so there's no bottom-edge-alignment bug motivating
        // one shared number. What does still apply is the same lesson that
        // fixed the top row: a box the window always scrolls doesn't need
        // to be measured to fit any particular row count exactly (a lease
        // count, a printer count) — that just recreates the "recalibrate
        // every time content changes" problem for a different set of
        // sections. Picked generously round instead, each independently,
        // rather than trimmed to the row count on hand at the time.
        case (.events, .window): return 350
        // 250 originally — bumped to give the list more room before it
        // needs to scroll, on request. See `NoBounceScrollView`'s doc
        // comment for the box-scrolling issue found alongside this.
        case (.snmpDevices, .window): return 300
        case (.dhcpHistory, .window): return 150
        case (.printerAlerts, .window): return 85
        // Both were previously "read-at-a-glance current state, sizes to
        // its content, no box" — reversed after offsite testing asked for
        // every window section to scroll uniformly rather than some
        // boxed and some not. `saasMonitoring` in particular is no longer
        // guaranteed to stay a fixed 3-service list now that users can
        // add their own sites to monitor (see `PUNCHLIST.md`).
        case (.wifi, .window): return 130
        case (.saasMonitoring, .window): return 150

        // Unreachable given the `appears(on:)` guard above (every case
        // here is window-only as of the audience split, so `.popover`
        // never reaches the switch) — spelled out rather than defaulted
        // so adding a surface to `surfaces` without adding its height
        // fails to compile instead of silently rendering an unboxed
        // section. `pathToInternet`/`speedTest` aren't repeated here —
        // they already match every surface via the first case above.
        case (.events, _), (.snmpDevices, _), (.dhcpHistory, _), (.printerAlerts, _),
             (.wifi, _), (.saasMonitoring, _):
            return nil
        }
    }

    /// Total fixed-height scroll-box space the popover spends, in points.
    ///
    /// **`0` as of the audience split**, and that is now the point of this
    /// property rather than an interesting fact about it: the popover
    /// used to spend 252pt here (Events 136 + Speed Test 56 + Path to
    /// Internet 60) against a ~600pt tile grid and footer that had no
    /// trim mechanism at all — the arithmetic behind why repeated
    /// trimming kept not being enough. Scoping every box-bearing section
    /// to the window removed the scrollable content entirely rather than
    /// continuing to shave it, so this is expected to read `0` and the
    /// regression this guards against is a *new* box-bearing section
    /// landing on the popover, not this number creeping back up from
    /// zero.
    static var popoverBoxTotal: CGFloat {
        allCases.reduce(0) { $0 + ($1.boxHeight(on: .popover) ?? 0) }
    }

    /// The ceiling `popoverBoxTotal` is not allowed to exceed without a
    /// deliberate decision.
    ///
    /// Deliberately a *regression guard*, not a physical limit: pinned to
    /// exactly today's total (`0`), so any box-bearing section landing on
    /// the popover again — the exact shape of the recurring problem this
    /// type exists to catch — fails the test and forces that trade-off to
    /// be made explicitly. Before the audience split this was the
    /// trimmable total (252pt); see `git blame` for that history if it's
    /// useful context for a future change.
    static let popoverBoxBudget: CGFloat = 0

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
    /// The last recorded total (846-860pt) predates DHCP History and SNMP
    /// Devices becoming window-only, and now also predates the audience
    /// split removing Events/Path to Internet/Speed Test from the popover
    /// entirely — it significantly overstates today's popover, which is
    /// down to two tiles and a footer. Still worth an actual
    /// `liveHeight` reading rather than assuming the ceiling question is
    /// closed just because the content shrank; a real number is cheap
    /// (one camera click) and this estimate has been wrong in this
    /// direction before.
    static let estimatedPopoverCeiling: CGFloat = 770
}
