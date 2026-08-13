import Testing
import SwiftUI
import AppKit
import SwiftData
@testable import NMS

/// Renders a SwiftUI view straight to a PNG via `ImageRenderer` — no app
/// launch, no AppleScript, no screenshot. Built after `Iron-Ham/
/// XcodePreviews` (an iOS-Simulator-based preview-capture tool trialed
/// this session) turned out not to apply here: NMS is macOS-only, with
/// no simulator to launch into. `ImageRenderer` needs none — it renders
/// natively for whatever platform it's compiled for.
///
/// **A no-op during every routine test run** (`test-quick.sh`,
/// `test-max.sh`, or a bare `xcodebuild test`) — gated on a request file
/// at `/tmp/nms-capture-request.json`, absent in all of those. Run
/// explicitly via `script/capture-preview.sh`, which writes that file
/// and scopes the run to just this one test with `-only-testing:`.
///
/// **Reads configuration from a file, not an environment variable.** A
/// first version used `ProcessInfo.processInfo.environment` — set by
/// the invoking shell, but `xcodebuild test` doesn't forward the
/// invoking shell's environment into the actual test-host process it
/// launches, confirmed directly (the env var read back empty inside the
/// test even though the shell that ran `xcodebuild` had it set). A file
/// on the shared filesystem crosses that process boundary with no such
/// gap. A literal `/tmp/...` path, not `NSTemporaryDirectory()`, for the
/// same reason -- not trusting this process's notion of "the temp
/// directory" to resolve to the same place the invoking shell's does.
///
/// **Scope, confirmed empirically, not assumed -- and it's a race, not
/// a single trigger.** Bisected step by step (2026-08-04): a bare
/// `Text` works; a hand-built tile-shaped box (padding/fixed-height/
/// `.overlay`) works; a bare `Grid` works; a `.task` that mutates
/// `@State` on appear works. But `ContentView`'s full `body`,
/// `scrollableContent` alone, and even the Network tile alone (via a
/// real `ContentView` instance from `ContentViewPreviewSupport
/// .makeContentView()`) all crashed the test-host process --
/// and then, rendering that same *known-safe* tile-shaped box while
/// simply keeping that real instance alive in scope (nothing of its
/// content rendered), the run crashed once and then succeeded
/// identically on xctest's automatic retry.
///
/// That's the tell: `ContentViewPreviewSupport.makeContentView()`
/// constructs all 17 real view models with their real side effects
/// (background timers, subprocess spawns -- see that function's own
/// doc comment), and `ImageRenderer` expects to snapshot a static tree
/// synchronously. If one of those background effects fires mid-render
/// and touches `@Published`/`@State`, it crashes; if not, it doesn't.
/// Longer/heavier renders (the real `ContentView`) reliably lose that
/// race; short, simple ones usually win it, which is why the isolated
/// examples above read as "safe" until one wasn't. There's no single
/// line to fix -- see `PUNCHLIST.md`'s "ImageRenderer-based preview
/// capture" entry for what a real fix would need (most likely: a way
/// to render against inert/stub view models with no live side effects,
/// rather than the real object graph this reuses from Xcode's own
/// canvas preview).
///
/// **What this means in practice**: edit `viewToCapture` below to
/// whatever specific, self-contained view needs a look right now --
/// something with no dependency on the real, side-effecting view-model
/// graph. Not a "render any real tile with real data" system; a
/// starting point for a specific, isolated render, adjusted each time
/// it's used.
// Nested under `SwiftDataTestGroup` (`NMSTests.swift`) so this suite's own
// `ModelContainer` creation is serialized against every other SwiftData-
// touching suite, not just internally -- see that type's own doc comment.
extension SwiftDataTestGroup {

@Suite("Preview capture (manual only, see script/capture-preview.sh)")
struct PreviewCaptureTests {
    private struct Request: Decodable {
        let outputPath: String
        let width: Double
        let height: Double
    }

    private static let requestURL = URL(fileURLWithPath: "/tmp/nms-capture-request.json")

    /// Edit this to whatever needs rendering right now. Its previous
    /// target -- `NetworkTile`'s `Grid` (`QuickCheckRow`/
    /// `ConnectionLayerRow`/`statusGridRow`) -- no longer exists: that
    /// whole native tile was deleted in the popover conversion's tile
    /// migration (Phase 4), replaced by the popover and `/network`. Reset
    /// to a minimal, self-contained placeholder rather than left
    /// referencing deleted types; the next real use should follow the
    /// same "no live side-effecting view models" discipline documented
    /// above, e.g. a fixture-driven render of a `MenuBarView` row rather
    /// than the real popover with its real view-model graph.
    @MainActor
    @ViewBuilder
    private static var viewToCapture: some View {
        Text("Edit viewToCapture with whatever needs a look right now.")
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25))
            }
    }

    @Test("render viewToCapture to a PNG when a capture request file is present")
    @MainActor
    func captureView() throws {
        guard let data = try? Data(contentsOf: Self.requestURL),
              let request = try? JSONDecoder().decode(Request.self, from: data)
        else {
            return
        }

        let renderer = ImageRenderer(
            content: Self.viewToCapture.frame(width: request.width, height: request.height)
        )
        // 2x, matching this Mac's own Retina screenshots elsewhere in this
        // project (script/capture-doc-scenarios.sh) -- a 1x render reads
        // noticeably softer for text-heavy content like this.
        renderer.scale = 2.0

        let image = try #require(renderer.nsImage, "ImageRenderer produced no image")
        let tiff = try #require(image.tiffRepresentation, "NSImage had no TIFF representation")
        let bitmap = try #require(NSBitmapImageRep(data: tiff), "TIFF data wasn't a valid bitmap")
        let png = try #require(bitmap.representation(using: .png, properties: [:]), "Failed to encode PNG")

        try png.write(to: URL(fileURLWithPath: request.outputPath))
    }
}

} // extension SwiftDataTestGroup (PreviewCaptureTests)
