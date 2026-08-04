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
@Suite("Preview capture (manual only, see script/capture-preview.sh)")
struct PreviewCaptureTests {
    private struct Request: Decodable {
        let outputPath: String
        let width: Double
        let height: Double
    }

    private static let requestURL = URL(fileURLWithPath: "/tmp/nms-capture-request.json")

    /// Edit this to whatever needs rendering right now. Currently checking
    /// `NetworkTile`'s `Grid` alignment after its rows (`QuickCheckRow`/
    /// `ConnectionLayerRow`/`DHCPStatusRow`) moved from inline
    /// `@ViewBuilder` functions into separate `View` types whose own
    /// `body` is a `GridRow` -- see `PUNCHLIST.md`'s view-structure
    /// factoring entry for why that's unverified visually. Deliberately
    /// *not* the real `NetworkTile` or `ContentViewPreviewSupport
    /// .makeContentView()` -- `dhcpLease`/`connectivity`/`traceroute`/
    /// `publicIP` all spawn a timer or subprocess in `init`, the exact
    /// live-side-effect risk this file's own doc comment documents.
    /// Fixture `ConnectionLayer` values plus one freshly-built
    /// `NetworkQualityViewModel` (confirmed side-effect-free at `init`
    /// -- no timer, on-demand only) reproduce the same `Grid` structure
    /// and the same row types with zero live view-model risk. The DHCP
    /// row calls `statusGridRow` directly with plain values rather than
    /// via `DHCPStatusRow`, for the same reason -- `DHCPLeaseViewModel`
    /// starts a timer and a background check in its own `init`.
    @MainActor
    @ViewBuilder
    private static var viewToCapture: some View {
        let schema = Schema([
            NetworkSnapshot.self, DiscoveredDeviceRecord.self, ConnectivityCheckRecord.self,
            KnownNetwork.self, PublicIPRecord.self, DHCPLeaseRecord.self, NetworkQualityRecord.self,
            AppEventRecord.self, ProviderEdgeRecord.self, SNMPDeviceRecord.self,
            WiFiSampleRecord.self, WiFiStressTestRecord.self
        ])
        // `try!` -- diagnostic-only code; an in-memory container failing
        // to initialize means Xcode itself is broken, not something
        // worth a fallback path for. Same convention
        // `ContentViewPreviewSupport.makeContentView()` uses.
        let container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let networkQuality = NetworkQualityViewModel(snapshotStore: SnapshotStore(context: container.mainContext))

        let layers: [ConnectionLayer] = [
            ConnectionLayer(id: "network", label: "Network", detail: "Thistle Wi-Fi · 10.0.0.142/24 · seen 12×", status: .healthy),
            ConnectionLayer(id: "localRouter", label: OverallStatus.routerLabel, detail: "10.0.0.1 · 4 ms", status: .healthy, url: "http://10.0.0.1"),
            ConnectionLayer(id: "publicIP", label: OverallStatus.publicIPLabel, detail: "73.1.2.3 · 12 ms", status: .healthy),
            ConnectionLayer(id: "peRouter", label: OverallStatus.peRouterLabel, detail: "Comcast · Not confirmed", status: .unknown),
            ConnectionLayer(id: "internet", label: OverallStatus.internetLabel, detail: "unreachable", status: .unhealthy, correlatedWithChange: true),
            ConnectionLayer(id: "dns", label: OverallStatus.dnsLabel, detail: "unreachable", status: .unhealthy),
            ConnectionLayer(id: "http", label: OverallStatus.httpLabel, detail: "unreachable", status: .unhealthy)
        ]

        VStack(alignment: .leading, spacing: 2) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                QuickCheckRow(networkQuality: networkQuality, interfaceName: nil)
                ForEach(layers) { layer in
                    ConnectionLayerRow(layer: layer, rootCauseLayerID: "internet", sparklineValues: layer.id == "network" ? [-52, -55, -50, -58, -49] : nil)
                }
                statusGridRow(color: .yellow, label: "DHCP", detail: "Changed recently") {
                    Color.clear.frame(width: 0, height: 0)
                } chart: {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
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
