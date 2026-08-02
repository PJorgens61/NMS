import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @ObservedObject var lanDiscovery: LANDiscoveryViewModel
    @ObservedObject var connectivity: ConnectivityViewModel
    @ObservedObject var networkIdentity: NetworkIdentityViewModel
    @ObservedObject var publicIP: PublicIPViewModel
    @ObservedObject var ispIdentity: ISPIdentityViewModel
    @ObservedObject var dhcpLease: DHCPLeaseViewModel
    @ObservedObject var networkQuality: NetworkQualityViewModel
    @ObservedObject var screenshot: ScreenshotViewModel
    @ObservedObject var wifiSSID: WiFiSSIDViewModel
    @ObservedObject var eventLog: EventLogViewModel
    @ObservedObject var traceroute: TracerouteViewModel
    @ObservedObject var snmp: SNMPViewModel
    @ObservedObject var saasMonitoring: SaaSMonitoringViewModel
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

    /// A copy with `isCapturingScreenshot` set — used by both the
    /// Screenshot and Bug Report footer buttons, which otherwise had this
    /// same three-line copy-and-flip duplicated at each call site. `self`
    /// is a struct, so this is a plain value copy that leaves the live
    /// popover untouched — not `self` directly, per `isCapturingScreenshot`'s
    /// own doc comment above.
    private var capturingScreenshotCopy: ContentView {
        var capturing = self
        capturing.isCapturingScreenshot = true
        return capturing
    }

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
    /// two top-level arrangements, and the footer's "Expert Mode" button
    /// hiding itself once you're already there. Section visibility
    /// and box heights deliberately do **not** go through this — they read
    /// `SectionLayout` instead, so the popover's contents stay a closed,
    /// testable list.
    private var isInWindow: Bool { surface == .window }

    /// Lets the footer's "Expert Mode" button bring up the `Window` scene
    /// declared in `NMSApp` — see that scene for why it exists (every
    /// diagnostic section in one resizable window, versus the popover's
    /// deliberately narrower scope).
    @Environment(\.openWindow) private var openWindow

    // Not `private` — `communityRow`/`commitCommunity` live in
    // ContentView+Window.swift, and Swift's `private` doesn't cross files
    // even between extensions of the same type.
    @State var communityDraft: String = ""
    @State var isEditingCommunity = false
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
            // Network Health, Info, Path to Internet, and Speed Test are
            // all fixed to `ContentView.tileHeight` (see that constant's
            // doc comment for the three earlier, more intricate alignment
            // mechanisms this replaced — a dynamically-synced `Grid` row
            // for one pair, deliberately independent sizing for the
            // other). Every tile now sizes the same simple way.
            //
            // Window-only: reported from offsite testing that the 2-up
            // arrangement left too little width for a tile's text to
            // read comfortably, so the window stacks all four full-width
            // instead — more width for the same fixed height. Left
            // untouched on the popover, which stays the tight 2-up
            // layout it's always been (the popover's fixed height budget
            // is already the constraint this app has fought hardest —
            // see `SectionLayout` — so a taller stack isn't a free win
            // there the way it is in the resizable window).
            VStack(spacing: 12) {
                if surface == .window {
                    tile(title: "Network Health", fixedHeight: Self.tileHeight) {
                        connectionHealthSection
                    }
                    tile(title: "Info", fixedHeight: Self.tileHeight) {
                        infoSection
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        tile(title: "Network Health", fixedHeight: Self.tileHeight) {
                            connectionHealthSection
                        }
                        tile(title: "Info", fixedHeight: Self.tileHeight) {
                            infoSection
                        }
                    }
                }
                // Path to Internet + Speed Test — see
                // `ContentView+Window.swift`'s `pathAndSpeedRow`. Window-only
                // already (both tiles' `SectionLayout` entries are
                // `[.window]`), so this contributes nothing on the popover.
                pathAndSpeedRow
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

            // Same two-independent-gates shape as SNMP Devices below:
            // `FeatureFlags.saasMonitoring` answers a consent question
            // (this reaches out to third-party services, not just this
            // Mac's own LAN); `SectionLayout` answers a space question.
            // Placed near Wi-Fi, not with the other full-width sections
            // below — same reasoning: read-at-a-glance current state, not
            // scrollable history.
            if FeatureFlags.saasMonitoring, SectionLayout.saasMonitoring.appears(on: surface) {
                Divider()

                Text("SaaS Status")
                    .font(.headline)

                saasMonitoringSection
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
                    // No longer the only way to populate this list —
                    // `SNMPViewModel.activate()` now sweeps automatically
                    // the first time this feature has nothing rehydrated
                    // from history. This stays for the case that leaves:
                    // forcing a fresh sweep to find a device added to the
                    // LAN after that first discovery, which nothing else
                    // triggers.
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
            // away via Expert Mode) but expensive to keep paying for in
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

    /// Refresh/Screenshot/Bug Report/Expert Mode/Networks…/
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
                    screenshot.capture(capturingScreenshotCopy)
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
                // A permanent part of the footer now, not the experimental
                // "compare this against a resizable window" toggle it
                // started as (see `NMSApp`'s "nms-window" scene) —
                // `FeatureFlags.comparisonWindow` is gone entirely, along
                // with its `PreferencesView` toggle. Still gated on
                // `!isInWindow` alone: this button's whole job is opening
                // Expert Mode *from* the popover, and without that guard
                // it would also sit in the window's own footer, where
                // clicking it just re-triggers opening the window you're
                // already looking at. The inverse of the `isInWindow &&`
                // gate every window-only *section* here uses (Wi-Fi, DHCP
                // History, SNMP Devices, Printer Alerts) — those only
                // belong inside the window; this button only belongs
                // outside it.
                if !isInWindow {
                    Button("Expert Mode…") {
                        openWindowInFront("nms-window")
                    }
                    .accessibilityLabel("Expert Mode")
                    .accessibilityHint("Opens the same content in a resizable window, with every diagnostic section — Events, SNMP Devices, DHCP History, Wi-Fi detail, Path to Internet, Speed Test, Printer Alerts")
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
    static let tileHeight: CGFloat = 180

    /// A bordered box with a header row (title, plus an optional trailing
    /// accessory like "Trace Now") — the visual unit tiles in the grid
    /// above are built from. A plain `Divider()` no longer reads as a
    /// separator once two tiles sit side by side rather than stacked full
    /// width, so each tile draws its own border instead.
    // Not `private` — called from `ContentView+Window.swift`'s
    // `pathAndSpeedRow`, and Swift's `private` doesn't cross files even
    // between extensions of the same type.
    @ViewBuilder
    func tile(title: String, fixedHeight: CGFloat? = nil, @ViewBuilder content: () -> some View) -> some View {
        tile(title: title, fixedHeight: fixedHeight, trailing: { EmptyView() }, content: content)
    }

    /// `fixedHeight` fixes the *whole tile* to that height and makes
    /// `content()` scroll internally to fit whatever's left after the
    /// header row and padding — so content shorter than the tile just
    /// leaves blank space below it, and content taller than the tile
    /// scrolls instead of growing the box. One mechanism, applied
    /// uniformly, rather than syncing some tiles' heights to each other's
    /// content dynamically (the three earlier, more intricate attempts
    /// `ContentView.tileHeight`'s doc comment describes).
    ///
    /// **First version of this was broken, confirmed by a live
    /// screenshot**: every tile collapsed to just its header row, content
    /// invisible. Two independent mistakes, not one:
    /// 1. The outer `.frame(maxHeight: fixedHeight)` only *caps* height —
    ///    it doesn't force a smaller natural size to grow to fill it. A
    ///    `maxHeight` alone left the tile at whatever tiny size its
    ///    (empty-looking) content produced.
    /// 2. The inner `NoBounceScrollView` got `.frame(maxHeight: .infinity)`,
    ///    on the assumption a `VStack` would automatically hand it
    ///    "whatever's left" the way it does a native `ScrollView`. It
    ///    doesn't: `NoBounceScrollView` is an `NSViewRepresentable`, not a
    ///    flexible SwiftUI container, and every *other* use of it in this
    ///    file already gives it an explicit `.frame(height:)` — this
    ///    should have followed that precedent instead of assuming
    ///    automatic space distribution would apply to a custom view too.
    ///
    /// Fixed by making both heights explicit rather than relying on
    /// flexible-layout distribution: `minHeight == maxHeight` forces the
    /// outer tile to exactly `fixedHeight` (a cap alone can't shrink
    /// below content, but it also can't grow to it — matching both
    /// bounds is what actually fixes a size), and the inner scroll area
    /// gets a computed, explicit height (`fixedHeight` minus the header
    /// row and padding) rather than an unenforced "fill available space."
    ///
    /// `nil` (the default) keeps the old behavior: the tile sizes to its
    /// own content, no scrolling, no fixed height — still used by nothing
    /// today now that all four top tiles pass `ContentView.tileHeight`,
    /// but kept as the default rather than removed, since a future tile
    /// that genuinely wants to just size to its content shouldn't have to
    /// fake a height to get that.
    ///
    /// **A second bug, caught by an actual Bug Report capture, not by
    /// inspection.** The first version of this ignored
    /// `isCapturingScreenshot` entirely, so every capture of a
    /// `fixedHeight` tile rendered the tile's whole content area as a
    /// solid yellow "prohibited" glyph instead of real content —
    /// `ImageRenderer` can't render `NoBounceScrollView`'s
    /// `NSViewRepresentable` off-screen any better than a plain
    /// `ScrollView` (see `ScreenshotService`'s own doc comment, quirk 1),
    /// and this is the exact "the capture branch is easy to forget, and
    /// forgetting it fails silently" bug class `scrollBox` was built to
    /// close off — reopened here because this function duplicates
    /// `scrollBox`'s scrolling logic instead of routing through it.
    /// Fixed by treating `fixedHeight` as inert during a capture, same as
    /// `scrollBox` already does: the tile renders as a plain, unclipped
    /// `VStack` showing everything, at whatever height that needs, rather
    /// than trying to force a `NoBounceScrollView` capture to work.
    @ViewBuilder
    func tile(
        title: String,
        fixedHeight: CGFloat? = nil,
        @ViewBuilder trailing: () -> some View,
        @ViewBuilder content: () -> some View
    ) -> some View {
        // `nil` during a capture regardless of what was passed in — see
        // this function's doc comment for the Bug Report that found why.
        let effectiveHeight = isCapturingScreenshot ? nil : fixedHeight
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                trailing()
            }
            if let effectiveHeight {
                NoBounceScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        content()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // An explicit number, not `.infinity` — see this
                // function's doc comment for why relying on automatic
                // flexible-space distribution didn't work here.
                // `Self.tileHeaderOverhead` is a first estimate (padding
                // + spacing + one `.headline` line), not measured against
                // a real screenshot — worth calibrating precisely if this
                // ever needs to be exact, though the generous, scroll-
                // absorbs-the-rest sizing this tile already uses means it
                // doesn't currently have to be.
                .frame(height: max(0, effectiveHeight - Self.tileHeaderOverhead))
            } else {
                content()
            }
        }
        .padding(10)
        // `minHeight` and `maxHeight` both set to `effectiveHeight` forces
        // an exact size — `maxHeight` alone is only a cap, and doesn't
        // make a smaller natural size grow to fill it (the first bug this
        // function's doc comment describes). Both `nil` when
        // `effectiveHeight` is `nil` (including during a capture) is
        // still "no height constraint at all, size to content."
        .frame(maxWidth: .infinity, minHeight: effectiveHeight, maxHeight: effectiveHeight, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }

    /// First estimate for `tile(fixedHeight:)`'s header+padding overhead
    /// (10pt padding × 2, 6pt `VStack` spacing, one `.headline` line) —
    /// not yet measured against a real render. Update this once a
    /// screenshot shows exactly how much of `tileHeight` the header
    /// actually consumes.
    private static let tileHeaderOverhead: CGFloat = 45

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
    /// Used to gate on a row-count threshold below which a box sized for
    /// the worst case would leave visible blank space under 1-2 rows —
    /// removed once every section that boxes at all became window-only
    /// (see `SectionLayout.boxHeight`'s doc comment): the window always
    /// boxes unconditionally, so that threshold check was unreachable at
    /// every real call site and just dead weight to read past.
    // Not `private` — called from every window-only list builder in
    // `ContentView+Window.swift`.
    @ViewBuilder
    func scrollBox(
        _ section: SectionLayout,
        spacing: CGFloat = 2,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if !isCapturingScreenshot, let height = section.boxHeight(on: surface) {
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
                // Omitted entirely rather than showing "—" while unknown —
                // this is a best-effort RDAP lookup (see
                // `ISPIdentityService`), not a check with a settled
                // "nothing found yet" state worth displaying.
                if let name = ispIdentity.organizationName {
                    HStack {
                        Text("ISP")
                            .foregroundStyle(.secondary)
                        Spacer()
                        // Absent for an ISP not in the curated table (e.g.
                        // Astound — checked live, no public status page
                        // exists) — the name still shows, just with no
                        // link icon, which is the correct behavior here.
                        if let url = ispIdentity.statusPageURL {
                            externalLinkIcon(
                                url: url,
                                accessibilityLabel: "\(name) status page",
                                accessibilityHint: "Opens \(name)'s status page in your browser"
                            )
                        }
                        Text(name)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 12))
                }
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
                correlatedWithChange: routerCheck?.correlatedWithChange ?? false,
                // Always shown once the address is known, not gated behind
                // a "does this actually serve a web UI" probe — the
                // simpler answer the punchlist item raising this itself
                // suggested, leaving that probe's self-signed-cert
                // complexity to the separate SNMP Devices web-link item.
                url: info?.routerAddress.map { "http://\($0)" }
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

        // Internet/DNS/HTTP need none of Network/Local Router/Public IP/
        // ISP Edge Router's special-cased `info == nil` branches above:
        // `ConnectivityViewModel.runChecks()`'s own no-interface guard
        // already synthesizes `success: false` entries for exactly these
        // three labels unconditionally (unlike Router/PublicIP/PeRouter,
        // which it only covers conditionally or not at all), so the
        // ordinary check-lookup-and-map below already resolves to
        // `.unhealthy` with no interface, correctly, without a local
        // guard of its own — confirmed by reading that guard rather than
        // assumed, before relying on it here.
        let internetLayer = standardLayer(id: "internet", label: OverallStatus.internetLabel)
        let dnsLayer = standardLayer(id: "dns", label: OverallStatus.dnsLabel)
        let httpLayer = standardLayer(id: "http", label: OverallStatus.httpLabel)

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
                    if let url = layer.url {
                        externalLinkIcon(
                            url: url,
                            accessibilityLabel: "\(layer.label) admin page",
                            accessibilityHint: "Opens \(layer.label)'s web interface in your browser"
                        )
                    }
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

    /// Builds a `ConnectionLayer` straight from `connectivity.checks`, no
    /// special-casing beyond "absent means not checked yet." Only fits
    /// layers with no extra states of their own to represent — see
    /// `connectionLayersLowToHigh`'s Internet/DNS/HTTP call sites for why
    /// those three specifically can use this and Network/Local Router/
    /// Public IP/ISP Edge Router can't.
    private func standardLayer(id: String, label: String) -> ConnectionLayer {
        let check = connectivity.checks.first { $0.label == label }
        return ConnectionLayer(
            id: id,
            label: label,
            detail: check.map(checkDetail) ?? "Not checked",
            status: check.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: check?.correlatedWithChange ?? false
        )
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
                    captureSafeTextField("What are you seeing?", text: $bugReportDraft) {
                        submitBugReport()
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
        screenshot.captureBugReport(
            capturingScreenshotCopy,
            comment: bugReportDraft,
            buildInfo: buildInfo,
            severityDescription: severityDescription
        )
        bugReportDraft = ""
        isReportingBug = false
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
    /// three footer buttons (Expert Mode, Networks…, Preferences…).
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

    // Not `private` — called from `ContentView+Window.swift`'s
    // `wifiSection`.
    func row(_ label: String, _ value: String) -> some View {
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

    /// Small "open in browser" icon button — first used by the SaaS
    /// monitoring section (this app's first-ever use of `Link`, confirmed
    /// safe under `ImageRenderer` capture); extracted here once Network
    /// Health's Local Router row and Info's ISP row needed the identical
    /// shape too, rather than a third near-copy of the same eight lines.
    /// Not `private`, matching `row(_:_:)`'s own cross-file convention.
    @ViewBuilder
    func externalLinkIcon(url: String, accessibilityLabel: String, accessibilityHint: String) -> some View {
        if let url = URL(string: url) {
            Link(destination: url) {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
        }
    }

    /// A `TextField` that swaps to a plain `Text` during a capture — see
    /// `ScreenshotService`'s quirk 4: any `NSViewRepresentable`, a plain
    /// `TextField` included even with `.textFieldStyle(.plain)`, renders
    /// off-screen as a solid yellow bar with a red "prohibited" glyph
    /// instead of its real content.
    ///
    /// Centralized here, mirroring how `scrollBox`/`tile(fixedHeight:)`
    /// already centralize the equivalent guard for `NoBounceScrollView`,
    /// after this exact branch was hand-rolled independently at two call
    /// sites (`bugReportRow`, `communityRow`) and simply missing at a
    /// third — the same "the capture branch is easy to forget, and
    /// forgetting it fails silently" bug class, just for `TextField`
    /// instead of a scroll container. Using this instead of a raw
    /// `TextField` anywhere in this capture path makes forgetting the
    /// guard structurally harder, not just documented.
    ///
    /// `placeholder` doubles as the `TextField`'s prompt and the
    /// capture-mode `Text`'s empty-state copy — both existing call sites
    /// already used the same string for each, so this doesn't change
    /// behavior, only removes the duplicated branch.
    // Not `private` — called from `ContentView+Window.swift`'s
    // `communityRow`.
    @ViewBuilder
    func captureSafeTextField(_ placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        if isCapturingScreenshot {
            Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue)
                .font(.system(size: 11))
                .foregroundStyle(text.wrappedValue.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit(onSubmit)
        }
    }
}
