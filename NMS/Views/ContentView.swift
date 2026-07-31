import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @ObservedObject var lanDiscovery: LANDiscoveryViewModel
    @ObservedObject var connectivity: ConnectivityViewModel
    @ObservedObject var networkIdentity: NetworkIdentityViewModel
    @ObservedObject var publicIP: PublicIPViewModel
    @ObservedObject var dhcpLease: DHCPLeaseViewModel
    @ObservedObject var networkQuality: NetworkQualityViewModel
    @ObservedObject var screenshot: ScreenshotViewModel
    @ObservedObject var wifiSSID: WiFiSSIDViewModel
    @ObservedObject var eventLog: EventLogViewModel
    @ObservedObject var traceroute: TracerouteViewModel
    @ObservedObject var snmp: SNMPViewModel
    /// Not `@ObservedObject` — a plain value computed once at launch (see
    /// `NMSApp`), not something that changes while the popover is open.
    let buildInfo: BuildInfoService.Info?
    /// The store's location, not its size — unlike `buildInfo`, disk size
    /// genuinely changes during a run, so it's read fresh from
    /// `storeSizeText` on every render rather than cached here.
    let storeURL: URL

    /// True only on the throwaway copy handed to `ImageRenderer` (see the
    /// camera button's action), never on the live popover. Makes the
    /// scrollable sections render as plain, unclipped lists of every row.
    ///
    /// Deliberately a plain stored property, not `@Environment` or
    /// `@State`. An `@Environment` version of exactly this was built
    /// first and confirmed not to work — the value never reached the
    /// view during `ImageRenderer`'s pass (logged from inside `eventList`
    /// during a real capture: `false` every time). A plain `var` on a
    /// struct has no propagation machinery to fail; `var copy = self;
    /// copy.isCapturingScreenshot = true` is just a value copy, read
    /// directly during `body`.
    ///
    /// Two independent reasons this matters, not one: `ImageRenderer`
    /// doesn't render `ScrollView` content *at all* off-screen (not
    /// clipped — absent, confirmed by a side-by-side against a real
    /// screen capture where every plain-`VStack` section rendered and
    /// every `ScrollView` section came out blank, 5 for 5); and a
    /// screenshot meant to be read later is more useful showing full
    /// history than whatever happened to fit an 8-row scroll window.
    var isCapturingScreenshot = false

    /// Which surface this copy is rendering into — `.window` for the one
    /// hosted in the comparison `Window` scene (see `NMSApp`), `.popover`
    /// otherwise.
    ///
    /// Each fixed-height mini-`ScrollView` (Events, SNMP Devices, DHCP
    /// History, Speed Test history, traceroute hops) still scrolls *within
    /// its own box* in the window rather than unclipping — a fully
    /// unclipped Events list ran to hundreds of rows and made the whole
    /// window scroll past everything else just to see later sections. What
    /// changes per surface is which sections appear at all and how tall
    /// their boxes are, both declared in `SectionLayout` rather than
    /// branched on inline here.
    ///
    /// This was an `isInWindow: Bool` until it became clear the two
    /// surfaces are diverging into different products rather than two
    /// sizes of one — see `Surface`'s doc comment.
    var surface: Surface = .popover

    /// Convenience for the handful of places that genuinely branch on the
    /// *container* rather than on a section's declared layout: `body`'s
    /// two top-level arrangements, and the footer's "Open in Window"
    /// button hiding itself once you're already there. Section visibility
    /// and box heights deliberately do **not** go through this — they read
    /// `SectionLayout` instead, so the popover's contents stay a closed,
    /// testable list.
    private var isInWindow: Bool { surface == .window }

    /// Lets the footer's "Open in Window" button bring up the comparison
    /// `Window` scene declared in `NMSApp` — see that scene for why it
    /// exists (a resizable/scrollable alternative to this fixed-height
    /// popover, added to compare side by side rather than replace outright).
    @Environment(\.openWindow) private var openWindow

    @State private var communityDraft: String = ""
    @State private var isEditingCommunity = false
    /// Backs the footer's "Bug Report" button — see `bugReportRow` and
    /// `submitBugReport`.
    @State private var bugReportDraft: String = ""
    @State private var isReportingBug = false
    /// Keyed by `ConnectionLayer.id`. Populated by the Network Health
    /// section's `.task`; empty until then, which simply renders no
    /// sparklines rather than empty boxes.
    @State private var latencyHistory: [String: [LatencySample]] = [:]

    /// The window branch used to be handled by `NMSApp` splitting
    /// `scrollableContent`/`footerBar` into two children of *its own*
    /// `VStack`, rather than embedding `ContentView` itself. That broke
    /// `@State` silently: `ContentView` was never actually placed in the
    /// tree as one identified node, only fragments of its computed
    /// output were, so SwiftUI had no stable identity to persist state
    /// against — `contentView(surface:)` constructs a fresh
    /// `ContentView` (fresh default `@State`) on every re-render, and
    /// nothing tied one render's mutated state to the next's. A tap on
    /// Bug Report *did* set `isReportingBug = true`, and *did* schedule a
    /// re-render — which then rebuilt `content` from scratch and reset it
    /// straight back to `false`, indistinguishable from the button doing
    /// nothing at all. Confirmed as the real cause via a live bug report
    /// filed through this exact path in the window ("no orange box"),
    /// while the popover — never split this way — worked correctly the
    /// whole time.
    ///
    /// Fixed by keeping both branches inside this one `body`, so
    /// `ContentView` is always embedded as a single, stably-identified
    /// view no matter which scene hosts it — `NMSApp.comparisonWindowContent`
    /// now just calls `contentView(surface: .window)` directly again, the
    /// same shape as the popover's own call.
    var body: some View {
        if isInWindow {
            // Footer pinned outside the scrollable region — the window's
            // content (SNMP Devices, DHCP History, Printer Alerts, Bug
            // Report) can run tall enough that without this, reaching
            // Refresh/Screenshot/Bug Report/Quit meant resizing the
            // window or scrolling all the way down first.
            //
            // `NoBounceScrollView` here for the same reason it used to
            // wrap this whole view from `NMSApp`: no outer scroll
            // floor-clamps the window to its full content height,
            // confirmed broken on the M1 MacBook Air specifically (see
            // that type's own doc comment, design 1) — moved one level
            // deeper, from wrapping `ContentView` externally to living
            // inside its own `body`, which is what restores the state
            // continuity described above.
            //
            // **Skipped entirely when `isCapturingScreenshot`** — found
            // via a live bug report filed right after the state-identity
            // fix above shipped: `ImageRenderer` can't render
            // `NoBounceScrollView`'s `NSViewRepresentable` content
            // off-screen any better than it renders a plain `ScrollView`
            // (see `ScreenshotService`'s own doc comment, quirk 1) — every
            // capture taken in the window was silently missing
            // `scrollableContent` entirely, confirmed by the resulting
            // PNGs shrinking from 300-700KB to ~42KB. Same fix as that
            // quirk: swap to the plain, unclipped form for the capturing
            // copy only, never for the live window.
            VStack(spacing: 0) {
                if isCapturingScreenshot {
                    scrollableContent
                        .padding(12)
                } else {
                    NoBounceScrollView(persistentScrollbar: true) {
                        scrollableContent
                            .padding(12)
                    }
                }
                Divider()
                footerBar
                    .padding(12)
            }
            .frame(width: 560)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                scrollableContent
                footerBar
            }
            .padding(12)
            // Widened from the original 335pt for the DHCP History section,
            // then brought back down from a first attempt at 670pt (a single
            // *unbroken* line of full lease detail) once that line wrapped to
            // two instead — 670pt then just left every section with wide,
            // pointless gaps between labels and values, confirmed directly:
            // the widest wrapped DHCP line (bcast/gateway/DNS/domain/lease-
            // T1-T2/xid) measured to ~440pt of actual text, against a screenshot
            // of a real lease. 560pt covers that with headroom for a slightly
            // longer domain or an extra DNS server, without carrying 670pt's
            // dead space. Every section still has `.lineLimit(1)` truncation
            // as its fallback regardless.
            .frame(width: 560)
        }
    }

    /// Everything except the footer controls — split out so `body` can
    /// give the window branch a pinned footer (via an inner
    /// `NoBounceScrollView` around just this part) while the popover
    /// branch keeps both in one plain `VStack`, unchanged either way:
    /// `@ViewBuilder`'s tuple-view flattening means
    /// `VStack(spacing: 6) { scrollableContent; footerBar }` lays out
    /// identically to a single flat VStack containing the same content
    /// inline. `private` again — both branches live inside this file's
    /// own `body` now; see `body`'s doc comment for why an earlier
    /// version of this split reached into `NMSApp` instead, and why that
    /// broke `@State`.
    @ViewBuilder
    private var scrollableContent: some View {
            // Network Health, Info, and Path to Internet are short
            // label/value lists that looked sparse and hard to read once
            // the popover doubled in width for the DHCP History section —
            // wide gaps between a label and its value with nothing else
            // to fill the space. Tiled side by side instead, each sized to
            // its own half, not the whole popover.
            //
            // Two independent columns (`HStack` of two `VStack`s), not a
            // `LazyVGrid` — that was tried first and produced visibly
            // misaligned tiles: a `LazyVGrid` synchronizes each *row's*
            // height to its tallest cell, so Path to Internet (short) and
            // Speed Test (its row-mate, and by far the tallest tile once
            // it has real history) were forced to the same row height,
            // leaving a real, confirmed-by-a-live-screenshot gap of dead
            // space below Path to Internet's shorter box.
            //
            // Independent columns fix that by construction, not by
            // coincidence: row-grid total height is
            // `max(NetworkHealth, Info) + max(Path, Speed)`, while
            // column-stack total is `max(NetworkHealth+Path,
            // Info+Speed)`. The sum-of-maxes is always ≥ the max-of-sums
            // for non-negative sizes, so this is a guaranteed improvement
            // (or at worst a no-op), never a regression — it can't make
            // the popover taller than the grid did.
            //
            // Swapping Info and Path to Internet was tried directly
            // (measured via `ContentView.liveHeight`, not just reasoned
            // about): {NetworkHealth+Info} / {Path+Speed} measured 850pt,
            // 4pt *taller* than this arrangement's 846pt, and visually just
            // moved the same-size imbalance to the other column instead of
            // reducing it. Of the three possible pairings of these four
            // tiles, this one — not the swap — happens to be the shortest.
            //
            // All of the above is window-only reasoning now. As of the
            // audience split (see `SectionLayout.surfaces`), Path to
            // Internet and Speed Test are gated by
            // `SectionLayout.pathToInternet`/`.speedTest.appears(on:)` and
            // render only in the window — the popover's two columns
            // collapse to exactly Network Health and Info, side by side,
            // with nothing conditional left to reason about there. The
            // column split itself needed no change: an `HStack` of two
            // one-tile `VStack`s lays out the same as two plain tiles
            // would, so this is one fewer thing to special-case per
            // surface, not a new one.
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    tile(title: "Network Health") {
                        connectionHealthSection
                    }
                    if SectionLayout.pathToInternet.appears(on: surface) {
                        tile(title: "Path to Internet", trailing: {
                            Button("Trace Now") {
                                traceroute.run()
                            }
                            .disabled(traceroute.isRunning)
                            .accessibilityLabel("Trace Now")
                            .accessibilityHint("Runs a traceroute to find the path to the internet")
                        }) {
                            tracerouteSection
                        }
                    }
                }
                VStack(spacing: 12) {
                    tile(title: "Info") {
                        infoSection
                    }
                    if SectionLayout.speedTest.appears(on: surface) {
                        tile(title: "Speed Test", trailing: {
                            Button(networkQuality.isRunning ? "Testing…" : "Run Speed Test") {
                                networkQuality.run()
                            }
                            .disabled(networkQuality.isRunning)
                            .accessibilityLabel(networkQuality.isRunning ? "Testing" : "Run Speed Test")
                            .accessibilityHint("Measures download and upload throughput using Cloudflare's public speed-test endpoint. Uses your data plan, up to roughly 50MB total, less on a slow connection.")
                        }) {
                            speedTestTileContent
                        }
                    }
                }
            }

            // Window-only (declared in `SectionLayout`, not gated inline
            // here) — this adds a full-width section, and the popover's
            // fixed-height budget is exactly the constraint this whole app
            // has fought hardest, so a section a fresh install didn't ask
            // for doesn't get to spend it. Hidden outright on Ethernet —
            // nothing here has a Wi-Fi answer. Placed above Events (moved
            // up on request) rather than at the bottom with the other
            // full-width sections, since it's read-at-a-glance current
            // state, not scrollable history like they are.
            if SectionLayout.wifi.appears(on: surface), wifiSSID.currentSSID != nil {
                Divider()

                Text("Wi-Fi")
                    .font(.headline)

                wifiSection
            }

            // Window-only as of the audience split (see
            // `SectionLayout.surfaces`): the popover's scope is now "can
            // I work, what's restricted," which Network Health already
            // answers, not "what changed and when" — that's the
            // diagnostic read Events exists for, so it moved to the
            // window along with Path to Internet and Speed Test rather
            // than staying as the one full-width holdout on the popover.
            if SectionLayout.events.appears(on: surface) {
                Divider()

                Text("Events")
                    .font(.headline)

                eventList
            }

            // Two independent gates. `FeatureFlags.snmpDevices` answers a
            // consent question (this is active network probing against
            // whatever LAN the Mac is on, not just a UI section — see that
            // flag's doc comment); `SectionLayout` answers a space
            // question (a scrollable list of per-device detail is squarely
            // "niche," not popover-budget material). Neither implies the
            // other, so both are checked.
            if FeatureFlags.snmpDevices, SectionLayout.snmpDevices.appears(on: surface) {
                Divider()

                HStack {
                    Text("SNMP Devices")
                        .font(.headline)
                    Spacer()
                    Button(snmp.isScanning ? "Scanning…" : "Scan") {
                        snmp.scan()
                    }
                    .disabled(snmp.isScanning || !snmp.isAvailable)
                    .accessibilityLabel(snmp.isScanning ? "Scanning" : "Scan")
                    .accessibilityHint("Clears the SNMP device list and sweeps the subnet again")
                }

                infrastructureList
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

            // Window-only, same reasoning as the Wi-Fi section above: the
            // popover's fixed-height budget is the constraint this app has
            // fought hardest, and DHCP History is scrollable history, not
            // read-at-a-glance current state — exactly the kind of section
            // that's cheap to lose from the popover (it's still one click
            // away via Open in Window) but expensive to keep paying for in
            // every popover-height trim.
            if SectionLayout.dhcpHistory.appears(on: surface) {
                Divider()

                Text("DHCP History")
                    .font(.headline)

                dhcpHistoryList
            }

            // Window-only from the start, unlike DHCP History above (which
            // moved here) — a fault a printer reports (out of paper, cover
            // open, low toner) is orthogonal to whether it's reachable on
            // the network at all, so this is new signal `Network Health`'s
            // reachability pinging can't see, but it's still a niche
            // per-device detail in the same category as SNMP Devices, not
            // something a fresh install's popover budget should pay for.
            // Hidden entirely when nothing's configured, same as the
            // Wi-Fi section hiding on Ethernet.
            if SectionLayout.printerAlerts.appears(on: surface), !connectivity.printerStatuses.isEmpty {
                Divider()

                Text("Printer Alerts")
                    .font(.headline)

                printerAlertsList
            }
    }

    /// Refresh/Screenshot/Bug Report/Open in Window/Networks…/
    /// Preferences…/Quit, the build-hash/store-size line, and the
    /// DEBUG-overrides banner — plus `bugReportRow`, whose comment
    /// field is only reachable via a footer button, so it's pinned
    /// alongside that button in the window rather than needing a
    /// scroll back down to see what was just opened. See
    /// `scrollableContent`'s doc comment for why this split exists, and
    /// `body`'s for why both stay `private` and composed only within
    /// this file.
    @ViewBuilder
    private var footerBar: some View {
            bugReportRow

            Divider()

            HStack {
                Button("Refresh") {
                    viewModel.refresh()
                    publicIP.check()
                    wifiSSID.refresh(isWiFi: viewModel.currentInterface?.isWiFi ?? false)
                }
                .accessibilityLabel("Refresh")
                .accessibilityHint("Re-reads network state, public IP and Wi-Fi network")
                // Icon-only so it adds no new row — this whole feature
                // exists to save a manual screenshot-and-hand-it-over
                // step, so it needs to cost as little popover space as
                // the thing it replaces cost none.
                Button {
                    // `self` here, unmutated (isCapturingScreenshot is
                    // still false) — logs the real, on-screen-equivalent
                    // height before the capturing copy below swaps every
                    // scrollable section for a plain unclipped list. See
                    // `ScreenshotViewModel.measureAndLogLiveHeight`.
                    screenshot.measureAndLogLiveHeight(self, surface: surface)
                    // A copy, not `self` — see `isCapturingScreenshot`.
                    // `ContentView` is a struct, so this is a plain value
                    // copy that leaves the live popover untouched.
                    var capturing = self
                    capturing.isCapturingScreenshot = true
                    screenshot.capture(capturing)
                } label: {
                    Image(systemName: "camera")
                }
                .accessibilityLabel("Screenshot")
                .accessibilityHint("Saves an image of this popover and logs an event naming the file, so it can be found without guessing")
                // Deliberately a separate button from Screenshot above,
                // not a prompt bolted onto it — that one's whole value is
                // staying a fast, no-prompt capture. This one exists
                // specifically to stop and ask "what are you seeing,"
                // which the automated capture can't infer on its own.
                // See `bugReportRow` for the comment field this reveals,
                // and `ScreenshotViewModel.captureBugReport` for what it
                // captures (same screenshot + state-dump bundle, plus the
                // comment, build hash and current severity).
                Button {
                    bugReportDraft = ""
                    isReportingBug = true
                } label: {
                    Image(systemName: "ladybug")
                }
                .accessibilityLabel("Bug Report")
                .accessibilityHint("Saves a screenshot and state dump along with a comment describing what you're seeing")
                // Temporary, for comparing this fixed-height popover against
                // a resizable/scrollable window (see `NMSApp`'s "nms-window"
                // scene) — not a permanent footer addition. Gated by
                // `FeatureFlags.comparisonWindow`, off by default for a
                // fresh install, *and* `!isInWindow` — this button's whole
                // job is opening the resizable window from the popover; a
                // fixed `FeatureFlags.comparisonWindow` gate alone left it
                // sitting in the window's own footer too, where clicking it
                // just re-triggered opening the window you were already
                // looking at. The inverse of the `isInWindow &&` gate every
                // window-only *section* here uses (Wi-Fi, DHCP History,
                // SNMP Devices, Printer Alerts) — those only belong inside
                // the window; this button only belongs outside it.
                if FeatureFlags.comparisonWindow && !isInWindow {
                    Button("Open in Window") {
                        openWindowInFront("nms-window")
                    }
                    .accessibilityLabel("Open in Window")
                    .accessibilityHint("Opens the same content in a resizable, scrollable window")
                }
                Button("Networks…") {
                    openWindowInFront("known-networks")
                }
                .accessibilityLabel("Known Networks")
                .accessibilityHint("Opens a list of every network this Mac has connected to, with a way to forget one")
                Button("Preferences…") {
                    openWindowInFront("preferences")
                }
                .accessibilityLabel("Preferences")
                .accessibilityHint("Opens toggles for experimental features")
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .accessibilityLabel("Quit")
                .accessibilityHint("Quits NMS")
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
                    .appKitToolTip(
                        NMSApp.storeFallbackReason ?? "",
                        enabled: !isCapturingScreenshot
                    )
            }
    }

    /// A bordered box with a header row (title, plus an optional trailing
    /// accessory like "Trace Now") — the visual unit tiles in the grid
    /// above are built from. A plain `Divider()` no longer reads as a
    /// separator once two tiles sit side by side rather than stacked full
    /// width, so each tile draws its own border instead.
    @ViewBuilder
    private func tile(title: String, @ViewBuilder content: () -> some View) -> some View {
        tile(title: title, trailing: { EmptyView() }, content: content)
    }

    @ViewBuilder
    private func tile(
        title: String,
        @ViewBuilder trailing: () -> some View,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }

    /// The one place a fixed-height, independently-scrolling history box
    /// gets built — Events, SNMP Devices, DHCP History, Speed Test and
    /// traceroute hops all route through here.
    ///
    /// Each of these used to hand-roll the same three-way branch, which
    /// went wrong in the same way twice: **the capture branch is easy to
    /// forget, and forgetting it fails silently.** `ImageRenderer` doesn't
    /// render `ScrollView` content off-screen at all (not clipped —
    /// absent, confirmed 5-for-5 against a real screen capture), and it
    /// can't render `NoBounceScrollView`'s `NSViewRepresentable` any
    /// better; both times the result was a screenshot quietly missing
    /// whole sections, caught only by a bug report rather than by any
    /// error. Centralising it means a new section can't forget — there's
    /// no per-section capture branch left to omit.
    ///
    /// `rowCount` drives `SectionLayout.scrollThreshold`: below it, the
    /// content renders as a plain self-sizing `VStack`, because a box
    /// sized for the worst case leaves visible blank space under the 1-2
    /// rows that are usually there. The window always boxes regardless,
    /// so sections behave consistently there rather than silently losing
    /// their scroll container whenever the row count happens to be low.
    @ViewBuilder
    private func scrollBox(
        _ section: SectionLayout,
        rowCount: Int,
        spacing: CGFloat = 2,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let wantsBox = rowCount > section.scrollThreshold || surface == .window
        if !isCapturingScreenshot, wantsBox, let height = section.boxHeight(on: surface) {
            NoBounceScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: height)
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
        }
    }

    /// Everything the "Info" tile shows: the current interface's
    /// identifying details, a public-IP error if there is one, and the
    /// network-recognition status — previously inlined directly in `body`
    /// before Info became its own tile.
    @ViewBuilder
    private var infoSection: some View {
        if let info = viewModel.currentInterface {
            VStack(alignment: .leading, spacing: 2) {
                row("Network", networkDisplay(info))
                // BSSID moved to the Wi-Fi tile (window-only) — topically
                // at home there alongside Signal/Channel/PHY Rate rather
                // than here. Real tradeoff, not a silent one: this makes
                // BSSID strictly less discoverable than before, since Info
                // is popover-visible and the Wi-Fi tile isn't. Accepted —
                // it already sits in the same "niche per-device detail"
                // bucket SNMP Devices is in.
                row("IP Address", ipAddressDisplay(info))
                row("Router", routerDisplay(info))
                row("DNS Server", info.dnsServer ?? "—")
                row("Public IP", publicIP.currentIP ?? (publicIP.isChecking ? "Checking…" : "—"))
            }
        } else {
            Text("No active network connection")
                .foregroundStyle(.secondary)
        }

        if let error = publicIP.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }

        networkIdentityStatus
    }

    /// The label-entry input is hidden entirely now — this is read-only
    /// recognition status. A label, once set, still shows via the "Network"
    /// row in Info; there's just no in-popover way to enter/change one
    /// anymore.
    @ViewBuilder
    private var networkIdentityStatus: some View {
        if let network = networkIdentity.currentNetwork {
            HStack {
                Text(networkIdentity.isNewNetwork ? "New network" : "Known network")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("seen \(network.timesSeen)×")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Ordered low (most fundamental) to high (most dependent on
    /// everything below it working first).
    private var connectionLayersLowToHigh: [ConnectionLayer] {
        let info = viewModel.currentInterface

        // Interface and Network used to be separate rows, but checked
        // almost the same thing: Interface was a pure up/down signal
        // (`info != nil`), and Network's own status matched that exactly
        // except in one case — Wi-Fi with no name resolvable at all (no
        // recognized-network label, no live SSID), where the interface is
        // genuinely up but *which* network it is remains unknown. Combined
        // into one row rather than two nearly-redundant ones, reusing
        // `networkDisplay(_:)` (built for the Info section's equivalent
        // combined row) for the detail text.
        let networkLayer: ConnectionLayer
        if let info {
            let hasName = (networkIdentity.currentNetwork?.label?.isEmpty == false) || wifiSSID.currentSSID != nil
            let detail = networkDisplay(info)
            if info.isWiFi && !hasName {
                // Not a connectivity failure — just missing information
                // (e.g. Location permission not granted yet) — so this is
                // "unknown," not "unhealthy," even though the interface
                // itself is confirmed up.
                networkLayer = ConnectionLayer(id: "network", label: "Network", detail: detail, status: .unknown)
            } else {
                networkLayer = ConnectionLayer(id: "network", label: "Network", detail: detail, status: .healthy)
            }
        } else {
            // Not genuine uncertainty — with no interface at all, this is
            // *definitely* down, not merely unevaluated.
            networkLayer = ConnectionLayer(id: "network", label: "Network", detail: "Down", status: .unhealthy)
        }

        // Every row below reuses its matching `OverallStatus.*Label`
        // constant for its own display text, rather than a separately
        // hardcoded string that happens to read similarly. Two of them
        // used to diverge for real — "Local Router" here read "Router"
        // in the Events log, and "Internet Ping by address" read
        // "Internet" — since `ConnectivityViewModel.logTransitions`
        // builds every event message straight from `check.label`, which
        // *is* one of these constants. Referencing the same constant here
        // makes that agreement structural instead of two places that
        // happened to match today.
        let routerCheck = connectivity.checks.first { $0.label == OverallStatus.routerLabel }
        let localRouterLayer: ConnectionLayer
        if info == nil {
            // Same reasoning as Network above: no interface means no
            // router address was ever known to check, but that's a
            // certain consequence of the root cause, not genuine
            // uncertainty — cascade as unhealthy instead of `.unknown`.
            localRouterLayer = ConnectionLayer(id: "localRouter", label: OverallStatus.routerLabel, detail: "—", status: .unhealthy)
        } else {
            localRouterLayer = ConnectionLayer(
                id: "localRouter",
                label: OverallStatus.routerLabel,
                detail: routerCheck.map(checkDetail) ?? "Not checked",
                status: routerCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: routerCheck?.correlatedWithChange ?? false
            )
        }

        // Pinging the router's own public/WAN address, not a remote host —
        // verified directly (TTL 64, sub-millisecond RTT) that this is
        // answered locally by the gateway recognizing its own address, not
        // a real round trip to the internet. Sits between Local Router
        // (LAN-side reachability) and ISP Edge Router (one hop further
        // out) since that's exactly where it tests: whether the gateway's
        // WAN side is alive, catching e.g. an ISP modem/ONT losing power
        // that a LAN-side-only check can't see.
        let publicIPCheck = connectivity.checks.first { $0.label == OverallStatus.publicIPLabel }
        let publicIPLayer: ConnectionLayer
        if info == nil {
            publicIPLayer = ConnectionLayer(id: "publicIP", label: OverallStatus.publicIPLabel, detail: "—", status: .unhealthy)
        } else if publicIP.currentIP == nil {
            // Not a failure — `PublicIPViewModel`'s own (much slower,
            // 5-minute-cadence) lookup just hasn't completed yet, most
            // likely right after launch.
            publicIPLayer = ConnectionLayer(id: "publicIP", label: OverallStatus.publicIPLabel, detail: "Not checked", status: .unknown)
        } else {
            publicIPLayer = ConnectionLayer(
                id: "publicIP",
                label: OverallStatus.publicIPLabel,
                detail: publicIPCheck.map(checkDetail) ?? "Not checked",
                status: publicIPCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: publicIPCheck?.correlatedWithChange ?? false
            )
        }

        // Discovery (which hop is the ISP edge) and monitoring (is it still
        // reachable) are deliberately separate: `TracerouteViewModel` only
        // owns confirming *which* hop this is; `ConnectivityViewModel`
        // pings that hop's address on the same fast/reactive cadence as
        // Router/Internet/DNS/HTTP, so this reads like every other layer
        // here (a response time, not a re-trace's resolved hostname).
        let peRouterLayer: ConnectionLayer
        if info == nil {
            // Same reasoning as Network/Local Router/Public IP above: no
            // interface means no path exists to trace at all, which is a
            // certain consequence of the root cause, not genuine
            // uncertainty. Reported directly: without this branch, a
            // previously-confirmed hop fell through to the
            // `monitoredHop == nil` case below during a real outage and
            // showed "Not confirmed" — misleading, since that text means
            // "you haven't set this up yet," not "this is currently down."
            peRouterLayer = ConnectionLayer(id: "peRouter", label: OverallStatus.peRouterLabel, detail: "—", status: .unhealthy)
        } else if traceroute.monitoredHop == nil {
            // Not a failure — you haven't confirmed which traceroute hop is
            // the ISP's edge yet (see the Path to Internet section).
            peRouterLayer = ConnectionLayer(id: "peRouter", label: OverallStatus.peRouterLabel, detail: "Not confirmed", status: .unknown)
        } else {
            let peRouterCheck = connectivity.checks.first { $0.label == OverallStatus.peRouterLabel }
            peRouterLayer = ConnectionLayer(
                id: "peRouter",
                label: OverallStatus.peRouterLabel,
                detail: peRouterCheck.map(checkDetail) ?? "Not checked",
                status: peRouterCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: peRouterCheck?.correlatedWithChange ?? false
            )
        }

        let internetCheck = connectivity.checks.first { $0.label == OverallStatus.internetLabel }
        let internetLayer = ConnectionLayer(
            id: "internet",
            label: OverallStatus.internetLabel,
            detail: internetCheck.map(checkDetail) ?? "Not checked",
            status: internetCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: internetCheck?.correlatedWithChange ?? false
        )

        let dnsCheck = connectivity.checks.first { $0.label == OverallStatus.dnsLabel }
        let dnsLayer = ConnectionLayer(
            id: "dns",
            label: OverallStatus.dnsLabel,
            detail: dnsCheck.map(checkDetail) ?? "Not checked",
            status: dnsCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: dnsCheck?.correlatedWithChange ?? false
        )

        let httpCheck = connectivity.checks.first { $0.label == OverallStatus.httpLabel }
        let httpLayer = ConnectionLayer(
            id: "http",
            label: OverallStatus.httpLabel,
            detail: httpCheck.map(checkDetail) ?? "Not checked",
            status: httpCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: httpCheck?.correlatedWithChange ?? false
        )

        return [networkLayer, localRouterLayer, publicIPLayer, peRouterLayer, internetLayer, dnsLayer, httpLayer]
    }

    /// The lowest (most fundamental) unhealthy layer — everything failing
    /// *above* this one is presumed to be a consequence of this, not an
    /// independent problem, since each layer depends on the ones below it.
    private var rootCauseLayerID: String? {
        connectionLayersLowToHigh.first { $0.status == .unhealthy }?.id
    }

    @ViewBuilder
    private var connectionHealthSection: some View {
        let layers = connectionLayersLowToHigh
        VStack(alignment: .leading, spacing: 2) {
            ForEach(layers.reversed()) { layer in
                HStack {
                    Circle()
                        .fill(layerColor(for: layer))
                        .frame(width: 8, height: 8)
                    Text(layer.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    // Inline rather than on its own row: sized to one
                    // line of text, so it costs width but no height —
                    // the popover fits a 13" MacBook Air exactly.
                    // Absent for Network/Interface, which have no
                    // latency concept.
                    if let samples = latencyHistory[layer.id] {
                        Sparkline(values: samples.map(\.latencyMs))
                    }
                    Text(layer.detail + (layer.status == .unhealthy && layer.correlatedWithChange ? " *" : ""))
                        .foregroundStyle(layer.status == .unhealthy ? layerColor(for: layer) : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12))
            }

            if layers.contains(where: { $0.status == .unhealthy && $0.correlatedWithChange }) {
                Text("* possibly related to a recent network change")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        // Loaded when the section appears rather than kept continuously
        // up to date — the popover is shut almost all the time. Keyed on
        // `checks` so it also refreshes while the popover is *open* and a
        // new round lands, which is exactly when someone is watching a
        // problem develop.
        .task(id: connectivity.lastCheckedAt) {
            latencyHistory = connectivity.latencyHistory()
        }
    }

    private func layerColor(for layer: ConnectionLayer) -> Color {
        switch layer.status {
        case .healthy: return .green
        case .unknown: return .gray
        case .unhealthy:
            // Full red for the actual root cause; a dimmed red for
            // anything failing above it, which is probably just a
            // consequence rather than its own separate problem.
            return layer.id == rootCauseLayerID ? .red : Color.red.opacity(0.4)
        }
    }

    private func checkDetail(for check: ConnectivityCheck) -> String {
        check.success ? String(format: "%.0f ms", check.latencyMs ?? 0) : "unreachable"
    }

    /// Live reachability for one SNMP device, straight from this round's
    /// `ConnectivityViewModel.checks` rather than anything SNMP itself
    /// reports — `poll()` only runs every 60s and answers a different
    /// question (did the descriptor/uptime change), so it lags well behind
    /// the 5s-capable ping check during and right after an outage. Matched
    /// by `displayName`, the same label `ConnectivityViewModel.buildTargets`
    /// files the ping result under — except the router: `buildTargets`
    /// deliberately excludes the router's own SNMP entry from the
    /// "infrastructure" targets (to avoid pinging it twice) and instead
    /// checks it once under the fixed `OverallStatus.routerLabel` ("Router"),
    /// which never equals its SNMP `displayName` (its `sysName`, e.g.
    /// "router"). Recognized by IP against the current interface's router
    /// address instead. `nil` (not yet checked this session, e.g. right
    /// after a fresh scan) reads as unknown/gray, not down.
    private func deviceReachability(_ device: SNMPDevice) -> LayerStatus {
        let label = device.ipAddress == viewModel.currentInterface?.routerAddress
            ? OverallStatus.routerLabel
            : device.displayName
        guard let check = connectivity.checks.first(where: { $0.label == label }) else {
            return .unknown
        }
        return check.success ? .healthy : .unhealthy
    }

    /// Explains why the ISP Edge Router hop shown is only a guess until
    /// confirmed. See `tracerouteSection`'s `suggestedEdgeHop` branch for
    /// why this is a tooltip and not a visible line.
    private static let suggestedEdgeHopHelp = """
        Tap ★ next to the real ISP hop below to confirm — the first \
        non-local hop isn't always right on networks with their own \
        public IP space (e.g. campus/enterprise).
        """

    /// Only the `.unknown` case really needs explaining — green and red
    /// read themselves — but all three are worded so hovering any dot
    /// answers the same question rather than leaving one silent.
    private static func reachabilityHelp(_ status: LayerStatus) -> String {
        switch status {
        case .healthy:
            return "Reachable — answered the most recent ping."
        case .unhealthy:
            return "Unreachable — did not answer the most recent ping."
        case .unknown:
            return """
                Not checked yet — this device has no ping result in the \
                current round, which is not the same as being down. The \
                router is checked under its own Network Health row, and \
                only the first few discovered devices are pinged each \
                round.
                """
        }
    }

    private func deviceStatusColor(_ status: LayerStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .unknown: return .gray
        case .unhealthy: return .red
        }
    }

    /// SNMP-discovered infrastructure: each row is name + software
    /// descriptor + uptime, since those are what identify the device and
    /// reveal a restart. The leading dot is live reachability (see
    /// `deviceReachability`) — added because a device that restarted and
    /// already recovered could otherwise only be told apart from one that's
    /// still down by reading Events log ordering, which can itself lag (the
    /// slower SNMP-restart detection can log *after* the ping-based
    /// recovery for the same episode). This dot answers "is it up right
    /// now" directly instead.
    @ViewBuilder
    private var infrastructureList: some View {
        if !snmp.isAvailable {
            Text("snmpget unavailable on this macOS version")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if snmp.devices.isEmpty {
            Text(snmp.isScanning ? "Sweeping subnet…" : (snmp.lastScanAt == nil ? "Not scanned yet" : "No SNMP devices found"))
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            scrollBox(.snmpDevices, rowCount: snmp.devices.count) {
                infrastructureRows
            }
        }

        if let error = snmp.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }

        communityRow
    }

    private var infrastructureRows: some View {
        ForEach(snmp.devices) { device in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Circle()
                        .fill(deviceStatusColor(deviceReachability(device)))
                        .frame(width: 8, height: 8)
                        // Gray is the case this exists for: it means
                        // "no ping result yet," which looks identical to
                        // trouble at a glance and gets misread exactly
                        // when someone is scanning this list during an
                        // outage.
                        .appKitToolTip(
                            Self.reachabilityHelp(deviceReachability(device)),
                            enabled: !isCapturingScreenshot
                        )
                    Text(device.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(device.uptimeDescription)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                // No lineLimit here, deliberately — sysDescr (a raw
                // SNMP-provided string, no length guarantee) wraps to as
                // many lines as it needs instead of truncating, unlike
                // the single-line convention used elsewhere in this
                // popover.
                // Addresses shown only when there's more than one — a
                // single address is already implied by the row and would
                // just cost a line.
                if !device.aliasAddresses.isEmpty {
                    Text(device.addressDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(device.sysDescr)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Every real DHCP lease change (server, address, or timing actually
    /// differed — see `SnapshotStore.recordDHCPLeaseIfChanged`), newest
    /// first — new rows appear at the top and push earlier ones down into
    /// the scroll. The newest row doubles as "the current lease" — there's
    /// no separate current-lease display now that this list exists.
    /// Two lines per lease, every parsed field included across the two
    /// (see `dhcpPrimaryDetail`/`dhcpSecondaryDetail`) — a single
    /// unbroken line was tried first, but the full field set (server,
    /// address, broadcast, gateway, DNS, domain, lease/T1/T2, transaction
    /// ID) measured out to roughly 950-1000pt to fit without truncating,
    /// confirmed directly against a real lease — too wide for a menu-bar
    /// popover. Wrapping to two lines fits comfortably at this popover's
    /// current (doubled) width instead.
    @ViewBuilder
    private var dhcpHistoryList: some View {
        if !DHCPLeaseService.isAvailable {
            Text("ipconfig unavailable on this macOS version")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if dhcpLease.history.isEmpty {
            Text("No DHCP lease observed yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            scrollBox(.dhcpHistory, rowCount: dhcpLease.history.count, spacing: 4) {
                dhcpHistoryRows
            }
        }
    }

    private var dhcpHistoryRows: some View {
        ForEach(dhcpLease.history) { record in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(record.primaryDetail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(record.observedAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                Text(record.secondaryDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The densest jargon in the app, and the reason
                    // tooltips were built at all. Explains only the
                    // genuinely opaque parts — bcast/gw/dns need no
                    // gloss for this app's audience, while T1/T2 and a
                    // bare hex transaction ID do.
                    .appKitToolTip(DHCPLeaseRecord.transactionHelpText, enabled: !isCapturingScreenshot)
            }
        }
    }

    /// Sized to comfortably show 2 printers before scrolling — see
    /// `SectionLayout.printerAlerts` for how that height was arrived at
    /// and why it carries a row of headroom rather than sitting exactly
    /// on the 2-row boundary.
    @ViewBuilder
    private var printerAlertsList: some View {
        scrollBox(.printerAlerts, rowCount: connectivity.printerStatuses.count, spacing: 0) {
            printerAlertRows
        }
    }

    /// One row per CUPS-configured printer — a colored dot (green: no
    /// alerts, red: `reasons` non-empty) plus the reasons themselves when
    /// present. `PrinterDiscoveryService.PrinterAlert` has no reachability
    /// concept of its own, so unlike `infrastructureRows` there's no
    /// "unknown/gray" state here — CUPS always reports *something*
    /// (`none`, if nothing's wrong).
    private var printerAlertRows: some View {
        ForEach(connectivity.printerStatuses) { printer in
            HStack {
                Circle()
                    .fill(printer.reasons.isEmpty ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(printer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(printer.reasons.isEmpty ? "OK" : printer.reasons.joined(separator: ", "))
                    .foregroundStyle(printer.reasons.isEmpty ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
        }
    }

    /// Current signal/link characteristics plus a short RSSI trend —
    /// window-only, see this section's call site in `body`. Reuses
    /// `Sparkline` (generalized from Network Health's latency-only
    /// version) rather than a second, parallel mini-chart type.
    @ViewBuilder
    private var wifiSection: some View {
        // Moved from Info — see that section's call site for the
        // discoverability tradeoff. Shown first, before Signal: it
        // identifies *which* access point, which is the natural thing to
        // read before that AP's own signal/link characteristics below —
        // same ordering Info used to have (right after Network).
        if let bssid = wifiSSID.currentBSSID {
            row("BSSID", bssid)
        }
        // Not the plain `row(_:_:)` helper, so the sparkline can sit
        // inline between label and value — same layout Network Health's
        // per-layer rows already use for their own sparklines.
        HStack {
            Text("Signal")
                .foregroundStyle(.secondary)
            Spacer()
            if wifiSSID.recentSamples.count > 1 {
                Sparkline(values: wifiSSID.recentSamples.reversed().map { $0.rssi.map(Double.init) })
            }
            Text(wifiSignalDetail)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        row("Channel", wifiChannelDetail)
        if let rate = wifiSSID.currentPHYRateMbps {
            row("PHY Rate", "\(Int(rate)) Mbps")
        }
        if let security = wifiSSID.currentSecurity {
            row("Security", security)
        }
    }

    /// RSSI plus its trend, with an SNR parenthetical when noise is also
    /// available — "-52 dBm (SNR 38 dB)". Noise isn't always reported (some
    /// adapters/driver states omit it), so the SNR half is conditional
    /// rather than showing a misleading partial calculation.
    private var wifiSignalDetail: String {
        guard let rssi = wifiSSID.currentRSSI else { return "—" }
        if let noise = wifiSSID.currentNoise {
            return "\(rssi) dBm (SNR \(rssi - noise) dB)"
        }
        return "\(rssi) dBm"
    }

    private var wifiChannelDetail: String {
        guard let number = wifiSSID.currentChannelNumber else { return "—" }
        guard let band = wifiSSID.currentChannelBand else { return "\(number)" }
        return "\(number) (\(band))"
    }

    /// The "Speed Test" tile's full content: the data-cost note (moved
    /// here from the header once the button moved into the tile's
    /// trailing slot, matching Path to Internet's "Trace Now"), any
    /// error, then the recent-runs list.
    @ViewBuilder
    private var speedTestTileContent: some View {
        HStack {
            Text("up to ~50MB per run")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            // Secondary, plain-styled — this tile already has one
            // first-class action (the header's "Run Speed Test"); a
            // second prominent button competing for the same slot would
            // suggest a choice that doesn't need to be made every time.
            // Shares `isRunning`/`recentRuns` with the Cloudflare path
            // rather than getting its own tile: both are answers to
            // "how's my connection right now," just at different costs
            // (~1s vs ~30s) and depths (throughput vs. throughput +
            // responsiveness under load) — one history, one place to
            // compare them, matching how this was originally scoped in
            // DESIGN-NOTES.md before the RPM half was deferred.
            if networkQuality.isAppleTestAvailable {
                Button(networkQuality.isRunning ? "Testing…" : "Run Network Quality") {
                    networkQuality.runAppleTest(interfaceName: viewModel.currentInterface?.interfaceName)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .disabled(networkQuality.isRunning)
                .accessibilityLabel(networkQuality.isRunning ? "Testing" : "Run Network Quality")
                .accessibilityHint("Runs Apple's own network quality test: throughput plus responsiveness under load. Uses your data plan and takes about 30 seconds.")
            }
        }
        speedTestList
        if let error = networkQuality.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }

    /// Every real speed-test run, newest first — a genuine time series
    /// (see `NetworkQualityResult`), not a change-log, so unlike DHCP
    /// History every run gets a row regardless of whether the numbers
    /// differ from the last one. Same size-to-fit-else-scroll threshold
    /// as `dhcpHistoryList`: a fixed-height `ScrollView` only earns its
    /// keep once there are actually more rows than comfortably fit.
    @ViewBuilder
    private var speedTestList: some View {
        if networkQuality.recentRuns.isEmpty {
            Text(networkQuality.isRunning ? "Testing…" : "No speed test run yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            scrollBox(.speedTest, rowCount: networkQuality.recentRuns.count) {
                speedTestRows
            }
        }
    }

    /// One line per run for the throughput/timestamp row: unlike DHCP
    /// History's secondary line, "↓ 765 Mbps  ↑ 173 Mbps" plus a
    /// time-only (no date) timestamp is short enough to fit this tile's
    /// half-width comfortably — confirmed directly against a real
    /// screenshot rather than assumed from the two-line version tried
    /// first. An Apple-sourced run adds a second line for RPM/base
    /// latency, the data a Cloudflare-endpoint run simply doesn't have —
    /// every Cloudflare row keeps looking exactly as it always has.
    private var speedTestRows: some View {
        ForEach(networkQuality.recentRuns) { run in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("↓ \(Self.mbpsText(run.downloadMbps))  ↑ \(Self.mbpsText(run.uploadMbps))")
                    Spacer()
                    Text(run.testedAt, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                if run.source == NetworkQualityResult.Source.appleNetworkQuality.rawValue {
                    Text(Self.appleQualityDetail(run))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// RPM under load, split by direction — the signal this whole second
    /// source exists for — plus idle base latency, the one other figure
    /// `networkQuality` measures that Cloudflare's plain file transfer
    /// has no equivalent of.
    private static func appleQualityDetail(_ run: NetworkQualityRecord) -> String {
        var parts = ["Apple"]
        if let dl = run.downloadResponsivenessRPM, let ul = run.uploadResponsivenessRPM {
            parts.append("RPM \(dl)↓/\(ul)↑")
        }
        if let rtt = run.baseRTTMs {
            parts.append(String(format: "base %.0fms", rtt))
        }
        return parts.joined(separator: " · ")
    }

    private static func mbpsText(_ value: Double) -> String {
        String(format: "%.0f Mbps", value)
    }

    /// First line: server and assigned address/CIDR — the two fields
    /// that identify *this* lease at a glance, alongside the timestamp.
    // dhcpPrimaryDetail/dhcpSecondaryDetail/dhcpLeaseHelp moved to
    // `DHCPLeaseRecord.primaryDetail`/`.secondaryDetail`/`.transactionHelpText`
    // so Network Review can render the same lease-history line without
    // duplicating the subnet-mask/T1/T2/transaction-ID formatting.

    /// Community strings are shared read-only passwords, not per-user
    /// secrets, and "public" is the near-universal default — so they're
    /// editable inline rather than hidden behind a settings window this app
    /// doesn't have. Comma-separated, and the order shown is the order
    /// they're tried in.
    @ViewBuilder
    private var communityRow: some View {
        if isEditingCommunity {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    TextField("public, private", text: $communityDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { commitCommunity() }
                    Button("Set") { commitCommunity() }
                        .accessibilityLabel("Set community strings")
                        .font(.system(size: 11))
                }
                Text("Comma-separated, tried in order — put the most common first.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        } else if snmp.isAvailable {
            HStack {
                Text("Community: \(snmp.communities.joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change") {
                    communityDraft = snmp.communities.joined(separator: ", ")
                    isEditingCommunity = true
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Change community strings")
                .accessibilityHint("Edits the SNMP community strings used for discovery")
            }
        }
    }

    private func commitCommunity() {
        snmp.setCommunities(communityDraft)
        isEditingCommunity = false
    }

    /// The footer's Bug Report button reveals this in place of nothing
    /// (unlike `communityRow`, there's no persistent summary state to
    /// show when inactive — a bug report isn't a setting) — same
    /// TextField/Button/`onSubmit` shape as `communityRow`, one row, no
    /// new vertical cost when inactive.
    ///
    /// Tinted/bordered rather than plain text, unlike the DEBUG-overrides
    /// banner above (`FailureInjector.activeOverridesSummary`, orange
    /// text with a ⚠ prefix, no box) — that one only ever needs to be
    /// *noticed* in an otherwise-static footer; this one needs to read as
    /// "you are now in a distinct mode, everything below applies to a
    /// report you're composing," which a color/weight change alone
    /// doesn't convey as clearly as a contained shape does.
    @ViewBuilder
    private var bugReportRow: some View {
        if isReportingBug {
            VStack(alignment: .leading, spacing: 4) {
                Label("Bug Report", systemImage: "ladybug.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                HStack {
                    // `.textFieldStyle(.plain)` on the capture chain
                    // (`ScreenshotViewModel`) wasn't enough on its own —
                    // confirmed against a real capture, still the same
                    // solid-yellow-bar-with-a-red-"prohibited"-glyph
                    // glitch, not just an unstyled-but-legible field.
                    // Whatever `ImageRenderer` is doing here goes deeper
                    // than border chrome — plausibly trying to draw a
                    // live insertion-point/field-editor for a field that
                    // has no real focus/window context off-screen. Same
                    // fix as every other `ImageRenderer` gap in this
                    // file: don't ask it to render the broken control at
                    // all. A plain `Text` has nothing native to fail to
                    // draw, and needs no interaction during a capture
                    // anyway.
                    if isCapturingScreenshot {
                        Text(bugReportDraft.isEmpty ? "What are you seeing?" : bugReportDraft)
                            .font(.system(size: 11))
                            .foregroundStyle(bugReportDraft.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("What are you seeing?", text: $bugReportDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .onSubmit { submitBugReport() }
                    }
                    Button("Submit") { submitBugReport() }
                        .accessibilityLabel("Submit bug report")
                        .font(.system(size: 11))
                    Button("Cancel") {
                        bugReportDraft = ""
                        isReportingBug = false
                    }
                    .accessibilityLabel("Cancel bug report")
                    .font(.system(size: 11))
                }
                Text("Saved with a screenshot, the current build, and severity — a blank comment still saves those.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
            )
            Divider()
        }
    }

    /// Severity computed the same way `NMSApp.overallStatus` does
    /// (`OverallStatus.compute`), duplicated here rather than threading
    /// a new parameter through `NMSApp.contentView(surface:)` and its
    /// two call sites (the popover and the comparison window). This
    /// view model wiring has already caused three real bugs from a
    /// dependency not being ready when first read (see `NMSApp
    /// .wireDerivedStateDependencies`'s doc comment) — a one-line formula
    /// repeated once is a smaller, more local cost than adding a new edge
    /// to that graph for a debug-adjacent feature.
    private func submitBugReport() {
        let status = OverallStatus.compute(interfaceIsDown: viewModel.currentInterface == nil, checks: connectivity.checks)
        let severityDescription: String
        switch status {
        case .normal: severityDescription = "Normal"
        case .marginal: severityDescription = "Marginal"
        case .critical: severityDescription = "Critical"
        }

        // Logged here as well as from the Screenshot button, and for the
        // same cost (one extra render, no file written). A bug report is
        // the *more* informative moment of the two — it arrives with a
        // human comment saying what looked wrong — so having it silently
        // contribute no height data was a gap: several reports have been
        // filed about the popover's layout while this number, the one
        // thing that would have dated them against a real measurement,
        // went unrecorded. Must run before the capturing copy below, so
        // it measures the live layout rather than the deliberately
        // unclipped capture.
        screenshot.measureAndLogLiveHeight(self, surface: surface)

        // Same copy-not-self pattern as the Screenshot button — see its
        // comment for why `isCapturingScreenshot` needs a value copy.
        var capturing = self
        capturing.isCapturingScreenshot = true
        screenshot.captureBugReport(
            capturing,
            comment: bugReportDraft,
            buildInfo: buildInfo,
            severityDescription: severityDescription
        )
        bugReportDraft = ""
        isReportingBug = false
    }

    @ViewBuilder
    private var eventList: some View {
        if eventLog.events.isEmpty {
            // Explains *why* it's empty rather than just stating that it
            // is — a bare "No events yet" on a fresh install (with a
            // perfectly healthy network) reads as "is this broken?" to a
            // new user. Deliberately not backfilled with synthetic
            // "everything came up fine" events instead: this log is meant
            // to be a trustworthy record of things that actually
            // happened, and fabricated entries at install would be
            // indistinguishable from real ones later.
            Text("No events yet — everything's healthy. Entries appear here when something changes (an outage or a recovery).")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                // Holds the same height the populated list would occupy,
                // so a first event appearing doesn't make the whole
                // popover jump.
                .frame(height: SectionLayout.events.boxHeight(on: surface), alignment: .top)
        } else {
            scrollBox(.events, rowCount: eventLog.events.count) {
                eventRows
            }
        }
    }

    /// Capped when capturing, uncapped on screen — the opposite of every
    /// other section here, and deliberate. On screen the list scrolls, so
    /// depth is free; in a capture every row is rendered unclipped, so
    /// depth is *height*, and height is legibility: a 39-event capture is
    /// already ~3300px tall, and the full 200-event fetch would run
    /// ~10,000px, which downscales to unreadable in any viewer. Since
    /// being readable is the entire reason the capture exists (see
    /// `ScreenshotService`), a legible window onto recent history beats a
    /// complete but illegible one. 50 keeps captures at roughly the size
    /// already confirmed readable.
    private var eventRows: some View {
        ForEach(isCapturingScreenshot ? Array(eventLog.events.prefix(50)) : eventLog.events) { event in
            HStack {
                Text(event.message)
                    .font(.system(size: 12))
                    .foregroundStyle(eventColor(for: event))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var tracerouteSection: some View {
        if viewModel.currentInterface == nil {
            // Reported directly: without this, a real outage fell through
            // to stale hop data from before the interface went down (or,
            // if the trace attempt during the outage returned an empty
            // result, to "Not traced yet") — either way, nothing here
            // said the actual, certain cause was "there's no interface to
            // trace from at all." Same reasoning as Network Health's
            // Network/Local Router/ISP Edge Router rows: this is a
            // certain consequence of the root cause, not something to
            // leave looking like stale-but-plausible data.
            Text("Interface down")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if let monitored = traceroute.monitoredHop {
            // No summary row here for the monitored hop's name/address —
            // that's already shown in Network Health above (as a response
            // time, not a name) and in the starred row in the hops list
            // below, so a third copy was just a spare line.
            Button("Stop monitoring hop \(monitored.hopNumber)") {
                traceroute.monitorHop(nil)
                // Drops the ISP Edge Router ping target on the next round —
                // check right away instead of leaving Network Health
                // showing its last (now stale) status for up to 30s.
                connectivity.runChecks()
            }
            .font(.system(size: 11))
            .accessibilityLabel("Stop monitoring hop \(monitored.hopNumber)")
            .accessibilityHint("Stops treating this hop as the ISP edge router")
        } else if let suggested = traceroute.suggestedEdgeHop {
            // A separate wrapped-text row here used to explain this, at a
            // real height cost: every *new* network starts unconfirmed, so
            // this branch — and the extra line — appeared on every network
            // visited for the first time, not just occasionally. Testing
            // on other networks is exactly what surfaced it, since the
            // home network's hop had long since been confirmed and never
            // showed the branch at all. A tooltip on the row itself, same
            // pattern as `dhcpLeaseHelp`/`reachabilityHelp`, keeps the
            // explanation without the line.
            row("Suggested (unconfirmed)", suggested.hostname ?? suggested.address ?? "—")
                .appKitToolTip(Self.suggestedEdgeHopHelp, enabled: !isCapturingScreenshot)
        } else if traceroute.isRunning {
            Text("Tracing…")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if traceroute.hops.isEmpty {
            Text("Not traced yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }

        // Both of these are independent of the branch above, and both
        // would otherwise keep showing stale pre-outage data (a lingering
        // error, or the last real hop list) underneath "Interface down" —
        // exactly the confusing mix that branch exists to avoid.
        if viewModel.currentInterface != nil, let error = traceroute.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }

        if viewModel.currentInterface != nil, !traceroute.hops.isEmpty {
            scrollBox(.pathToInternet, rowCount: displayedHops.count) {
                hopRows
            }
        }
    }

    @ViewBuilder
    private var hopRows: some View {
        ForEach(displayedHops) { hop in
            HStack {
                Text("\(hop.hopNumber)")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
                Text(hopLabel(for: hop))
                    .foregroundStyle(hopColor(for: hop))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(hopRTT(for: hop))
                    .foregroundStyle(.secondary)
                Button {
                    let isMonitored = traceroute.monitoredHopNumber == hop.hopNumber
                    traceroute.monitorHop(isMonitored ? nil : hop.hopNumber)
                    // New/changed ISP Edge Router ping target — check right
                    // away instead of waiting up to 30s for the next round.
                    connectivity.runChecks()
                } label: {
                    Image(systemName: traceroute.monitoredHopNumber == hop.hopNumber ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .disabled(hop.address == nil)
                // Icon-only, so there is no text for VoiceOver to fall back
                // on — without this it announces only "button".
                .accessibilityLabel(
                    traceroute.monitoredHopNumber == hop.hopNumber
                        ? "Monitored ISP edge router, hop \(hop.hopNumber)"
                        : "Monitor hop \(hop.hopNumber) as ISP edge router"
                )
            }
            .font(.system(size: 11))
        }
    }

    /// Once a hop is confirmed as the one to monitor, hops beyond it (closer
    /// to the actual destination, e.g. `1.1.1.1`) aren't relevant to "the
    /// path to my ISP" and just add noise — so they're hidden. Before
    /// confirmation, the full path still shows, since you need to see hops
    /// beyond the auto-suggested one to pick a different, correct one on
    /// networks where the suggestion doesn't hold (see `suggestedEdgeHop`).
    private var displayedHops: [TracerouteHop] {
        guard let monitoredHopNumber = traceroute.monitoredHopNumber else { return traceroute.hops }
        return traceroute.hops.filter { $0.hopNumber <= monitoredHopNumber }
    }

    private func hopLabel(for hop: TracerouteHop) -> String {
        guard let address = hop.address else { return "* (no response)" }
        return hop.hostname ?? address
    }

    private func hopColor(for hop: TracerouteHop) -> Color {
        if traceroute.monitoredHopNumber == hop.hopNumber {
            return .blue
        }
        switch hop.isLocal {
        case true: return .secondary
        case false: return .primary
        case nil: return .secondary
        }
    }

    private func hopRTT(for hop: TracerouteHop) -> String {
        guard let rtt = hop.roundTripMs else { return "—" }
        return String(format: "%.0f ms", rtt)
    }

    private func eventColor(for event: AppEventRecord) -> Color {
        guard let kind = AppEventKind(rawValue: event.kind) else { return .primary }
        switch kind.polarity {
        case .positive: return .green
        case .negative: return .red
        case .neutral: return .primary
        }
    }

    /// Network name (if any) plus connection type combined into one row
    /// (e.g. "Thistle Wi-Fi", "Thistle Ethernet", or just "Ethernet" with
    /// no known name yet) instead of separate "Network"/"Interface" and
    /// "Type" rows, to save vertical space in the Info section. Prefers a
    /// user-assigned network label over the live Wi-Fi SSID over nothing
    /// at all — the raw interface hardware name (e.g. "USB 10/100/1000
    /// LAN") is dropped entirely here in favor of just the connection
    /// type, since it added little once a name or type is already shown.
    private func networkDisplay(_ info: NetworkInterfaceInfo) -> String {
        let type = info.isWiFi ? "Wi-Fi" : "Ethernet"
        let label = networkIdentity.currentNetwork?.label
        let name = (label?.isEmpty == false ? label : nil) ?? wifiSSID.currentSSID
        guard let name else { return type }
        return "\(name) \(type)"
    }

    /// Just the IP — deliberately not appending the router's `KnownNetwork`
    /// fingerprint the way this used to. That was originally a bare MAC
    /// address, shown so a VRRP failover between two physical boxes at the
    /// same IP would be visible without cross-referencing the SNMP device
    /// list. Once the per-network scoping work changed `fingerprint` to
    /// `routerMAC|subnet` (see DESIGN-NOTES.md's "Per-network device
    /// scoping"), this row started leaking that internal identity string
    /// verbatim — `10.0.0.1 (bc:b9:23:81:a6:d4|10.0.0.0/24)` — never a
    /// deliberate display choice, just an unaudited side effect. Reported
    /// directly; simplified to the plain IP rather than reconstructing a
    /// clean bare-MAC-only version, since that's what was actually asked
    /// for.
    private func routerDisplay(_ info: NetworkInterfaceInfo) -> String {
        info.routerAddress ?? "—"
    }

    /// Opens a window scene *and* actually puts it in front. Used by all
    /// three footer buttons (Open in Window, Networks…, Preferences…).
    ///
    /// Three separate things conspire here, which is why the first
    /// attempt — a bare `NSApp.activate` immediately after `openWindow` —
    /// worked often enough to look fixed, then didn't:
    ///
    /// 1. NMS runs as `.accessory` (no Dock icon, no app-switcher entry;
    ///    see `AppDelegate`), so macOS won't activate it just because one
    ///    of its windows opened. That needs an explicit `activate`.
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

    /// IP address and subnet mask combined into one CIDR-notation row
    /// (e.g. "10.0.0.152/24") instead of two separate rows, to save
    /// vertical space in the Info section.
    private func ipAddressDisplay(_ info: NetworkInterfaceInfo) -> String {
        guard let ip = info.ipAddress else { return "—" }
        guard let mask = info.subnetMask, let prefix = SubnetCalculator.prefixLength(subnetMask: mask) else {
            return ip
        }
        return "\(ip)/\(prefix)"
    }

    /// `nil` before anything has ever been written to `storeURL` (e.g.
    /// the in-memory fallback path, or a fresh install's very first
    /// instant) — see `StoreSizeService`, which reports that case as
    /// absent rather than a misleading "0 bytes".
    private var storeSizeText: String? {
        StoreSizeService.formattedSize(at: storeURL)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
    }
}
