import SwiftUI

/// Shared building blocks that survive the popover conversion's tile
/// deletion — `row(_:_:)` (a label/value line), still needed by
/// `KnownNetworksView`, and `.help(optional:)`, `row`'s own dependency.
/// `tile()`/`externalLinkIcon()` were removed alongside the tiles that
/// were their only callers (popover conversion, Phase 4) — every window
/// tile is gone, replaced by the popover and the web pages
/// `LocalDiagnosticServer` renders.
extension View {
    /// One label/value line — a secondary-styled label on the left, a
    /// selectable, middle-truncated value on the right. `help` is
    /// optional reference detail for a value that isn't self-explanatory
    /// — hover-only, a "tooltip, not a permanent caption" posture. The
    /// label turns blue-and-underlined when `help` is set — raised
    /// directly ("I can never find them in NMS"), a plain `.help()`
    /// hover gives no visual cue a label has more info at all. Blue
    /// specifically because nothing else in this app's own color
    /// vocabulary uses it (status is green/yellow/red) — checked
    /// directly before picking it, not assumed free. Underline added on
    /// top, also raised directly: the classic web-link convention,
    /// already muscle memory for "this has more behind it" well beyond
    /// this one app. Gated by `FeatureFlags.tooltipHighlights` (on by
    /// default) rather than unconditional — see that flag's own doc
    /// comment.
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

    /// `.help(_:)` has no built-in optional overload — `nil` has to mean
    /// "no tooltip," not "a tooltip with empty text" (an empty string was
    /// tried first and risked showing an empty hover bubble;
    /// conditionally skipping the modifier entirely is the safe
    /// version). `row(_:_:help:)` above is this function's own caller,
    /// most of whose rows pass `nil`.
    @ViewBuilder
    func help(optional text: String?) -> some View {
        if let text {
            self.help(text)
        } else {
            self
        }
    }
}

/// Composes a tooltip from an always-shown plain explanation and an
/// optional mechanism-level clause, appended only when
/// `FeatureFlags.tooltipTechnicalDetail` is on — one adaptive string, not
/// two independent copies of the same fact that could quietly drift
/// apart (same "one source of truth" reasoning `rpmThresholdHelp`
/// already established). See PUNCHLIST.md's "expert mode and a calmer
/// mode" entry for the bigger, not-yet-decided version of this same
/// split.
func tooltip(_ base: String, technical: String) -> String {
    FeatureFlags.tooltipTechnicalDetail ? "\(base) \(technical)" : base
}
