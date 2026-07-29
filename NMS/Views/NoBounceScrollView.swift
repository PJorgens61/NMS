import SwiftUI
import AppKit

/// A drop-in replacement for SwiftUI's `ScrollView`, used both for every
/// fixed-height history box in `ContentView` (Events, SNMP Devices, DHCP
/// History, Speed Test, traceroute hops) and for the outer container of
/// the comparison window itself (see `NMSApp`) — every scrollable region
/// in that window, nested or not.
///
/// Three designs came before this one, each solving one problem while
/// reintroducing another:
/// 1. No outer `ScrollView` at all — fixed the tile boxes bouncing, but
///    floor-clamped the window to its full content height, unable to
///    shrink.
/// 2. A plain `NSScrollView` wrapper that severed `nextResponder` during
///    `scrollWheel(with:)` — restored shrinking and killed the bounce, but
///    also killed the pass-through: scrolling past a tile's own limit did
///    nothing instead of continuing into the window's scroll, so the
///    window could only be scrolled from the narrow gaps between tiles.
/// 3. `verticalScrollElasticity = .none` on just the tile boxes, with a
///    plain SwiftUI `ScrollView` (`.scrollBounceBehavior(.basedOnSize)`)
///    for the outer container — chaining and per-tile bounce were both
///    fixed, but Speed Test and DHCP History (near the very top and
///    bottom of the whole document) still visibly bounced, because
///    forwarded scroll from them reached the outer view's own *genuine*
///    edge, where `.basedOnSize` still allows the native elastic bounce.
///
/// The fix that actually works: disable elasticity everywhere, tile boxes
/// and the outer container alike. `verticalScrollElasticity = .none`
/// doesn't touch the responder chain — chaining still works, proven by
/// Events (in the middle of the document) already scrolling seamlessly
/// into the outer view under design 3 — it only removes the rubber-band
/// visual, which was the actual complaint everywhere it showed up.
struct NoBounceScrollView<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView
        // Leading/trailing/top only — not bottom — so the hosting view's
        // width tracks the scroll view's visible width while its height
        // stays intrinsic to the content, which is what lets the
        // NSScrollView compute a real scrollable document height.
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])
        context.coordinator.hostingView = hostingView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.hostingView?.rootView = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }
}
