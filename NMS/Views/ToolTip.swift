import SwiftUI
import AppKit

/// A hover tooltip that actually works inside `MenuBarExtra(.window)`.
///
/// Named for the mechanism rather than the effect, because the mechanism
/// is the whole point: **SwiftUI's own `.help(_:)` renders nothing at all
/// in this popover.** That was spiked directly — two `.help()` calls, one
/// on a plain Info row and one on every Network Health layer row,
/// confirmed present in the running binary, hovered, and no tooltip
/// appeared in either case. An AppKit `NSView.toolTip` overlaid in the
/// same place, on the same row, works. Anyone reaching for `.help()`
/// here will find it silently does nothing; use this instead.
///
/// That makes three `MenuBarExtra(.window)`-specific SwiftUI gaps in this
/// app, after the menu bar icon silently ignoring `.foregroundStyle`
/// (see `NMSApp.statusIcon`) and `ImageRenderer` refusing to render
/// `ScrollView` content (see `ScreenshotService`). See DESIGN-NOTES.md's
/// "UI tooltips".
///
/// `PassthroughView` overrides `hitTest` to always return `nil` — without
/// it, a stock `NSView` overlay returns *itself* from the default
/// `hitTest(_:)` for any point inside its bounds, silently swallowing
/// every click on whatever SwiftUI content sits underneath. Confirmed
/// directly: after `externalLinkIcon` started overlaying this tooltip,
/// every `Link` it wraps (Router, ISP, SNMP device admin pages) stopped
/// opening a browser in both the popover and the Expert Mode window —
/// hovering still worked (a tooltip's tracking area is independent of
/// hit-testing), so this went unnoticed until someone actually clicked
/// one. `.textSelection(.enabled)` on the value rows was verified
/// working before this fix too, so the swallowed-click risk this
/// override exists to remove was real, not hypothetical.
private struct AppKitToolTip: NSViewRepresentable {
    let text: String

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

extension View {
    /// Attaches a native hover tooltip. Use in place of `.help(_:)`,
    /// which does not work in this app's popover — see `AppKitToolTip`.
    ///
    /// `enabled` exists for one specific caller: the screenshot capture
    /// must pass `false`. `ImageRenderer` cannot render an
    /// `NSViewRepresentable` and substitutes a placeholder graphic for
    /// the entire view it's attached to — so a tooltip added to the DHCP
    /// detail line and the SNMP status dots replaced both with yellow
    /// broken-image blocks in the capture, destroying exactly the
    /// content those captures exist to show. Caught by reading a real
    /// capture after adding the tooltips; it is not visible from hovering
    /// the live popover, where everything looks correct.
    ///
    /// The same failure mode as native buttons in a capture (see
    /// `ScreenshotViewModel.capture`, which forces `.buttonStyle(.plain)`
    /// for the same reason). Losing hover text in a still image costs
    /// nothing — nobody hovers a PNG.
    @ViewBuilder
    func appKitToolTip(_ text: String, enabled: Bool = true) -> some View {
        if enabled {
            overlay(AppKitToolTip(text: text))
        } else {
            self
        }
    }
}
