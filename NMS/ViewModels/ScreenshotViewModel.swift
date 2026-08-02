import Foundation
import SwiftUI
import AppKit
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
    /// `.textFieldStyle(.plain)`: found via a real bug report whose own
    /// screenshot showed a `TextField` (`.roundedBorder` on the live
    /// view) rendering as a solid yellow bar with a red "prohibited"
    /// glyph instead of any text — the same category of native-chrome
    /// gap as the button case above. **Kept, but confirmed insufficient
    /// on its own** — a second real capture with this modifier already
    /// applied showed the identical glitch, so whatever `ImageRenderer`
    /// is doing here goes deeper than border styling (plausibly trying
    /// to draw a live insertion-point/field-editor for a field with no
    /// real focus/window context off-screen). Left in place as cheap
    /// insurance for any `TextField` this doesn't fully cover, but the
    /// actual fix for Bug Report's field is in `ContentView.bugReportRow`:
    /// swap to a plain `Text` during capture rather than asking
    /// `ImageRenderer` to draw the control at all — see that type's own
    /// comment.
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
    /// Logs the popover's actual on-screen height — see
    /// `ScreenshotService.measureHeight` for why this has to be a
    /// separate render from `capture` below rather than reading its
    /// result, and why a screenshot's own size can't answer this.
    ///
    /// Piggybacks on the screenshot button rather than running on a timer
    /// or at launch: clicking it is already a deliberate, recurring action
    /// (confirmed by the real event history — dozens of `screenshotCaptured`
    /// entries across this project's life), so logging one more number
    /// alongside it costs nothing new to trigger and builds a real history
    /// of this popover's height over time for free. `view` must be the
    /// live, unmutated copy — call this before applying
    /// `isCapturingScreenshot = true` for the actual capture below, not
    /// after.
    /// `surface` is not decoration. This is called from `footerBar`, which
    /// renders on *both* surfaces, so a camera click in the resizable
    /// window measured that window and logged it under the same bare label
    /// as a popover reading — leaving a history whose entries can't be
    /// told apart, for a metric whose entire purpose is answering "does
    /// the popover still fit the smallest screen." Only `.popover`
    /// readings answer that question; a `.window` reading is a number
    /// about a user-resizable window, which has no ceiling to breach.
    func measureAndLogLiveHeight(_ view: some View, surface: Surface) {
        guard let height = ScreenshotService.measureHeight(view) else { return }
        UIStateLogger.log(
            "ContentView.liveHeight",
            String(format: "%@ %.0fpt", surface.rawValue, height)
        )
    }

    func capture(_ view: some View) {
        let renderable = view
            .buttonStyle(.plain)
            .textFieldStyle(.plain)
            .background(Color(nsColor: .windowBackgroundColor))
        guard let filename = ScreenshotService.capture(renderable) else { return }

        // One click, two artifacts, sharing a timestamp — deliberate.
        // The recurring debugging question isn't "what did the UI look
        // like" or "what was in the store," it's whether those two
        // *agree*: a value can be stale in the view, or correct in the
        // view and absent from the store. Capturing them separately
        // means capturing them at different moments, which is precisely
        // when a mismatch stops being evidence. Debug builds only — see
        // `StoreInspector`.
        if let dump = snapshotStore.dumpState() {
            UIStateLogger.log("StoreInspector", "state dump saved: \(dump)")
        }

        snapshotStore.logEvent(.screenshotCaptured, message: "Screenshot saved: \(filename)")
        onEventLogged?()
    }

    /// Same bundle as `capture(_:)` — same screenshot, same DEBUG-only
    /// state dump, same shared timestamp — plus the one thing neither
    /// artifact can supply on its own: what the user actually observed.
    /// `comment` is the reason this is a separate button rather than a
    /// prompt bolted onto the existing one — that button's whole value is
    /// staying a fast, no-prompt capture; this one is deliberately "stop
    /// and say what's wrong."
    ///
    /// `buildInfo`/`severityDescription` are passed in rather than
    /// resolved here because both already exist as `ContentView`
    /// properties (`buildInfo` directly; severity via `OverallStatus
    /// .compute`, duplicated there rather than threaded through
    /// `NMSApp.contentView(surface:)` as a new parameter — see that
    /// call site's comment for why touching that wiring is treated as a
    /// bigger cost than a one-line formula repeated twice).
    ///
    /// Unlike `capture(_:)`'s message (just the filename — the dump has
    /// no reader-facing content of its own to summarize), this event's
    /// `message` carries the comment itself, so it's directly readable
    /// from the Events list without needing to open any file at all —
    /// `.lineLimit(1)`/`.truncationMode(.middle)` there already handle a
    /// comment too long to fit on one line, same as every other event
    /// row.
    func captureBugReport(_ view: some View, comment: String, buildInfo: BuildInfoService.Info?, severityDescription: String) {
        let renderable = view
            .buttonStyle(.plain)
            .textFieldStyle(.plain)
            .background(Color(nsColor: .windowBackgroundColor))
        guard let filename = ScreenshotService.capture(renderable) else { return }

        let buildLine = buildInfo.map { "Build \($0.shortHash)\($0.isDirty ? "+dirty" : "")" } ?? "Build unknown"
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)

        let header = "\(buildLine) · \(severityDescription)\nComment: \(trimmedComment.isEmpty ? "(none)" : trimmedComment)\n"
        if let dump = snapshotStore.dumpState(header: header) {
            UIStateLogger.log("StoreInspector", "bug report dump saved: \(dump)")
        }

        let summary = trimmedComment.isEmpty ? "no comment" : trimmedComment
        snapshotStore.logEvent(
            .bugReportCaptured,
            message: "\(buildLine) · \(severityDescription): \(summary) (\(filename))"
        )
        onEventLogged?()

        // Off-main: `BugReportExportService.export` shells out to `zip`
        // and blocks on `waitUntilExit()`. Release-build-safe (see that
        // type's own doc comment) — this is for a friend testing the app
        // to actually hand the report to someone, not a debug tool.
        DispatchQueue.global(qos: .utility).async {
            guard let zipURL = BugReportExportService.export(screenshotFilename: filename, header: header) else { return }
            Task { @MainActor in
                NSWorkspace.shared.activateFileViewerSelecting([zipURL])
            }
        }
    }
}
