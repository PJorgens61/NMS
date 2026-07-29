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
    /// `.buttonStyle(.plain)` applies only to this rendered copy, never
    /// to the live popover `view` itself (SwiftUI style modifiers don't
    /// mutate their source). Needed because `ImageRenderer` doesn't
    /// reliably draw macOS's native bordered-button chrome when
    /// rendering off-screen — confirmed directly against a real capture,
    /// where every button (Refresh, Trace Now, Run Speed Test, Scan,
    /// Quit) rendered as a generic broken-image placeholder instead of
    /// its label. Plain style has no native bezel to fail to draw.
    func capture(_ view: some View) {
        guard let filename = ScreenshotService.capture(view.buttonStyle(.plain)) else { return }
        snapshotStore.logEvent(.screenshotCaptured, message: "Screenshot saved: \(filename)")
        onEventLogged?()
    }
}
