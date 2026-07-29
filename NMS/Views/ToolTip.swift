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
/// Deliberately no `hitTest` override: an overlay that swallowed mouse
/// events would silently break `.textSelection(.enabled)` on the value
/// rows, which exists so an address can be copied mid-troubleshooting.
/// Verified by dragging across a tooltipped row's value — selection
/// still works as-is, so suppressing hit-testing would be solving a
/// problem that doesn't exist.
private struct AppKitToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
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
