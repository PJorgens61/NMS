import SwiftUI

struct ContentView: View {
    // Every view model here is `@Observable`, not `ObservableObject` — see
    // `PUNCHLIST.md`'s Observation migration entry. Plain `var`, not
    // `@ObservedObject`: `ContentView` only forwards each one to a child,
    // never creates or two-way-binds any of them, and `@Observable`
    // reference types need no property wrapper for that.
    var viewModel: NetworkMonitorViewModel
    var lanDiscovery: LANDiscoveryViewModel
    var connectivity: ConnectivityViewModel
    var networkIdentity: NetworkIdentityViewModel
    var publicIP: PublicIPViewModel
    var ispIdentity: ISPIdentityViewModel
    var dhcpLease: DHCPLeaseViewModel
    var networkQuality: NetworkQualityViewModel
    var wifiStressTest: WiFiStressTestViewModel
    var wifiSSID: WiFiSSIDViewModel
    var ethernetLink: EthernetLinkViewModel
    var eventLog: EventLogViewModel
    var traceroute: TracerouteViewModel
    var snmp: SNMPViewModel
    var saasMonitoring: SaaSMonitoringViewModel
    var ddns: DDNSViewModel
    var firewallVisibility: FirewallVisibilityViewModel
    /// Not `@ObservedObject` — a plain value computed once at launch (see
    /// `NMSApp`), not something that changes while the popover is open.
    let buildInfo: BuildInfoService.Info?
    /// The store's location, not its size — unlike `buildInfo`, disk size
    /// genuinely changes during a run, so it's read fresh from
    /// `storeSizeText` on every render rather than cached here.
    let storeURL: URL
    /// Unconditional (unlike `diagnosticServer` below) -- `SnapshotStore`
    /// itself isn't debug-only, only `LocalDiagnosticServer` is. Keeping
    /// this a plain, always-present property avoids the awkward
    /// conditional-trailing-argument problem a `#if DEBUG`-wrapped init
    /// parameter runs into (confirmed directly: it doesn't parse cleanly
    /// either way the comma is placed). Needed here rather than routed
    /// through an existing view model since `LocalDiagnosticServer`
    /// wants several `fetch*History` calls made fresh per page load, not
    /// whatever limit/shape any one view model's own in-memory array
    /// already happens to have.
    let snapshotStore: SnapshotStore

    /// Lets "Networks…"/"Preferences…" bring up their own `Window` scenes
    /// (see `NMSApp`).
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Footer pinned outside the scrollable region — the window's
        // content (SNMP Devices, DHCP History) can run tall enough that
        // without this, reaching Refresh/Quit meant resizing the window or
        // scrolling all the way down first.
        VStack(spacing: 0) {
            ScrollView {
                scrollableContent
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    // Wider than top/bottom on both sides, deliberately —
                    // a real gutter between tile content and each window
                    // edge. Scroll-wheel/trackpad input over one of the
                    // inner-scrolling tiles (Network Health, Info) gets
                    // consumed by that tile instead of chaining to this
                    // outer scroll, so this gutter gives a reliable empty
                    // strip on either side where wheel/trackpad input
                    // reaches this outer scroll instead — confirmed live
                    // to be enough on its own, so the permanently-visible
                    // scroll indicator this once needed (a stand-in for
                    // `NoBounceScrollView`'s old `persistentScrollbar`)
                    // was removed again; the standard auto-hiding
                    // indicator is back.
                    .padding(.horizontal, 32)
                    // Caps tile content + its 32pt gutter at the window's
                    // original 600pt width, then centers that block in
                    // whatever's wider. Previously the *outer* VStack
                    // (below) was pinned to a fixed 600 — widening the
                    // window just added blank space outside the
                    // `ScrollView` entirely, dead space that couldn't
                    // catch wheel/trackpad input at all. Capping here
                    // instead means the extra space stays inside the
                    // `ScrollView`'s own content, i.e. the gutter itself
                    // grows with the window rather than a separate margin
                    // sitting outside it.
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
                // Capped to the tiles' own rendered width (not
                // scrollableContent's wider 600pt gutter block) so this
                // line's edges land exactly on the tile edges above it --
                // confirmed by measuring rendered pixels, since a plain
                // Divider() has no visible width of its own to eyeball
                // against otherwise. Uncapped, this would inherit the
                // outer VStack's full flexible width and stretch
                // edge-to-edge.
                .frame(maxWidth: Self.tileContentWidth)
                .frame(maxWidth: .infinity)
            footerBar
                // Vertical-only -- a horizontal component here would
                // inset the button row inside the frame cap below,
                // pulling Refresh/Quit in from the tile edges they're
                // meant to align with.
                .padding(.vertical, 12)
                // Same tileContentWidth cap-then-center as Divider above,
                // for the same reason: footerBar's own Spacer() otherwise
                // fills whatever width it's offered, so this is what
                // actually pins Refresh/Networks…/Preferences… to the
                // left tile edge and Quit to the right one.
                .frame(maxWidth: Self.tileContentWidth)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 600, maxWidth: .infinity)
        // Named rather than relying on `.global`'s less precisely
        // documented semantics — anchors every `reportFrameForFieldTest`
        // reading to this one known root, unambiguously. See
        // `FieldTestFrameReporter`'s own doc comment for why this exists.
        .coordinateSpace(.named("nmsWindow"))
    }

