import Foundation
import SwiftUI
import Combine

/// A single fire-and-forget action, unlike every other view model here —
/// no `@Published` state to bind the UI to, just a place to own the
/// `SnapshotStore` reference so `ContentView` doesn't reach into it
/// directly (the same boundary every other view model maintains).
@MainActor
final class ScreenshotViewModel: ObservableObject {
    private let snapshotStore: SnapshotStore

    /// Fired when an `AppEventRecord` gets logged, so the event log view
    /// can refresh.
    var onEventLogged: (() -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    /// Renders `view` (the popover's own current content — see
    /// `ScreenshotService`) to a PNG and logs a `.screenshotCaptured`
    /// event naming the file, so it's findable later without guessing.
    /// Silently does nothing on failure — a local render/file-write
    /// failure is rare enough that it doesn't warrant its own
    /// user-visible error affordance.
    ///
    /// Both modifiers apply only to this rendered copy, never to the live
    /// popover `view` itself (SwiftUI modifiers don't mutate their
    /// source).
    ///
    /// `.buttonStyle(.plain)`: `ImageRenderer` doesn't reliably draw
    /// macOS's native bordered-button chrome when rendering off-screen —
    /// confirmed directly against a real capture, where every button
    /// (Refresh, Trace Now, Run Speed Test, Scan, Quit) rendered as a
    /// generic broken-image placeholder instead of its label. Plain
    /// style has no native bezel to fail to draw.
    ///
    /// `.background(...)`: the live popover's background belongs to the
    /// `MenuBarExtra` window, not to `ContentView`, so a detached render
    /// has none at all — every pixel the content doesn't cover comes out
    /// fully transparent, which reads as black and made all the
    /// default-colored (dark) text invisible in a real capture. Only
    /// explicitly-colored text (green/red events, the blue hostname
    /// link) survived. `windowBackgroundColor` is the same system color
    /// the real popover window uses, so the capture matches what's on
    /// screen rather than approximating it.
    func capture(_ view: some View) {
        let renderable = view
            .buttonStyle(.plain)
            .background(Color(nsColor: .windowBackgroundColor))
        guard let filename = ScreenshotService.capture(renderable) else { return }
        snapshotStore.logEvent(.screenshotCaptured, message: "Screenshot saved: \(filename)")
        onEventLogged?()
    }
}
