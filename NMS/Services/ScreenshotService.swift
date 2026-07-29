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
/// **Known limitation, confirmed directly rather than assumed:**
/// `ImageRenderer` does not render `ScrollView` content at all when
/// rendering off-screen — not clipped, entirely absent, even with real,
/// non-empty data behind it (Events/SNMP Devices/Speed Test's history,
/// specifically). An attempted fix — an `@Environment` flag telling
/// those sections to swap their `ScrollView` for a plain unclipped list
/// during capture — was built and tested, and the environment value
/// never actually propagated into `ImageRenderer`'s render pass (checked
/// directly via logging: read as `false` on every capture). Reverted
/// rather than left in as dead code. A capture currently shows Network
/// Health, Info, Path to Internet, Speed Test's header, and DHCP History
/// (small enough to render without a `ScrollView`) correctly; Events,
/// SNMP Devices, and Speed Test's run list render blank. See
/// DESIGN-NOTES.md for the options considered to actually fix this
/// (real window capture, needing Screen Recording permission) versus
/// shipping with the limitation.
struct ScreenshotService {
    private static let directory = FileManager.default
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
        return filename
    }
}