    @ViewBuilder
    // Not `private` — also rendered directly (bypassing `body`'s own
    // ScrollView/named coordinate space) by NMSTests/PreviewCapture.swift
    // via `@testable import NMS`. See that file's own doc comment.
    var scrollableContent: some View {
            // Network Health and Info merged into one "Network" tile —
            // real content overlap (Router/Network/DNS/Public IP/ISP
            // each showed up in both, just as two different facets of
            // the same concept), see `PUNCHLIST.md`'s "Network Health
            // and Info tiles" item for the full reasoning this was
            // built from. Still fixed to `ContentView.tileHeight`, same
            // as Path to Internet/Speed Test below (see that constant's
            // own doc comment for the three earlier, more intricate
            // alignment mechanisms this replaced).
            VStack(spacing: 12) {
                NetworkTile(
                    viewModel: viewModel,
                    connectivity: connectivity,
                    wifiSSID: wifiSSID,
                    networkIdentity: networkIdentity,
                    publicIP: publicIP,
                    ispIdentity: ispIdentity,
                    traceroute: traceroute,
                    dhcpLease: dhcpLease,
                    networkQuality: networkQuality,
                    ddns: ddns
                )
                // Path to Internet + Speed Test + Apple networkQuality +
                // Local Stress Test — stacked vertically, not side by
                // side (see this whole four-tile window grid's own
                // history in `ContentView.tileHeight`'s doc comment for
                // why). Each is its own `View` type now — see
                // `PUNCHLIST.md`'s `ContentView` fan-in entry.
                PathToInternetTile(traceroute: traceroute, viewModel: viewModel, connectivity: connectivity)
                SpeedTestTile(networkQuality: networkQuality)
                if networkQuality.isAppleTestAvailable {
                    AppleNetworkQualityTile(networkQuality: networkQuality, viewModel: viewModel)
                }
                LocalStressTestTile(wifiStressTest: wifiStressTest, viewModel: viewModel)
            }

            // Hidden outright on Ethernet — nothing here has a Wi-Fi
            // answer. Placed above Events (moved up on request) rather
            // than at the bottom with the other full-width sections,
            // since it's read-at-a-glance current state, not scrollable
            // history like they are.
            // Below here, every section uses `tile()` -- the same bordered
            // box Network/Path to Internet/Speed Test/Apple networkQuality/
            // Local Stress Test above already use. These used to go
            // through a separate `scrollBox()` helper (a standalone
            // Divider()+Text(title)+independently-scrolling box), which
            // turned out not to share tile()'s width behavior: nested
            // inside this whole VStack's own outer ScrollView, scrollBox's
            // ScrollView sized to its content's natural width rather than
            // the constrained width its parent actually offered, letting
            // long rows push these boxes out past every tile's edge above
            // them -- confirmed live, and two narrower attempts at fixing
            // scrollBox() directly (matching tile()'s own
            // `maxWidth: .infinity`, then capping explicitly to
            // `tileContentWidth`) both still reproduced it. Switching to
            // the exact mechanism that was already confirmed correct
            // sidesteps whatever this is, rather than chasing it further.
            WiFiTile(wifiSSID: wifiSSID)

            // Ethernet's counterpart to the Wi-Fi section just above —
            // mutually exclusive with it by construction (a Mac's default
            // route is either Wi-Fi or Ethernet, never both). `EthernetTile`
            // itself decides whether there's anything to show (mirrors
            // `wifiSSID.currentSSID != nil` above — nothing to show while
            // the cable's unplugged either) — see its own doc comment for
            // why this is a separate `View` type now, not a computed
            // property here.
            EthernetTile(ethernetLink: ethernetLink)

            // `FeatureFlags.saasMonitoring` is a consent question (this
            // reaches out to third-party services, not just this Mac's
            // own LAN). Placed near Wi-Fi, not with the other full-width
            // sections below — same reasoning: read-at-a-glance current
            // state, not scrollable history.
            if FeatureFlags.saasMonitoring {
                SaaSStatusTile(saasMonitoring: saasMonitoring)
            }

            EventsTile(eventLog: eventLog)

            // `FeatureFlags.snmpDevices` is a consent question (this is
            // active network probing against whatever LAN the Mac is on,
            // not just a UI section — see that flag's doc comment).
            if FeatureFlags.snmpDevices {
                SNMPDevicesTile(snmp: snmp, viewModel: viewModel, connectivity: connectivity)
            }

            // `FeatureFlags.firewallVisibility` is a consent question, same
            // shape as `snmpDevices`'s comment just above — this reaches an
            // internet-hosted server, not just this Mac's own LAN.
            if FeatureFlags.firewallVisibility {
                FirewallVisibilityTile(firewallVisibility: firewallVisibility)
            }

            // LAN Devices has no section of its own — the popover was too
            // tall for a 13" MacBook screen. The underlying scan still
            // runs for its own sake: see `LANDiscoveryViewModel` for what
            // it feeds (SNMP's candidate addresses, MAC-merge data) even
            // with no UI list. Bonjour discovery was removed outright
            // rather than left dormant like this — see DESIGN-NOTES.md's
            // "mDNS/Bonjour" section — since it was never actually running
            // (nothing called its `scan()`) and, even if it had been,
            // found nothing SNMP's own subnet sweep didn't already cover.

            DHCPHistoryTile(dhcpLease: dhcpLease)
    }

