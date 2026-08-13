import AppKit
import SwiftUI

/// Ported directly from RoonWatch's `RoonWatchApp.swift` `MenuBarIcon` —
/// same confirmed-working fix for the same `MenuBarExtra` gotcha:
/// `NSStatusItem` forces template/monochrome rendering on a SwiftUI
/// `MenuBarExtra` label, so plain `.foregroundStyle`/AppKit
/// `contentTintColor` both silently no-op. The fix is building the
/// `NSImage` with an explicit `SymbolConfiguration(paletteColors:)` and
/// `isTemplate = false`, then handing SwiftUI that already-colored image
/// via `Image(nsImage:)` so it still reacts to `@Published`/`@AppStorage`
/// changes through SwiftUI's normal pipeline.
struct MenuBarIcon: View {
    var status: OverallStatus

    var body: some View {
        Image(nsImage: Self.icon(status: status))
    }

    private static func icon(status: OverallStatus) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [NSColor(status.color)])
        let image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }
}
