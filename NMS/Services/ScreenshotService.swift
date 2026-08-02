import SwiftUI
import AppKit

/// Renders the popover's current SwiftUI view tree directly to a PNG,
/// entirely in-memory — not a screen capture. That distinction matters:
/// a real screen capture (`screencapture`/`CGWindowListCreateImage`)
/// needs Screen Recording permission and grabs actual on-screen pixels,
/// which risks capturing whatever else happens to be on screen at the
/// same moment (confirmed the hard way earlier in this app's history —
/// an external capture attempt grabbed the whole desktop, other windows
/// included, instead of just the popover). `ImageRenderer` (macOS 13+)
/// renders the view's own layout instead, so what's saved is exactly the
/// popover's content and nothing else, with no permission prompt at all.
///
/// **At least four `ImageRenderer` quirks the caller has to work
/// around**, all found by reading real output rather than assumed. The
/// first three are handled centrally in `ScreenshotViewModel.capture`
/// (which is why this type takes an already-prepared view and does
/// nothing clever itself); the fourth needed its own fix at each
/// affected call site instead, since it's not something a shared
/// modifier applied here can reach:
///
/// 1. `ScrollView` content doesn't render *at all* off-screen — not
///    clipped, absent. Hence `ContentView.isCapturingScreenshot`, which
///    swaps every scrollable section for a plain unclipped list.
/// 2. Native bordered buttons render as broken-image placeholders.
///    Hence `.buttonStyle(.plain)`.
/// 3. There's no implicit background — the popover's real one belongs to
///    the `MenuBarExtra` window, not to `ContentView` — so an
///    unmodified render is fully transparent. Hence an explicit
///    `.background(...)`.
/// 4. Any `NSViewRepresentable` (a `TextField` even with
///    `.textFieldStyle(.plain)`, and separately `NoBounceScrollView`)
///    renders as a solid yellow bar with a red "prohibited" glyph
///    instead of its real content — confirmed deeper than border/bezel
///    styling, since `.plain` alone didn't fix the `TextField` case.
///    No shared fix is possible here the way 1-3 have one: each site
///    swaps to a plain, capture-only substitute instead (`Text` in place
///    of `TextField` in `ContentView.bugReportRow`; an unclipped `VStack`
///    in place of `NoBounceScrollView` in `ContentView.tile(fixedHeight:)`
///    and `scrollBox`) — this is the "the capture branch is easy to
///    forget, and forgetting it fails silently" bug class those two
///    types' own doc comments describe, and it has recurred more than
///    once precisely because the fix can't live in one place the way
///    quirks 1-3's can.
///
/// See DESIGN-NOTES.md's "Popover screenshot button" for how the first
/// three were diagnosed, including one attempted fix (`@Environment`)
/// that was built, disproved by logging, and reverted.
struct ScreenshotService {
    // Not `private` — `BugReportExportService` needs the real file this
    // resolves to, to bundle it into a shareable zip. One source of
    // truth for the path rather than a second, hand-typed copy of it.
    static let directory = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NMS/screenshots", isDirectory: true)

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// Returns the saved file's name (not the full path — the directory
    /// above is fixed and already known) on success, `nil` if rendering
    /// or writing failed.
    @MainActor
    static func capture(_ content: some View) -> String? {
        let renderer = ImageRenderer(content: content)
        // Retina-sharp, matching the actual display instead of a
        // hardcoded default — a screenshot meant to be read (by a person
        // or by Claude) is only useful if the text in it is legible.
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard
            let nsImage = renderer.nsImage,
            let tiffData = nsImage.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "NMS-\(formatter.string(from: Date())).png"
        guard (try? pngData.write(to: directory.appendingPathComponent(filename))) != nil else {
            return nil
        }
        // See DebugArtifactRetention — this directory had no retention at
        // all until now.
        DebugArtifactRetention.pruneFiles(in: directory)
        return filename
    }

    /// Renders the view exactly as passed and returns its natural height
    /// in points — no file written, nothing saved. Exists to build a real
    /// history of the popover's *actual on-screen* height over time,
    /// which a screenshot literally cannot answer: `capture` above always
    /// renders with `ContentView.isCapturingScreenshot == true`, which
    /// swaps every scrollable section for a plain unclipped list
    /// specifically so captures stay legible. A screenshot's height is
    /// therefore always the full-history size, never the fixed-height,
    /// clipped layout that actually has to fit inside a screen — proven
    /// directly the first time this was tried: shrinking a scrollable
    /// section's `.frame(height:)` and comparing two screenshots showed
    /// the total height going *up*, not down, because both captures
    /// bypassed that frame entirely.
    ///
    /// Caller decides which layout this measures by whether `content` was
    /// prepared with `isCapturingScreenshot` true or false — pass the
    /// live, unmutated view for the number that matters here.
    @MainActor
    static func measureHeight(_ content: some View) -> CGFloat? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage?.size.height
    }
}
