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
    @ObservedObject var wifiStressTest: WiFiStressTestViewModel
    @ObservedObject var wifiSSID: WiFiSSIDViewModel
    @ObservedObject var ethernetLink: EthernetLinkViewModel
    @ObservedObject var eventLog: EventLogViewModel
    @ObservedObject var traceroute: TracerouteViewModel
    @ObservedObject var snmp: SNMPViewModel
    @ObservedObject var saasMonitoring: SaaSMonitoringViewModel
    @ObservedObject var ddns: DDNSViewModel
    /// Not `@ObservedObject` — a plain value computed once at launch (see
    /// `NMSApp`), not something that changes while the popover is open.
    let buildInfo: BuildInfoService.Info?
    /// The store's location, not its size — unlike `buildInfo`, disk size
    /// genuinely changes during a run, so it's read fresh from
    /// `storeSizeText` on every render rather than cached here.
    let storeURL: URL

    /// Lets "Networks…"/"Preferences…" bring up their own `Window` scenes
    /// (see `NMSApp`).
    @Environment(\.openWindow) private var openWindow

    // Not `private` — `communityRow`/`commitCommunity` live in
    // ContentView+Window.swift, and Swift's `private` doesn't cross files
    // even between extensions of the same type.
    @State var communityDraft: String = ""
    @State var isEditingCommunity = false
    /// Backs the Apple networkQuality tile's "View Full Report" button —
    /// see `appleNetworkQualityTileContent` in `ContentView+Window.swift`.
    /// Not `private`, same cross-file reason as `communityDraft` above.
    @State var isShowingAppleVerboseOutput = false
    /// Backs the Local Stress Test tile's one-time confirmation alert —
    /// see `wifiStressTestSection`/the tile in `ContentView+Window.swift`.
    /// Not `private`, same cross-file reason as `communityDraft` above.
    @State var isShowingWiFiStressTestConfirmation = false
    /// Keyed by `ConnectionLayer.id`. Populated by the Network Health
    /// section's `.task`; empty until then, which simply renders no
    /// sparklines rather than empty boxes.
    @State private var latencyHistory: [String: [LatencySample]] = [:]

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
                    // indicator is back. The window's own `.frame(width:)`
                    // grows by the same total amount so tile content
                    // itself doesn't get any narrower.
                    .padding(.horizontal, 32)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footerBar
                .padding(12)
        }
        .frame(width: 600)
    }

    @ViewBuilder
    private var scrollableContent: some View {
            // Network Health, Info, Path to Internet, and Speed Test are
            // all fixed to `ContentView.tileHeight` (see that constant's
            // doc comment for the three earlier, more intricate alignment
            // mechanisms this replaced — a dynamically-synced `Grid` row
            // for one pair, deliberately independent sizing for the
            // other). Every tile now sizes the same simple way.
            VStack(spacing: 12) {
                tile(title: "Network Health", fixedHeight: Self.tileHeight) {
                    connectionHealthSection
                }
                tile(title: "Info", fixedHeight: Self.tileHeight) {
                    infoSection
                }
                // Path to Internet + Speed Test — see
                // `ContentView+Window.swift`'s `pathAndSpeedRow`.
                pathAndSpeedRow
            }

            // Hidden outright on Ethernet — nothing here has a Wi-Fi
            // answer. Placed above Events (moved up on request) rather
            // than at the bottom with the other full-width sections,
            // since it's read-at-a-glance current state, not scrollable
            // history like they are.
            if wifiSSID.currentSSID != nil {
                Divider()

                Text("Wi-Fi")
                    .font(.headline)

                wifiSection
            }

            // Ethernet's counterpart to the Wi-Fi section just above —
            // mutually exclusive with it by construction (a Mac's default
            // route is either Wi-Fi or Ethernet, never both).
            // `ethernetLink.currentSpeedMbps != nil` answers "is there
            // actually a negotiated link to report" (mirrors
            // `wifiSSID.currentSSID != nil` above — nothing to show while
            // the cable's unplugged either).
            if ethernetLink.currentSpeedMbps != nil {
                Divider()

                Text("Ethernet")
                    .font(.headline)

                ethernetLinkSection
            }

            // `FeatureFlags.saasMonitoring` is a consent question (this
            // reaches out to third-party services, not just this Mac's
            // own LAN). Placed near Wi-Fi, not with the other full-width
            // sections below — same reasoning: read-at-a-glance current
            // state, not scrollable history.
            if FeatureFlags.saasMonitoring {
                Divider()

                Text("SaaS Status")
                    .font(.headline)

                saasMonitoringSection
            }

            Divider()

            Text("Events")
                .font(.headline)

            eventList

            // `FeatureFlags.snmpDevices` is a consent question (this is
            // active network probing against whatever LAN the Mac is on,
            // not just a UI section — see that flag's doc comment).
            if FeatureFlags.snmpDevices {
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
                    .accessibilityIdentifier("snmpDevices.scan")
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

            Divider()

            Text("DHCP History")
                .font(.headline)

            dhcpHistoryList
    }

    /// Refresh/Networks…/Preferences…/Quit, the build-hash/store-size
    /// line, and the DEBUG-overrides banner.
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
                Button("Networks…") {
                    openWindowInFront("known-networks")
                }
                .accessibilityLabel("Known Networks")
                .accessibilityHint("Opens a list of every network this Mac has connected to, with a way to forget one")
                .accessibilityIdentifier("footer.networks")
                Button("Preferences…") {
                    openWindowInFront("preferences")
                }
                .accessibilityLabel("Preferences")
                .accessibilityHint("Opens toggles for experimental features")
                .accessibilityIdentifier("footer.preferences")
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .accessibilityLabel("Quit")
                .accessibilityHint("Quits NMS")
                .accessibilityIdentifier("footer.quit")
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
    /// — see `connectionHealthSection`'s own doc comment. While that was
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

    /// A bordered box with a header row (title, plus an optional trailing
    /// accessory like "Trace Now") — the visual unit tiles in the grid
    /// above are built from. A plain `Divider()` no longer reads as a
    /// separator once two tiles sit side by side rather than stacked full
    /// width, so each tile draws its own border instead.
    // Not `private` — called from `ContentView+Window.swift`'s
    // `pathAndSpeedRow`, and Swift's `private` doesn't cross files even
    // between extensions of the same type.
    @ViewBuilder
    func tile(title: String, fixedHeight: CGFloat? = nil, scrolls: Bool = true, @ViewBuilder content: () -> some View) -> some View {
        tile(title: title, fixedHeight: fixedHeight, scrolls: scrolls, trailing: { EmptyView() }, content: content)
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
    /// invisible. The outer `.frame(maxHeight: fixedHeight)` only *caps*
    /// height — it doesn't force a smaller natural size to grow to fill
    /// it, so a `maxHeight` alone left the tile at whatever tiny size its
    /// (empty-looking) content produced.
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
    @ViewBuilder
    func tile(
        title: String,
        fixedHeight: CGFloat? = nil,
        scrolls: Bool = true,
        @ViewBuilder trailing: () -> some View,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let effectiveHeight = fixedHeight
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                trailing()
            }
            // `scrolls: false` — raised directly, for tiles whose content
            // is genuinely bounded (a small, fixed row count defined in
            // code, not user data that can grow without limit) rather
            // than needing a scroll safety net the way Speed Test's
            // growing run history or Events' unbounded log do. Traded
            // deliberately: if this tile's content ever does grow past
            // `effectiveHeight`, there's no scroll fallback to catch it
            // — accepted, since the row count here is capped by a fixed,
            // known list, not something a user can expand.
            if let effectiveHeight, scrolls {
                ScrollView {
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
                VStack(alignment: .leading, spacing: 2) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    /// gets built — Events, SNMP Devices, DHCP History, Wi-Fi, Ethernet,
    /// and SaaS Status all route through here.
    // Not `private` — called from every list builder in
    // `ContentView+Window.swift`.
    @ViewBuilder
    func scrollBox(
        _ section: SectionLayout,
        spacing: CGFloat = 2,
        @ViewBuilder content: () -> some View
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: section.boxHeight)
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

        // Confirms the polling is actually active and shows its current
        // state — absent entirely until a hostname is configured (see
        // `ddnsRow`).
        ddnsRow
    }

    /// One summary row for however many hostnames are configured — not
    /// one row per hostname, to keep this from growing the tile
    /// unboundedly the way `FeatureFlags.UserAddedSaaSSite` deliberately
    /// stays out of the curated SaaS table for the same reason. Per-
    /// hostname detail lives in the tooltip and, for a genuine
    /// transition, the Events list.
    @ViewBuilder
    private var ddnsRow: some View {
        if !ddns.statuses.isEmpty {
            HStack {
                Text("DDNS")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    ddns.checkAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(ddns.isChecking)
                .accessibilityLabel("Check DDNS hostnames now")
                .accessibilityIdentifier("info.ddns.checkNow")
                .help("Resolves every configured DDNS hostname now, rather than waiting for the next scheduled check.")
                Circle()
                    .fill(ddnsSummaryColor)
                    .frame(width: 8, height: 8)
                Text(ddnsSummaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
            .help(ddnsTooltipText)
        }
    }

    /// Worst state wins — a single red dot for one stale hostname among
    /// several shouldn't be averaged away by the others being fine.
    /// `.blockedByCGNAT` renders distinctly from both: not a failure
    /// (green would be dishonest) and not "something broke" (red would
    /// overstate it) — a structural fact about this connection, same
    /// `.orange` tier the "possibly related to a recent network change"
    /// annotation already uses for "worth noting, not a failure."
    private var ddnsSummaryColor: Color {
        let states = ddns.statuses.compactMap(\.syncState)
        if states.contains(.stale) { return .red }
        if states.contains(.blockedByCGNAT) { return .orange }
        if states.count == ddns.statuses.count, states.allSatisfy({ $0 == .current }) { return .green }
        return .secondary
    }

    private var ddnsSummaryText: String {
        let name = ddns.statuses.count == 1 ? ddns.statuses[0].hostname : "\(ddns.statuses.count) hostnames"
        let minutes = Int(FeatureFlags.ddnsCheckInterval / 60)
        return "\(name) · every \(minutes)m"
    }

    private var ddnsTooltipText: String {
        ddns.statuses.map { status in
            let state: String
            switch status.syncState {
            case .current: state = "in sync"
            case .stale: state = "stale — check your DDNS client"
            case .blockedByCGNAT: state = "blocked by CGNAT"
            case nil: state = status.lastError ?? "checking…"
            }
            return "\(status.hostname): \(state)"
        }.joined(separator: "\n")
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
            // On Wi-Fi this row shows a signal-strength sparkline instead
            // of the network's name (see `connectionHealthSection`'s own
            // per-row rendering) — the name still reads correctly from
            // the Info tile's own row, which reuses `networkDisplay(_:)`
            // unchanged. Requested directly: "Name" + "Ethernet" (via
            // `networkDisplay`, unchanged) or a sparkline + "Wi-Fi"
            // (here), not "Name" + "Wi-Fi" as before.
            let detail = info.isWiFi ? "Wi-Fi" : networkDisplay(info)
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

    /// **`Grid` clipping, found and fixed, worth remembering why.** `Grid`
    /// once correctly aligned every row's icons but rendered every label
    /// with its first character clipped, when this tile's content lived
    /// inside `NoBounceScrollView` — a custom `NSHostingView`/`NSScrollView`
    /// bridge with a documented history of not perfectly tracking
    /// SwiftUI's intrinsic sizing for certain content. Root-caused to that
    /// AppKit bridge specifically, not `Grid` itself: dropping down to a
    /// plain SwiftUI `ScrollView` (see `NoBounceScrollView`'s removal)
    /// made the bug stop reproducing entirely, confirmed live — no
    /// special-casing needed here anymore.
    @ViewBuilder
    private var connectionHealthSection: some View {
        let layers = connectionLayersLowToHigh
        VStack(alignment: .leading, spacing: 2) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                ForEach(layers.reversed()) { layer in
                    GridRow {
                        Circle()
                            .fill(layerColor(for: layer))
                            .frame(width: 8, height: 8)
                        Text(layer.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .gridColumnAlignment(.leading)
                        // Network's own sparkline (Wi-Fi only — Ethernet
                        // has no signal strength to chart) uses RSSI
                        // history from `wifiSSID.recentSamples`, not
                        // `latencyHistory`: this row isn't a ping-latency
                        // check, so `latencyHistory` has no entry for it
                        // at all. Same values/reversal `wifiSection`'s
                        // own Signal row already uses for the identical
                        // chart.
                        if let url = layer.url {
                            externalLinkIcon(
                                url: url,
                                accessibilityLabel: "\(layer.label) admin page",
                                accessibilityHint: "Opens \(layer.label)'s web interface in your browser"
                            )
                        } else {
                            // Not `EmptyView()` — confirmed by direct
                            // testing that a literal `EmptyView()` cell
                            // doesn't reliably reserve its `Grid` column,
                            // so rows with an empty icon/sparkline
                            // silently collapsed a column relative to
                            // rows with real content there (Router's icon
                            // pushed its sparkline right of every ping
                            // row's). `Color.clear` measures as a real
                            // zero-color view and keeps every row's cell
                            // count *and* column position honest.
                            Color.clear.frame(width: 0, height: 0)
                        }
                        if layer.id == "network", viewModel.currentInterface?.isWiFi == true,
                           wifiSSID.recentSamples.count > 1 {
                            Sparkline(values: wifiSSID.recentSamples.reversed().map { $0.rssi.map(Double.init) })
                        } else if let samples = latencyHistory[layer.id] {
                            Sparkline(values: samples.map(\.latencyMs))
                        } else {
                            Color.clear.frame(width: 0, height: 0)
                        }
                        // `minWidth` protects this column specifically —
                        // confirmed necessary again on the second `Grid`
                        // attempt: sharing one column width across every
                        // row means a long label ("ISP Edge Router")
                        // squeezes this column on every row, not just its
                        // own. A value truncated in the middle
                        // ("Hom...hernet") is unreadable garble; a label
                        // truncated at the tail ("ISP Edge…") still
                        // starts with its most identifying word — so this
                        // column gets the guaranteed room, and the label
                        // column absorbs whatever compression is left.
                        // 85pt comfortably fits the longest real value
                        // seen here ("Home Ethernet"). `maxWidth: .infinity`
                        // marks this column flexible so `Grid` gives it the
                        // tile's leftover width instead of shrink-wrapping
                        // the whole grid to its narrowest fit — without it,
                        // a wide Expert Mode window left the grid (and this
                        // "trailing"-aligned column) bunched at the tile's
                        // left edge instead of flush against its real right
                        // edge. Confirmed via user screenshot: looked fine
                        // in the narrower popover, misaligned only in the
                        // window.
                        Text(layer.detail + (layer.status == .unhealthy && layer.correlatedWithChange ? " *" : ""))
                            .foregroundStyle(layer.status == .unhealthy ? layerColor(for: layer) : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 85, maxWidth: .infinity, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
                    }
                }

                // A fast, on-demand responsiveness check, useful before a
                // video call. Living inside Network Health's own tile
                // rather than as a new one: no extra height budget spent.
                // The full Apple networkQuality tile still exists
                // separately for the complete test/history.
                quickCheckGridRow
            }
            .font(.system(size: 12))

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

    /// Same five-cell shape every `GridRow` in `connectionHealthSection`
    /// uses (dot, label, icon, sparkline, value) — an icon button styled
    /// identically to `externalLinkIcon`, in the same column position, so
    /// it aligns with the Router row's link icon by construction. No
    /// sparkline for this row (`EmptyView`), same "always emit every
    /// cell" rule `Grid` needs. The dot stays gray until a result exists
    /// — never claims a verdict it hasn't earned.
    private var quickCheckGridRow: some View {
        GridRow {
            Circle()
                .fill(quickCheckColor)
                .frame(width: 8, height: 8)
                // Same tooltip the Expert Mode tile's own RPM figures use
                // (`ContentView+Window.rpmThresholdHelp`) — raised
                // directly, so the two surfaces' colored verdicts explain
                // themselves the same way.
                .help(Self.rpmThresholdHelp)
            // "networkQuality" — matches the Expert Mode tile's own name
            // for the full test this is a quick preview of, reported
            // directly as clearer than "Call Check". Length is close to
            // the original "Video Call Check" that was shortened for
            // truncation reasons (see `quickCheckDetailText`'s trailing
            // column) — re-verify visually after this rename.
            Text("networkQuality")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
            Button {
                networkQuality.runQuickCheck(interfaceName: viewModel.currentInterface?.interfaceName)
            } label: {
                Image(systemName: "play.circle")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(networkQuality.isRunningQuickCheck || networkQuality.isRunning)
            .accessibilityLabel("Video Call Check")
            .accessibilityHint("Runs a quick, about 5 second check of your connection's responsiveness under load, useful before a video call. Uses your data plan.")
            .accessibilityIdentifier("networkHealth.quickCheck")
            .help("Runs a quick, about 5 second check of your connection's responsiveness under load, useful before a video call. Uses your data plan.")
            Color.clear.frame(width: 0, height: 0)
            Text(quickCheckDetailText)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .gridColumnAlignment(.trailing)
        }
    }

    private var quickCheckColor: Color {
        guard let status = networkQuality.quickCheckStatus else { return .gray }
        return Self.statusColor(forRPM: status.rpm)
    }

    /// The single green/yellow/red mapping both the quick check row and
    /// the "Apple networkQuality" tile's history rows use — raised
    /// directly, so a given RPM number reads the same color in either
    /// place rather than each inventing its own cutoffs.
    /// Not `private`: called from `ContentView+Window.swift`'s
    /// `appleQualityRows`, and Swift's `private` doesn't cross files even
    /// between extensions of the same type. Thresholds match
    /// `QuickCheckStatus`'s own (the shared source of truth for "what
    /// counts as good") rather than duplicating the numbers here.
    static func statusColor(forRPM rpm: Int) -> Color {
        switch QuickCheckStatus(rpm: rpm) {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .red
        }
    }

    private var quickCheckDetailText: String {
        if networkQuality.isRunningQuickCheck { return "Checking…" }
        if let error = networkQuality.quickCheckError { return error }
        // Shorter than "\(status.label) — \(status.rpm) RPM" (tried
        // first) — that version truncated in the middle of the RPM
        // number once the label above was long enough to squeeze it.
        if let status = networkQuality.quickCheckStatus { return "\(status.label) (\(status.rpm))" }
        return "Tap to check"
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

    /// Network name (if any) plus connection type combined into one row
    /// (e.g. "<network name> Wi-Fi", "<network name> Ethernet", or just
    /// "Ethernet" with no known name yet) instead of separate "Network"/
    /// "Interface" and "Type" rows, to save vertical space in the Info
    /// section. The raw interface hardware name (e.g. "USB 10/100/1000
    /// LAN") is dropped entirely here in favor of just the connection
    /// type, since it added little once a name or type is already shown.
    ///
    /// On Wi-Fi, the live SSID wins over a user-assigned `KnownNetwork`
    /// label — reported directly: `KnownNetwork` is keyed by router MAC
    /// + subnet, not SSID (see that type's own doc comment), so the same
    /// physical LAN reached over Ethernet and Wi-Fi shares one label. A
    /// label set from the Ethernet side was silently overriding the
    /// genuinely different, accurate live Wi-Fi SSID instead of just
    /// supplementing it. Off Wi-Fi there's no live-SSID equivalent, so
    /// the label is still the best available name there.
    private func networkDisplay(_ info: NetworkInterfaceInfo) -> String {
        let type = info.isWiFi ? "Wi-Fi" : "Ethernet"
        let label = networkIdentity.currentNetwork?.label
        let name: String? = info.isWiFi
            ? (wifiSSID.currentSSID ?? (label?.isEmpty == false ? label : nil))
            : (label?.isEmpty == false ? label : nil)
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
            // Same string as the VoiceOver hint above, shown as a real
            // hover tooltip too.
            .help(accessibilityHint)
        }
    }

}
