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
///    floor-clamped the window to its full content height. Confirmed
///    broken on the M1 MacBook Air specifically: the window was taller
///    than the screen, with no way to reach the lower half at all.
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
///    Disabling elasticity on the outer container too (this type, without
///    `persistentScrollbar`) fixed that — but scroll-wheel *chaining* from
///    an exhausted tile into the outer container turned out to behave
///    inconsistently across input devices: fine on a trackpad, unreliable
///    with a Magic Mouse.
///
/// `persistentScrollbar` exists because of that last point, combined with
/// design 1's MacBook Air finding: outer scrolling can't be optional (a
/// window taller than the screen needs *some* way to reach the rest), but
/// scroll-wheel chaining can't be the only way to do it, since it isn't
/// reliable on every device. A `.legacy` scroller is always visible and
/// occupies real width rather than overlaying content, so its thumb can be
/// grabbed directly — a `mouseDown`/`mouseDragged` interaction on the
/// `NSScroller`, entirely separate from `scrollWheel(with:)`, and so
/// unaffected by the chaining inconsistency. That's the reliable path for
/// reaching content below the fold; wheel-scrolling over the gaps between
/// tiles (and chaining out of an exhausted tile) still works too, just
/// isn't the only way anymore.
struct NoBounceScrollView<Content: View>: NSViewRepresentable {
    private let content: Content
    private let persistentScrollbar: Bool

    init(persistentScrollbar: Bool = false, @ViewBuilder content: () -> Content) {
        self.persistentScrollbar = persistentScrollbar
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        if persistentScrollbar {
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
        }

        let hostingView = NSHostingView(rootView: AnyView(content))
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
        context.coordinator.hostingView?.rootView = AnyView(content)
    }

    func makeCoordinator() -> NoBounceScrollCoordinator { NoBounceScrollCoordinator() }
}

/// Deliberately declared at the top level, not nested inside
/// `NoBounceScrollView<Content>`. A version of this class nested inside
/// that generic struct — even after its stored property was type-erased
/// to remove `Content` from the picture — crashed `swift-frontend` itself
/// during Release/Archive builds: a real compiler bug in the optimizer's
/// `EarlyPerfInliner` pass on the class's synthesized `deinit`, confirmed
/// by the crash log naming the exact same mangled symbol
/// (`NoBounceScrollView.Coordinator.deinit`) both before and after that
/// property was type-erased. That ruled out the property type as the
/// trigger — it's the nesting itself, a class with its own `deinit` living
/// inside a generic type's lexical scope, that the inliner chokes on. The
/// crash is invisible in Debug builds, which skip optimization (`-Onone`)
/// entirely. Moving the class out to the top level sidesteps it.
final class NoBounceScrollCoordinator {
    var hostingView: NSHostingView<AnyView>?
}
