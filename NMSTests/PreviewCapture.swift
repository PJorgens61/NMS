import Testing
import SwiftUI
import AppKit
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
/// **Scope, confirmed empirically, not assumed:** works for a
/// self-contained view (a bare `Text`, a hand-built tile-shaped box with
/// padding/fixed-height/`.overlay`). Crashes the test-host process for
/// `ContentView`'s full `body` *and* for `scrollableContent` alone
/// (i.e. even with `body`'s own `ScrollView`/`.coordinateSpace(name:
/// "nmsWindow")` removed) — narrowed that far and stopped there; the
/// exact trigger inside `scrollableContent`'s real tiles/view-model
/// graph (a specific `Grid`, `Sparkline`, or side-effecting view model)
/// isn't identified. See `PUNCHLIST.md`'s "ImageRenderer-based preview
/// capture" entry for that and the other deferred options.
///
/// **What this means in practice**: edit `viewToCapture` below to
/// whatever specific, self-contained view needs a look right now --
/// one real tile's content, a hand-built reproduction of a layout
/// question, etc. Not a "render any tile by name" system; a starting
/// point for that specific render, adjusted each time it's used.
@Suite("Preview capture (manual only, see script/capture-preview.sh)")
struct PreviewCaptureTests {
    private struct Request: Decodable {
        let outputPath: String
        let width: Double
        let height: Double
    }

    private static let requestURL = URL(fileURLWithPath: "/tmp/nms-capture-request.json")

    /// Edit this to whatever needs rendering right now. Left as the
    /// confirmed-working example (a hand-built tile-shaped box) rather
    /// than a real `ContentView` tile, since none of `ContentView`'s
    /// real tiles are reachable in isolation today — they're
    /// constructed inline in `scrollableContent`, not as separately
    /// named properties, and `scrollableContent` itself is one of the
    /// two confirmed-crashing cases above.
    @MainActor
    @ViewBuilder
    private static var viewToCapture: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostic").font(.headline)
            Text("Edit PreviewCaptureTests.viewToCapture to render something else.")
                .font(.system(size: 12))
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .topLeading)
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