    /// Refresh/Networks…/Preferences…/Quit, the build-hash/store-size
    /// line, and the DEBUG-overrides banner.
    ///
    /// **Deliberately still a computed property, not its own `View`
    /// type** — considered directly as part of `PUNCHLIST.md`'s
    /// view-structure factoring entry, which names this property
    /// specifically, and rejected: the DEBUG-overrides and store-
    /// fallback banners below have no `@Observable` property backing
    /// them at all (`FailureInjector.activeOverridesSummary()`/
    /// `NMSApp.storeFallbackReason` are plain static reads), so their
    /// only "refresh" mechanism is being swept along whenever
    /// `ContentView.body` re-evaluates for an unrelated reason — see
    /// their own doc comments below for why that's an accepted,
    /// deliberate trade-off, not an oversight. A separate `View` type
    /// with narrow inputs would take `buildInfo`/`storeURL` (both
    /// effectively constant for the process lifetime) and view-model
    /// references this content never actually *reads* during `body` —
    /// SwiftUI would find nothing changed on any later re-render and
    /// skip re-evaluating it, and those two banners would freeze at
    /// whatever they showed on the very first render instead of staying
    /// current. This is the "no independent invalidation story" carve-
    /// out from `swiftui-specialist`'s `references/structure.md`, just
    /// inverted: not merely *no benefit* to extracting, but a real
    /// regression from it.
    @ViewBuilder
    private var footerBar: some View {
            HStack(spacing: 4) {
                Button("Refresh") {
                    viewModel.refresh()
                    publicIP.check()
                    wifiSSID.refresh(isWiFi: viewModel.currentInterface?.isWiFi ?? false)
                }
                .accessibilityLabel("Refresh")
                .accessibilityHint("Re-reads network state, public IP and Wi-Fi network")
                .accessibilityIdentifier("footer.refresh")
                .help(tooltip(
                    "Re-reads network state, public IP and Wi-Fi network.",
                    technical: "Doesn't re-run Path to Internet or SNMP Devices, which refresh independently."
                ))
                Button("Networks…") {
                    openWindowInFront("known-networks")
                }
                .accessibilityLabel("Known Networks")
                .accessibilityHint("Opens a list of every network this Mac has connected to, with a way to forget one")
                .accessibilityIdentifier("footer.networks")
                .help("Opens a list of every network this Mac has connected to, with a way to forget one")
                Button("Preferences…") {
                    openWindowInFront("preferences")
                }
                .accessibilityLabel("Preferences")
                .accessibilityHint("Opens toggles for experimental features")
                .accessibilityIdentifier("footer.preferences")
                .help("Opens toggles for experimental features")
                #if DEBUG
                // A separate window for debug action buttons, not more
                // footer buttons — see `DebugToolsView`'s own doc comment
                // for why (raised directly once a second button, Path
                // Discovery, was about to join Diagnostic Log here).
                Button("Tools…") {
                    openWindowInFront("debug-tools")
                }
                .accessibilityLabel("Debug Tools")
                .accessibilityHint("Opens a window with debug-only diagnostic actions: a local event/test-result log, and a reverse-traceroute path discovery tool")
                .accessibilityIdentifier("footer.debugTools")
                .help("Opens debug-only diagnostic actions (Diagnostic Log, Path Discovery) in their own window. Debug builds only.")
                #endif
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .accessibilityLabel("Quit")
                .accessibilityHint("Quits NMS")
                .accessibilityIdentifier("footer.quit")
                .help("Quits NMS")
            }

            if buildInfo != nil || storeSizeText != nil {
                // Shares one row rather than adding a second — no new
                // vertical space cost, matching the discipline every other
                // footer addition here has followed. Store size answers
                // "how big has this gotten" (this table has no size cap
                // the way the pruned telemetry tables do; DHCP/SNMP/Events
                // history accumulates indefinitely), read fresh on every
                // render since — unlike the build hash — it genuinely
                // changes during a run.
                HStack(spacing: 4) {
                    if let buildInfo {
                        Text("Build \(buildInfo.shortHash)\(buildInfo.isDirty ? "+" : "")")
                            .accessibilityLabel(
                                "Build \(buildInfo.shortHash)\(buildInfo.isDirty ? ", with uncommitted changes" : "")"
                            )
                    }
                    if let storeSizeText {
                        if buildInfo != nil {
                            Text("·")
                        }
                        Text("\(storeSizeText) store")
                            .accessibilityLabel("Store size \(storeSizeText)")
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }

            // Deliberately loud (unlike the build line above) and placed
            // last, so it's the final thing read top-to-bottom. Exists to
            // catch a mistake with real history in this project: a test's
            // `defaults` key left set after the test ended, otherwise only
            // discoverable by grepping the plist by hand. No `#if DEBUG`
            // needed here — `activeOverridesSummary()` is already `nil`
            // unconditionally in a release build, so this is inert there
            // without a second guard to keep in sync.
            //
            // No dedicated refresh timer: this is computed directly in
            // `body`, so it goes stale for at most as long as the popover
            // sits open with nothing else re-rendering it — in practice
            // at most one connectivity round (30s, 5s if anything's
            // already unhealthy), since that's `@Published` and already
            // drives a re-render on its own.
            if let overrides = FailureInjector.activeOverridesSummary() {
                Text("⚠ DEBUG: \(overrides)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityLabel("Debug overrides active: \(overrides)")
            }

            // Red, not orange, and unconditional in every build — unlike
            // the debug banner above, this reports real data loss in
            // progress: no saved history is visible and nothing from this
            // session will survive quitting. It went unnoticed for two
            // days precisely because the symptom (an empty Events list)
            // renders as reassuring copy, so this says the opposite
            // plainly. See `NMSApp.storeFallbackReason`.
            if NMSApp.storeFallbackReason != nil {
                Text("⚠ Database unavailable — history is hidden and nothing is being saved")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityLabel("Database unavailable. Saved history cannot be read and new data is not being saved.")
                    .help(NMSApp.storeFallbackReason ?? "")
            }
    }

    /// The one fixed height all four top tiles (Network Health, Info,
    /// Path to Internet, Speed Test) share — replaces three earlier,
    /// increasingly bespoke attempts at making these tiles line up:
    /// `Grid`/`GridRow` row-syncing for one pair, deliberately independent
    /// sizing for the other, a `SectionLayout`-declared height per section,
    /// and (briefly) a `GeometryReader`/`PreferenceKey` round-trip. Every
    /// one of those existed to reconcile tiles whose *natural* content
    /// heights genuinely differ. Declaring one shared height and scrolling
    /// whatever doesn't fit sidesteps the reconciliation problem instead
    /// of solving it more cleverly — raised directly, after three rounds
    /// of Bug Reports on this exact alignment.
    ///
    /// Deliberately *not* sized to fit any one tile's full natural
    /// content (that was the first attempt — fit Network Health's 7 rows
    /// exactly at 150pt — but it made every future content change a
    /// fresh calibration problem: add a row anywhere and something either
    /// clips or needs remeasuring). Picked short enough on purpose that
    /// every tile routinely needs its internal scroll, not just the one
    /// with genuinely unbounded content (Speed Test's growing run list).
    /// That makes scrolling the norm everywhere rather than the exception
    /// on one tile, so the exact number here stops being load-bearing — a
    /// row added or removed from any section's content just changes how
    /// much of it needs a scroll, never whether it renders at all.
    ///
    /// **History: 180→270→210→240→210.** Network Health and Info briefly
    /// went through a `scrolls: false` phase (no internal scroll fallback
    /// at all) to route around a real `Grid`/scroll-container interop bug
    /// — see `NetworkTile`'s own doc comment. While that was
    /// in effect, this constant had to fit both tiles' full worst-case
    /// row count with real room, which is what pushed it to 240. Once the
    /// underlying scroll container switched from a custom AppKit bridge
    /// to a plain SwiftUI `ScrollView` (see `NoBounceScrollView`'s
    /// removal), that `Grid` bug didn't reproduce — confirmed live — so
    /// `scrolls: false` was dropped for both tiles and this reverted to
    /// 210, back to the original "deliberately short, scrolling absorbs
    /// the rest" design above. Raised directly: chasing an exact-fit
    /// number here is the wrong ongoing cost when scrolling already
    /// solves it.
    static let tileHeight: CGFloat = 210

    /// Every tile's actual rendered width once centered in the window --
    /// window's 600pt floor minus scrollableContent's 32pt gutter on each
    /// side (600 - 64 = 536). `Divider()` and `footerBar` cap themselves
    /// to this same number (see `body`) so their edges land exactly on
    /// the tiles' own edges instead of on the wider 600pt block that
    /// includes the gutter -- confirmed by measuring rendered pixels
    /// directly (a `Divider()` or a button row has no natural width of
    /// its own to eyeball against, unlike a tile's visible border).
    static let tileContentWidth: CGFloat = 536

    /// `tile()` and `row(_:_:)` — the bordered-box helper and its
    /// label/value row — now live in `TileHelpers.swift` as plain `View`
    /// extension methods, not `ContentView` instance methods, so the
    /// extracted tile types (`EthernetTile` and friends) can call them
    /// without needing a `ContentView` to call through. `ContentView`
    /// itself still calls them unqualified for the sections not yet
    /// extracted — an extension method resolves identically to an
    /// instance method from inside a conforming type's own body.

    /// First estimate for `tile(fixedHeight:)`'s header+padding overhead
    /// (10pt padding × 2, 6pt `VStack` spacing, one `.headline` line) —
    /// not yet measured against a real render. Update this once a
    /// screenshot shows exactly how much of `tileHeight` the header
    /// actually consumes.
    ///
    /// Not `private` — `TileHelpers.swift`'s `tile()` (now a `View`
    /// extension, not a `ContentView` member) reads this too.
    static let tileHeaderOverhead: CGFloat = 45

    /// Opens a window scene *and* actually puts it in front. Used by all
    /// three footer buttons (Expert Mode, Networks…, Preferences…).
    ///
    /// Three separate things conspire here, which is why the first
    /// attempt — a bare `NSApp.activate` immediately after `openWindow` —
    /// worked often enough to look fixed, then didn't:
    ///
    /// 1. At the time this was written, NMS ran as `.accessory` (no Dock
    ///    icon, no app-switcher entry), so macOS wouldn't activate it just
    ///    because one of its windows opened — that needed an explicit
    ///    `activate`. NMS is `.regular` now (no code needed for that; it's
    ///    the OS default and the old `AppDelegate` override was removed as
    ///    dead weight), but point 4 below found a second, policy-independent
    ///    reason `activate` stays necessary regardless.
    /// 2. Both calls used to run synchronously inside the button action,
    ///    while the `MenuBarExtra` popover is still dismissing — the
    ///    window may not exist yet to raise, and the dismissal takes
    ///    focus back afterwards regardless. Deferring one run loop turn
    ///    lets the popover finish and the window get created first.
    /// 3. `activate` raises whichever window is *key*. For a window
    ///    that's already open but buried — the case this was reported
    ///    for, since Known Networks stays open across popover
    ///    dismissals — that's frequently some other window, so the app
    ///    came forward and the requested window stayed behind.
    ///
    /// So the specific window is ordered front by name rather than
    /// trusting activation to pick the right one.
    ///
    /// **A fourth thing, found later, on a different machine.**
    /// `NSApp.activate(ignoringOtherApps:)` has been deprecated since
    /// macOS 14, and confirmed (not just suspected) to actually stop
    /// working somewhere after that: reproduced live on a MacBook running
    /// macOS 26.5.2, `openWindowInFront`'s own log line showed a clean
    /// window match (`known-networks → known-networks`, `makeKeyAndOrderFront`
    /// ran) — ruling out points 2 and 3 above entirely — yet the window
    /// still never came to front; a different app stayed frontmost. The
    /// window was correctly made key *within this app's own window
    /// list*, but the application itself never actually activated, so
    /// another app's windows kept rendering on top of it regardless. See
    /// `BUGS.md`'s "No window comes to the front on the MacBook" for the
    /// full diagnosis this was built from — this app's deployment target
    /// is already macOS 14+, so the modern, no-parameter
    /// `NSApplication.activate()` needs no availability guard.
    ///
    /// SwiftUI sets `NSWindow.identifier` to the scene id **verbatim** —
    /// verified from the state log, which is why the match is logged at
    /// all: it was written expecting a decorated identifier
    /// (`SwiftUI.Window-...-id-known-networks` or similar) and the log
    /// showed a plain `known-networks → known-networks`. `contains`
    /// rather than `==` is kept anyway, since it costs nothing and still
    /// matches if a future SwiftUI does decorate it. The log line stays
    /// for the same reason: if a match is ever missed, it says
    /// `NO WINDOW MATCHED` instead of the window silently misbehaving.
    private func openWindowInFront(_ id: String) {
        openWindow(id: id)
        DispatchQueue.main.async {
            NSApp.activate()
            let match = NSApp.windows.first { $0.identifier?.rawValue.contains(id) == true }
            match?.makeKeyAndOrderFront(nil)
            UIStateLogger.log(
                "ContentView.openWindowInFront",
                "\(id) → \(match?.identifier?.rawValue ?? "NO WINDOW MATCHED")"
            )
        }
    }

    /// `nil` before anything has ever been written to `storeURL` (e.g.
    /// the in-memory fallback path, or a fresh install's very first
    /// instant) — see `StoreSizeService`, which reports that case as
    /// absent rather than a misleading "0 bytes".
    private var storeSizeText: String? {
        StoreSizeService.formattedSize(at: storeURL)
    }

}
