import SwiftUI

/// Shared building blocks for the tile grid — `tile()` (the bordered box
/// with a header row), `row(_:_:)` (a label/value line inside one), and
/// `externalLinkIcon` (the small "open in browser" icon button). Pulled
/// out of `ContentView` into a plain `View` extension so extracted tile
/// types (`EthernetTile` and friends — see the `ContentView` fan-in work
/// in `PUNCHLIST.md`) can use the exact same box styling, row layout, and
/// link icon `ContentView` itself still uses for the tiles that haven't
/// been extracted yet, without needing a `ContentView` instance to call
/// through. None of these ever touched any `ContentView` instance state
/// — moving them here changes nothing about their behavior.
extension View {
    /// A bordered box with a header row (title, plus an optional trailing
    /// accessory like "Trace Now") — the visual unit tiles in the grid
    /// above are built from. A plain `Divider()` no longer reads as a
    /// separator once two tiles sit side by side rather than stacked full
    /// width, so each tile draws its own border instead.
    @ViewBuilder
    func tile(title: String, fixedHeight: CGFloat? = nil, scrolls: Bool = true, @ViewBuilder content: () -> some View) -> some View {
        tile(title: title, fixedHeight: fixedHeight, scrolls: scrolls, trailing: { EmptyView() }, content: content)
    }

    /// `fixedHeight` fixes the *whole tile* to that height and makes
    /// `content()` scroll internally to fit whatever's left after the
    /// header row and padding — so content shorter than the tile just
    /// leaves blank space below it, and content taller than the tile
    /// scrolls instead of growing the box. One mechanism, applied
    /// uniformly, rather than syncing some tiles' heights to each other's
    /// content dynamically (the three earlier, more intricate attempts
    /// `ContentView.tileHeight`'s doc comment describes).
    ///
    /// **First version of this was broken, confirmed by a live
    /// screenshot**: every tile collapsed to just its header row, content
    /// invisible. The outer `.frame(maxHeight: fixedHeight)` only *caps*
    /// height — it doesn't force a smaller natural size to grow to fill
    /// it, so a `maxHeight` alone left the tile at whatever tiny size its
    /// (empty-looking) content produced.
    ///
    /// Fixed by making both heights explicit rather than relying on
    /// flexible-layout distribution: `minHeight == maxHeight` forces the
    /// outer tile to exactly `fixedHeight` (a cap alone can't shrink
    /// below content, but it also can't grow to it — matching both
    /// bounds is what actually fixes a size), and the inner scroll area
    /// gets a computed, explicit height (`fixedHeight` minus the header
    /// row and padding) rather than an unenforced "fill available space."
    ///
    /// `nil` (the default) keeps the old behavior: the tile sizes to its
    /// own content, no scrolling, no fixed height — still used by nothing
    /// today now that all four top tiles pass `ContentView.tileHeight`,
    /// but kept as the default rather than removed, since a future tile
    /// that genuinely wants to just size to its content shouldn't have to
    /// fake a height to get that.
    ///
    @ViewBuilder
    func tile(
        title: String,
        fixedHeight: CGFloat? = nil,
        scrolls: Bool = true,
        @ViewBuilder trailing: () -> some View,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let effectiveHeight = fixedHeight
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing()
            }
            // `scrolls: false` — raised directly, for tiles whose content
            // is genuinely bounded (a small, fixed row count defined in
            // code, not user data that can grow without limit) rather
            // than needing a scroll safety net the way Speed Test's
            // growing run history or Events' unbounded log do. Traded
            // deliberately: if this tile's content ever does grow past
            // `effectiveHeight`, there's no scroll fallback to catch it
            // — accepted, since the row count here is capped by a fixed,
            // known list, not something a user can expand.
            if let effectiveHeight, scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        content()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // An explicit number, not `.infinity` — see this
                // function's doc comment for why relying on automatic
                // flexible-space distribution didn't work here.
                // `ContentView.tileHeaderOverhead` is a first estimate
                // (padding + spacing + one `.headline` line), not
                // measured against a real screenshot — worth calibrating
                // precisely if this ever needs to be exact, though the
                // generous, scroll-absorbs-the-rest sizing this tile
                // already uses means it doesn't currently have to be.
                .frame(height: max(0, effectiveHeight - ContentView.tileHeaderOverhead))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        // `minHeight` and `maxHeight` both set to `effectiveHeight` forces
        // an exact size — `maxHeight` alone is only a cap, and doesn't
        // make a smaller natural size grow to fill it (the first bug this
        // function's doc comment describes). Both `nil` when
        // `effectiveHeight` is `nil` (including during a capture) is
        // still "no height constraint at all, size to content."
        .frame(maxWidth: .infinity, minHeight: effectiveHeight, maxHeight: effectiveHeight, alignment: .topLeading)
        .reportFrameForFieldTest("tile.\(title)")
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.25))
        }
    }

    /// One label/value line inside a tile — a secondary-styled label on
    /// the left, a selectable, middle-truncated value on the right.
    /// `help` is optional reference detail for a value that isn't
    /// self-explanatory (see `WiFiTile`'s PHY Rate row) — hover-only,
    /// same "tooltip, not a permanent caption" posture
    /// `QuickCheckDisplay.rpmThresholdHelp` already established. The
    /// label turns blue-and-underlined when `help` is set — raised
    /// directly ("I can never find them in NMS"), a plain `.help()`
    /// hover gives no visual cue a label has more info at all. Blue
    /// specifically because nothing else in this app's own color
    /// vocabulary uses it (status is green/yellow/red; `externalLinkIcon`
    /// is deliberately `.secondary`, not blue) — checked directly before
    /// picking it, not assumed free. Underline added on top, also raised
    /// directly: the classic web-link convention, already muscle memory
    /// for "this has more behind it" well beyond this one app. Gated by
    /// `FeatureFlags.tooltipHighlights` (on by default) rather than
    /// unconditional — see that flag's own doc comment.
    @ViewBuilder
    func row(_ label: String, _ value: String, help: String? = nil) -> some View {
        let highlight = help != nil && FeatureFlags.tooltipHighlights
        HStack {
            Text(label)
                .foregroundStyle(highlight ? .blue : .secondary)
                .underline(highlight)
            Spacer()
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        .help(optional: help)
    }

    /// Small "open in browser" icon button — first used by the SaaS
    /// monitoring section (this app's first-ever use of `Link`, confirmed
    /// safe under `ImageRenderer` capture); shared once Network Health's
    /// Local Router row and Info's ISP row needed the identical shape
    /// too, rather than a third near-copy of the same eight lines.
    @ViewBuilder
    func externalLinkIcon(url: String, accessibilityLabel: String, accessibilityHint: String) -> some View {
        if let url = URL(string: url) {
            Link(destination: url) {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
            // Same string as the VoiceOver hint above, shown as a real
            // hover tooltip too.
            .help(accessibilityHint)
        }
    }

    /// `.help(_:)` has no built-in optional overload — `nil` has to mean
    /// "no tooltip," not "a tooltip with empty text" (an empty string was
    /// tried first and risked showing an empty hover bubble;
    /// conditionally skipping the modifier entirely is the safe
    /// version). Added for `NetworkTile.statusGridRow`'s `dotHelp`
    /// parameter, most rows of which pass `nil`.
    @ViewBuilder
    func help(optional text: String?) -> some View {
        if let text {
            self.help(text)
        } else {
            self
        }
    }
}
