import SwiftUI
import AppKit
import SwiftData

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory = menu bar only, no Dock icon, no app switcher entry.
        // This is the standard pattern for background utility apps.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The `MenuBarExtra` label, plus a DEBUG-only side effect: auto-opening
/// the "nms-window" `Window` scene once at launch.
///
/// This exists so a script (or an AI assistant driving a session, same
/// audience `FailureInjector`'s doc comments call out) can verify the app
/// visually with just `screencapture` against a real `NSWindow` — no
/// Accessibility permission, no clicking through the menu bar popover
/// first. See the punch-list item this closes ("a debug key to auto-open
/// the real window at launch").
///
/// **Why this lives here, not in `NMSApp.init()` or `AppDelegate`:**
/// `openWindow(id:)` is a SwiftUI `@Environment` action, only available
/// inside a real `View` — `NMSApp` is a `struct: App`, not a `View`, and
/// `AppDelegate` is plain `AppKit`, neither has access to it. The
/// `MenuBarExtra`'s popover content (`ContentView`) *is* a `View` with
/// that access already (see its own `openWindow`/`openWindowInFront`),
/// but its `.task`/`.onAppear` only fire once actually shown — clicked
/// open by a user or a script, not at launch. The one place in this
/// scene graph guaranteed to render immediately, regardless of whether
/// anything is ever clicked, is the `MenuBarExtra`'s `label` — it's
/// what makes the menu bar icon itself show up, confirmed empirically:
/// the icon and its live color are visible the instant the app launches.
/// Wrapping the label in its own tiny `View` gets a real `openWindow`
/// binding attached to something with that guarantee.
///
/// **`for now`, unconditional in DEBUG rather than gated behind its own
/// defaults key** — this is a temporary dev/verification convenience,
/// not a real behavior change for the shipped app, so it follows the
/// same `#if DEBUG` discipline as `FailureInjector`/`StoreInspector`
/// rather than adding a new toggle. A release build can't produce this
/// side effect at all.
///
/// `didAutoOpen` guards against re-triggering on every re-render — the
/// label closure re-evaluates whenever `overallStatus.color` changes,
/// and while `.task` on a stable view identity shouldn't restart on its
/// own, the guard costs nothing and removes any doubt.
private struct MenuBarLabel: View {
    let symbolName: String
    let color: Color
    #if DEBUG
    @Environment(\.openWindow) private var openWindow
    @State private var didAutoOpen = false
    #endif

    var body: some View {
        let image = Image(nsImage: NMSApp.statusIcon(symbolName: symbolName, color: color))
        #if DEBUG
        image.task {
            guard !didAutoOpen else { return }
            didAutoOpen = true
            openWindow(id: "nms-window")
            // Same activation/ordering `openWindowInFront` needed on the
            // MacBook (see `ContentView.openWindowInFront`'s fix,
            // `NSApp.activate()` with no arguments) — found by testing
            // this exact path right after that fix landed: a script or
            // screenshot right after launch would otherwise see the
            // window exist but sit behind other apps, the same failure
            // mode, just reached through `openWindow(id:)` directly
            // instead of a footer button. Deferred one run loop turn for
            // the same reason `openWindowInFront` is: the window may not
            // exist yet the instant `openWindow` returns.
            DispatchQueue.main.async {
                NSApp.activate()
                let match = NSApp.windows.first { $0.identifier?.rawValue.contains("nms-window") == true }
                match?.makeKeyAndOrderFront(nil)
                UIStateLogger.log(
                    "MenuBarLabel.autoOpenWindow",
                    "nms-window → \(match?.identifier?.rawValue ?? "NO WINDOW MATCHED")"
                )
            }
        }
        #else
        image
        #endif
    }
}

@main
struct NMSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var networkMonitor: NetworkMonitorViewModel
    @StateObject private var lanDiscovery: LANDiscoveryViewModel
    @StateObject private var connectivity: ConnectivityViewModel
    @StateObject private var networkIdentity: NetworkIdentityViewModel
    @StateObject private var publicIP: PublicIPViewModel
    @StateObject private var dhcpLease: DHCPLeaseViewModel
    @StateObject private var networkQuality: NetworkQualityViewModel
    @StateObject private var screenshot: ScreenshotViewModel
    @StateObject private var wifiSSID: WiFiSSIDViewModel
    @StateObject private var eventLog: EventLogViewModel
    @StateObject private var traceroute: TracerouteViewModel
    @StateObject private var snmp: SNMPViewModel

    // SwiftData requires the container to be kept alive for as long as
    // anything derived from it (like `mainContext`) is in use. Without this
    // property the container was a throwaway local in `init()` — it got
    // deallocated as soon as `init()` returned, leaving `mainContext`
    // pointing at a dead container and crashing on the first later fetch.
    private let modelContainer: ModelContainer
    /// Computed once at launch, not a `@Published`/computed-in-`body`
    /// property — `body` re-evaluates on every network change, and this
    /// shells out to `git`, so it belongs alongside `modelContainer` as a
    /// plain constant rather than being recomputed on every re-render.
    private let buildInfo: BuildInfoService.Info?
    /// The store's resolved location, captured once so `ContentView` can
    /// read its on-disk size fresh on every render (unlike `buildInfo`,
    /// file *size* genuinely changes during a run, so only the path is
    /// cached here — not a size snapshot that would go stale). Reusing
    /// `makeModelContainer()`'s own resolution rather than calling
    /// `storeURL()` a second time, which would log a duplicate `App.store`
    /// line at every launch.
    private let storeURL: URL
    /// Kept alongside the view models it backs rather than left as an
    /// `init()`-local, since `KnownNetworksView`'s Review sheet needs it
    /// directly (via explicit-fingerprint fetches) rather than through a
    /// specific view model — see `NetworkReviewViewModel`.
    private let snapshotStore: SnapshotStore

    init() {
        let (container, resolvedStoreURL) = Self.makeModelContainer()
        modelContainer = container
        storeURL = resolvedStoreURL
        let buildInfo = BuildInfoService.current()
        self.buildInfo = buildInfo
        UIStateLogger.log(
            "App.build",
            buildInfo.map { "\($0.shortHash)\($0.isDirty ? "+dirty" : "") — \($0.subject)" } ?? "unknown"
        )
        // Catches the override left set across a relaunch — the one case
        // `ConnectivityViewModel`'s own on-change log can't cover, since
        // it only fires from a *transition* and a key already set at
        // launch produces none. See `FailureInjector.activeOverridesSummary`.
        UIStateLogger.log("FailureInjector.activeOverrides", FailureInjector.activeOverridesSummary() ?? "none")
        // Started before any view model, so the beat covers the whole
        // launch sequence — the LAN scan, traceroute and connectivity
        // round kicked off below are exactly the kind of work a wedge
        // would happen during.
        UIStateLogger.startMainThreadHeartbeat()
        let store = SnapshotStore(context: container.mainContext)
        snapshotStore = store
        // Before any view model reads the device list: a store carrying
        // duplicate SNMP rows from the bug fixed in
        // `adoptUntaggedRecords` would otherwise crash the app on the next
        // poll. No-ops on a clean store. See `dedupeSNMPDevices`.
        store.dedupeSNMPDevices()
        let networkMonitor = NetworkMonitorViewModel(snapshotStore: store)
        let lanDiscovery = LANDiscoveryViewModel(snapshotStore: store)
        let networkIdentity = NetworkIdentityViewModel(snapshotStore: store)
        let publicIP = PublicIPViewModel(snapshotStore: store)
        let dhcpLease = DHCPLeaseViewModel(snapshotStore: store, networkMonitor: networkMonitor)
        // No wiring into `wireDependencies` below, and no timer of its
        // own — deliberately never triggered automatically. See
        // `NetworkQualityViewModel`'s own doc comment.
        let networkQuality = NetworkQualityViewModel(snapshotStore: store)
        let screenshot = ScreenshotViewModel(snapshotStore: store)
        let wifiSSID = WiFiSSIDViewModel(snapshotStore: store)
        let eventLog = EventLogViewModel(snapshotStore: store)
        let traceroute = TracerouteViewModel(snapshotStore: store)
        let connectivity = ConnectivityViewModel(
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            traceroute: traceroute,
            publicIP: publicIP,
            snapshotStore: store
        )
        let snmp = SNMPViewModel(
            snapshotStore: store,
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            traceroute: traceroute
        )
        // Two-phase: `SNMPViewModel` needs view models built alongside
        // `connectivity`, so the back-reference is injected once both exist.
        connectivity.attach(snmp: snmp)
        Self.wireDependencies(
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            connectivity: connectivity,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            dhcpLease: dhcpLease,
            screenshot: screenshot,
            wifiSSID: wifiSSID,
            eventLog: eventLog,
            traceroute: traceroute,
            snmp: snmp,
            networkQuality: networkQuality
        )
        _networkMonitor = StateObject(wrappedValue: networkMonitor)
        _lanDiscovery = StateObject(wrappedValue: lanDiscovery)
        _connectivity = StateObject(wrappedValue: connectivity)
        _networkIdentity = StateObject(wrappedValue: networkIdentity)
        _publicIP = StateObject(wrappedValue: publicIP)
        _dhcpLease = StateObject(wrappedValue: dhcpLease)
        _networkQuality = StateObject(wrappedValue: networkQuality)
        _screenshot = StateObject(wrappedValue: screenshot)
        _wifiSSID = StateObject(wrappedValue: wifiSSID)
        _eventLog = StateObject(wrappedValue: eventLog)
        _traceroute = StateObject(wrappedValue: traceroute)
        _snmp = StateObject(wrappedValue: snmp)

        // Recognize whatever network we're already on at launch, rather
        // than waiting for the next topology change to fire a scan.
        lanDiscovery.scan()
        wifiSSID.refresh(isWiFi: networkMonitor.currentInterface?.isWiFi ?? false)
    }

    /// Every cross-view-model connection in the app, split into four
    /// smaller functions below — one per `// MARK:` category this single
    /// function used to hold inline. Only two view models consume other
    /// view models' state — `ConnectivityViewModel` (reads
    /// `networkMonitor`, `traceroute`, `publicIP`, `snmp`) and
    /// `SNMPViewModel` (reads `networkMonitor`, `lanDiscovery`,
    /// `traceroute`) — so the whole dependency matrix is roughly eight
    /// edges and small enough to audit by reading these four functions,
    /// still called from exactly one place (`init()`).
    ///
    /// That matters because of a bug class this app has now hit three
    /// times. Every one of those reads is optional-chained with a silent
    /// fallback (`snmp?.devices ?? []`, `traceroute?.monitoredHop?.address`),
    /// so a dependency that isn't ready yet doesn't error — it quietly
    /// yields an incomplete result that then sits cached until some
    /// *timer* recomputes it. The ISP Edge Router row vanished for 30s
    /// that way, and the SNMP MAC merge for 60s. The fix in both cases
    /// was to make the recompute trigger belong to the dependency rather
    /// than the clock, which is what `wireDerivedStateDependencies` below
    /// does. An edge missing from that function is the shape this bug
    /// takes, so it should be possible to spot one by inspection instead
    /// of by user report.
    ///
    /// **Splitting these out was considered against a message-bus/pub-sub
    /// alternative and rejected in favor of this — see DESIGN-NOTES.md's
    /// "A message bus for cross-view-model events? Considered, rejected."**
    /// The problem being solved here is genuinely just "one function got
    /// long to read," not "these are too coupled" — pub-sub would trade
    /// away the exact property (a missing edge is visible by reading the
    /// wiring) that's caught three real bugs, in exchange for solving a
    /// readability problem four smaller functions already solve without
    /// that cost.
    private static func wireDependencies(
        networkMonitor: NetworkMonitorViewModel,
        lanDiscovery: LANDiscoveryViewModel,
        connectivity: ConnectivityViewModel,
        networkIdentity: NetworkIdentityViewModel,
        publicIP: PublicIPViewModel,
        dhcpLease: DHCPLeaseViewModel,
        screenshot: ScreenshotViewModel,
        wifiSSID: WiFiSSIDViewModel,
        eventLog: EventLogViewModel,
        traceroute: TracerouteViewModel,
        snmp: SNMPViewModel,
        networkQuality: NetworkQualityViewModel
    ) {
        wireTopologyChangeFanOut(
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            connectivity: connectivity,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            dhcpLease: dhcpLease,
            wifiSSID: wifiSSID,
            traceroute: traceroute
        )
        wireDerivedStateDependencies(
            networkMonitor: networkMonitor,
            lanDiscovery: lanDiscovery,
            connectivity: connectivity,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            traceroute: traceroute,
            snmp: snmp
        )
        wireReachabilityTransitions(
            connectivity: connectivity,
            publicIP: publicIP,
            traceroute: traceroute,
            networkQuality: networkQuality
        )
        wireEventLogRefresh(
            networkMonitor: networkMonitor,
            connectivity: connectivity,
            publicIP: publicIP,
            dhcpLease: dhcpLease,
            screenshot: screenshot,
            wifiSSID: wifiSSID,
            eventLog: eventLog,
            snmp: snmp,
            traceroute: traceroute
        )
    }

    /// A change to the Mac's own interface/IP/router invalidates nearly
    /// everything, so it re-runs nearly everything.
    private static func wireTopologyChangeFanOut(
        networkMonitor: NetworkMonitorViewModel,
        lanDiscovery: LANDiscoveryViewModel,
        connectivity: ConnectivityViewModel,
        networkIdentity: NetworkIdentityViewModel,
        publicIP: PublicIPViewModel,
        dhcpLease: DHCPLeaseViewModel,
        wifiSSID: WiFiSSIDViewModel,
        traceroute: TracerouteViewModel
    ) {
        // `[weak networkMonitor]` because this closure is stored *on*
        // `networkMonitor` and also reads it (for `currentInterface`
        // below) — the one self-referential edge in this whole wiring
        // graph, and so the one retain cycle. Every other assignment here
        // captures a different object than the one it's stored on. Doesn't
        // leak today, since these all live for the process lifetime, but
        // it would the moment any of them became per-scene.
        networkMonitor.onChangePersisted = { [weak networkMonitor] snapshot in
            // Clears recognition and the store's current-network
            // fingerprint immediately, before the LAN scan below can
            // re-recognize whatever network this change lands on —
            // without this, anything recorded during that gap (a DHCP
            // lease, an SNMP poll, an event) would be tagged with the
            // *previous* network's fingerprint. See
            // `NetworkIdentityViewModel.reset`.
            networkIdentity.reset()
            lanDiscovery.scan(for: snapshot)
            // A topology change is the most likely moment the public IP
            // actually changed, so check it right away rather than waiting
            // for the next periodic tick.
            publicIP.check()
            // Same for the Wi-Fi SSID — e.g. unplugging Ethernet and
            // falling back to Wi-Fi is exactly this kind of change.
            wifiSSID.refresh(isWiFi: networkMonitor?.currentInterface?.isWiFi ?? false)
            // A topology change (new network, interface failover) is
            // exactly the moment a DHCP lease is likely to have changed
            // too, rather than waiting up to 5 minutes for the next poll.
            dhcpLease.check()
            // A new network means a genuinely different set of reachable
            // printers (CUPS' own configured list doesn't change, but
            // which of them are actually on this LAN does) — re-read
            // rather than waiting for the next launch to notice.
            connectivity.refreshConfiguredPrinters()
            // The path to the internet (and the ISP edge router) can change
            // along with the topology change itself, so re-trace now rather
            // than waiting up to 10 minutes for the next periodic run.
            traceroute.run()
            // Router/internet/DNS/HTTP reachability is exactly what just
            // changed too (e.g. an interface coming back up, or a failover
            // to a different one) — re-check now instead of leaving Network
            // Health showing stale router/internet/DNS/HTTP status for up
            // to 30s until the next periodic round.
            connectivity.runChecks()
        }
    }

    /// The edges that exist specifically so a consumer re-derives when its
    /// dependency resolves, instead of waiting for a timer. Each one here
    /// corresponds to a real bug that shipped without it.
    private static func wireDerivedStateDependencies(
        networkMonitor: NetworkMonitorViewModel,
        lanDiscovery: LANDiscoveryViewModel,
        connectivity: ConnectivityViewModel,
        networkIdentity: NetworkIdentityViewModel,
        publicIP: PublicIPViewModel,
        traceroute: TracerouteViewModel,
        snmp: SNMPViewModel
    ) {
        // `ConnectivityViewModel.buildTargets` reads
        // `traceroute.monitoredHop` to decide whether to include the ISP Edge
        // Router target. `traceroute.run()` is async, so the first check round
        // at launch runs before any hop exists and silently omits the row —
        // invisible for up to 30s. Also covers every later trace, so a changed
        // edge-router address is picked up at once.
        traceroute.onTraceCompleted = { connectivity.runChecks() }

        // `SNMPViewModel.rebuildDeviceList` reads `lanDiscovery.devices` for
        // the MACs behind its merge (one device answering at several
        // addresses). `lanDiscovery.scan()` is async — it had to be, to stop
        // `arp` blocking the main thread — so `SNMPViewModel.init()` rebuilds
        // before any MAC exists and the merge didn't land for 60s.
        // `networkIdentity` shares this edge: recognizing a network needs the
        // router's MAC, which only a LAN scan can supply.
        lanDiscovery.onScanCompleted = { devices in
            networkIdentity.recognize(
                routerAddress: networkMonitor.currentInterface?.routerAddress,
                subnetMask: networkMonitor.currentInterface?.subnetMask,
                from: devices
            )
            snmp.rebuildDeviceList()
        }

        // The retry half of the fix in `NetworkIdentityViewModel.recognize`
        // for `BUGS.md`'s "Known Networks silently never adds an
        // unfamiliar network": a scan that ran too early for the OS to
        // have ARP-resolved the router yet used to leave that network
        // unrecognized for the rest of the session, with nothing to
        // retrigger recognition. 3s is long enough for the OS to catch up
        // (this exact race, after a Wi-Fi reconnect, is what
        // `SNMPViewModel.refreshARPIfMergeDataIsStale`'s own doc comment
        // already describes) without meaningfully delaying a legitimately
        // new network's first recognition. Capped at one retry by
        // `NetworkIdentityViewModel.hasRequestedRetry`, not here.
        networkIdentity.onRecognitionPending = { [weak lanDiscovery] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                lanDiscovery?.scan()
            }
        }

        // `ConnectivityViewModel.buildTargets` pings the SNMP device list as
        // its infrastructure targets, reading it as `snmp?.devices ?? []`.
        // `connectivity` is constructed *before* `snmp` (the back-reference is
        // injected afterward by `attach(snmp:)`), so the first check round at
        // launch runs with `snmp` still nil and monitors no infrastructure at
        // all. Until this edge existed it recovered only because
        // `onTraceCompleted` above rebuilt the target list ~500ms later and
        // happened to pick up SNMP too — a neighbour masking a missing edge,
        // which is exactly what this grouping is meant to make visible.
        // Found by the "unavailable: snmpDevices" line in the state log.
        snmp.onDeviceListChanged = { connectivity.runChecks() }

        // `ConnectivityViewModel.buildTargets` also reads `publicIP.currentIP`
        // for the Public IP ping target, and `check()` is an async network
        // fetch — same shape as the two edges above. Observed directly: the
        // target was absent for the first two rounds at launch, appearing
        // only 30 seconds in in via the periodic timer rather than anything
        // noticing the fetch had resolved. This closes the last of
        // `ConnectivityViewModel`'s four dependencies.
        publicIP.onCurrentIPChanged = { connectivity.runChecks() }
    }

    /// An upstream failure (e.g. a switch between the local router and the
    /// ISP) doesn't touch the Mac's own interface/IP/router, so
    /// `onChangePersisted` never fires for it — the raw IP check failing is
    /// the earliest signal something broke upstream.
    private static func wireReachabilityTransitions(
        connectivity: ConnectivityViewModel,
        publicIP: PublicIPViewModel,
        traceroute: TracerouteViewModel,
        networkQuality: NetworkQualityViewModel
    ) {
        connectivity.onInternetUnreachable = { traceroute.run() }
        // The recovery counterpart. The trace fired above runs while the path
        // is still down, so it fails and clears the monitored hop, removing
        // the ISP Edge Router target entirely — leaving an outage with no
        // matching recovery until the next periodic trace up to 10 minutes
        // later. Re-tracing on recovery restores the hop and the check.
        connectivity.onInternetReachable = {
            traceroute.run()
            // Same stale-after-recovery problem, different symptom: a public
            // IP fetch that fails mid-transition leaves `lastError` set, and
            // the popover renders it verbatim — so URLError's "The Internet
            // connection appears to be offline." sat under Info while every
            // Network Health row was green, until the next 5-minute tick.
            publicIP.check()
            // Same bug, third symptom: Speed Test's own `lastError` is just
            // as sticky, and reported directly — Ethernet reconnecting
            // still showed "offline" until a manual re-run. Cleared, not
            // re-fetched: a real Speed Test transfer must never happen
            // without the user asking for it.
            networkQuality.clearStaleErrorOnRecovery()
        }
    }

    /// Every producer that can write an `AppEventRecord` tells the log view
    /// to re-read.
    private static func wireEventLogRefresh(
        networkMonitor: NetworkMonitorViewModel,
        connectivity: ConnectivityViewModel,
        publicIP: PublicIPViewModel,
        dhcpLease: DHCPLeaseViewModel,
        screenshot: ScreenshotViewModel,
        wifiSSID: WiFiSSIDViewModel,
        eventLog: EventLogViewModel,
        snmp: SNMPViewModel,
        traceroute: TracerouteViewModel
    ) {
        networkMonitor.onEventLogged = { eventLog.refresh() }
        connectivity.onEventLogged = { eventLog.refresh() }
        publicIP.onEventLogged = { eventLog.refresh() }
        dhcpLease.onEventLogged = { eventLog.refresh() }
        screenshot.onEventLogged = { eventLog.refresh() }
        wifiSSID.onEventLogged = { eventLog.refresh() }
        snmp.onEventLogged = { eventLog.refresh() }
        traceroute.onEventLogged = { eventLog.refresh() }
    }

    /// The at-a-glance severity: interface down and router/internet/DNS/HTTP
    /// failures are critical (red); a monitored LAN device being down is
    /// marginal (yellow); anything else is normal (green).
    private var overallStatus: OverallStatus {
        OverallStatus.compute(interfaceIsDown: networkMonitor.currentInterface == nil, checks: connectivity.checks)
    }

    /// Built once here rather than duplicated at each of the two call
    /// sites below — the popover and the comparison window show the exact
    /// same live view models, just hosted in a different `Scene`.
    /// `isInWindow` is the one thing that differs: see `ContentView`'s
    /// property of the same name for why.
    private func contentView(isInWindow: Bool) -> ContentView {
        ContentView(
            viewModel: networkMonitor,
            lanDiscovery: lanDiscovery,
            connectivity: connectivity,
            networkIdentity: networkIdentity,
            publicIP: publicIP,
            dhcpLease: dhcpLease,
            networkQuality: networkQuality,
            screenshot: screenshot,
            wifiSSID: wifiSSID,
            eventLog: eventLog,
            traceroute: traceroute,
            snmp: snmp,
            buildInfo: buildInfo,
            storeURL: storeURL,
            isInWindow: isInWindow
        )
    }

    var body: some Scene {
        MenuBarExtra {
            contentView(isInWindow: false)
        } label: {
            MenuBarLabel(symbolName: networkMonitor.statusSymbolName, color: overallStatus.color)
        }
        .menuBarExtraStyle(.window)

        // Comparison window, opened via the popover's "Open in Window"
        // button (see `ContentView`) — not yet a replacement for the
        // popover above, just a side-by-side alternative to evaluate.
        //
        // An outer scroll container turned out not to be optional: without
        // one, the window is floor-clamped to its full content height, and
        // on the M1 MacBook Air's screen that's taller than the screen
        // itself — no way to reach the lower half at all, confirmed
        // directly. But the earlier outer `NoBounceScrollView` attempt
        // relied on scroll-wheel *chaining* out of an exhausted tile to
        // reach it, and that chaining is inconsistent across input
        // devices (fine on a trackpad, unreliable with a Magic Mouse).
        // `persistentScrollbar: true` is the fix: a `.legacy`, always-
        // visible scroller whose thumb can be grabbed and dragged
        // directly, a `mouseDown`-based interaction with nothing to do
        // with `scrollWheel(with:)` — reliable on any device, and not
        // dependent on chaining working. Wheel-scrolling over the gaps
        // between tiles (and chaining out of a tile) still works too; the
        // scrollbar is just the guaranteed path now, not the only one.
        // Deliberately an always-declared `Window` scene, gating its
        // *content* rather than the scene itself — see
        // `comparisonWindowContent`'s doc comment for why: a conditional
        // `Scene` here crashed `swift-frontend` outright ("failed to
        // produce diagnostic for expression"), a real type-checker
        // failure, not something fixable by restructuring the Scene side.
        // `FeatureFlags.comparisonWindow` still fully gates what a tester
        // can actually see — the footer button that opens this window is
        // hidden when the flag is off (see `ContentView`), so nothing
        // routes here in the first place; an empty window existing but
        // unreachable is a compiler workaround, not a real hole.
        Window("NMS", id: "nms-window") {
            comparisonWindowContent
        }
        .defaultSize(width: 600, height: 700)

        // A separate window rather than a popover section — see
        // `KnownNetworksView`'s doc comment.
        Window("Known Networks", id: "known-networks") {
            KnownNetworksView(networkIdentity: networkIdentity, snapshotStore: snapshotStore)
        }
        .defaultSize(width: 460, height: 320)

        // A plain `Window`, not a `Settings` scene — see
        // `PreferencesView`'s doc comment for why that doesn't reliably
        // work for a `.accessory` app.
        Window("Preferences", id: "preferences") {
            PreferencesView()
        }
        // Sizes to whatever the content actually measures rather than a
        // guessed `defaultSize` — that guess (380x260) was too short and
        // truncated both feature descriptions mid-sentence. Content
        // sizing means a longer description, a larger system font, or a
        // future third toggle can't reintroduce that.
        .windowResizability(.contentSize)
    }

    /// Gates the comparison window's *content*, not the `Window` scene
    /// itself — see the scene declaration's doc comment in `body` for why
    /// a conditional `Scene` isn't the mechanism here. `FeatureFlags
    /// .comparisonWindow` off means an empty window that's unreachable
    /// anyway (the footer button that opens it is hidden in that case),
    /// not a real content leak.
    /// Deliberately just `contentView(isInWindow: true)` — a single,
    /// direct call, same shape as the popover's own. An earlier version
    /// of this reached in and composed `ContentView.scrollableContent`/
    /// `.footerBar` as two separate children of a `VStack` declared here
    /// instead, to pin the footer outside the scroll container. That
    /// broke `@State` silently: `ContentView` was never actually placed
    /// in the tree as one identified node, only fragments of its
    /// computed output were, so nothing tied one render's mutated state
    /// to the next — confirmed via a live bug report filed through the
    /// exact path this broke (Bug Report producing no visible UI in the
    /// window, while identical code worked in the popover). The
    /// pinned-footer behavior itself is still here — moved into
    /// `ContentView.body`'s own `isInWindow` branch, where it can't
    /// split state across two parents because there's only ever one.
    @ViewBuilder
    private var comparisonWindowContent: some View {
        if FeatureFlags.comparisonWindow {
            contentView(isInWindow: true)
        } else {
            EmptyView()
        }
    }

    /// macOS forces menu bar icons to render as monochrome "template"
    /// images by default — a plain SwiftUI `Image` with `.foregroundStyle`
    /// gets that treatment too, silently ignoring the color (confirmed:
    /// the color didn't show up at all with that approach). Rasterizing
    /// the symbol into an `NSImage` and explicitly setting `isTemplate =
    /// false` is the standard way to bypass that.
    ///
    /// `fileprivate`, not `private` — `MenuBarLabel` above is a sibling
    /// type in this same file, not an extension of `NMSApp`, so `private`
    /// (scoped to the enclosing declaration) wouldn't reach it; this stays
    /// exactly as invisible outside `NMSApp.swift` either way.
    fileprivate static func statusIcon(symbolName: String, color: Color) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()

        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        NSColor(color).set()
        let rect = NSRect(origin: .zero, size: base.size)
        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    /// Falls back to an in-memory store if the on-disk store can't be
    /// opened (e.g. a corrupted database after a schema change), so a
    /// storage problem degrades to "history isn't saved this run" rather
    /// than the menu bar app failing to launch.
    ///
    /// **Explicit, app-specific store URL — not the SwiftData default.**
    /// `ModelConfiguration(schema:)` with no `url:` resolves to a bare
    /// `~/Library/Application Support/default.store` — a generic filename
    /// with no per-app namespacing at all. Confirmed directly via `lsof`
    /// that this app was NOT the only process on the Mac open on that
    /// exact path: `/usr/libexec/icloudmailagent`, a completely unrelated
    /// system daemon, had the same file open read/write at the same time,
    /// apparently for the same reason (it also left its own store
    /// unnamed). Two independent processes issuing SQLite writes/locks
    /// against one physical file is a real collision, not a hypothetical
    /// one — it produced a beachballed, genuinely unkillable (`kill -9`
    /// had no effect) NMS process, consistent with the main thread wedged
    /// in an uninterruptible wait on a contended file lock. Namespacing
    /// under a dedicated `NMS/` subdirectory, matching the pattern already
    /// used for `UIStateLogger`'s log file, makes this collision
    /// structurally impossible rather than just unlikely.
    /// The real store, unless a debug override points somewhere else.
    ///
    /// ```
    /// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSStorePath /tmp/nms-test/scratch.store
    /// defaults delete ~/Library/Preferences/Thistle.NMS.plist NMSStorePath
    /// ```
    ///
    /// Exists so scripted scenarios stop polluting real history.
    /// Injected failures write genuine `AppEventRecord` and
    /// `ConnectivityCheckRecord` rows, so every test run permanently
    /// added `[injected]` entries to the same event log and DHCP history
    /// the app exists to keep honest — twice already they had to be
    /// deleted by hand. Pointing a run at a throwaway path makes that
    /// structurally impossible instead of a cleanup step someone has to
    /// remember.
    ///
    /// Also gives scenarios a *known* starting state, which matters for
    /// more than tidiness: SNMP restart detection compares against a
    /// previously stored uptime, so against a fresh store the first poll
    /// is `.firstSeen` and logs nothing. A script wanting that event must
    /// let two polls run — obvious when starting from empty, invisible
    /// when starting from whatever happened to be there.
    ///
    /// `#if DEBUG` like the rest of the debug tooling. Parent directories
    /// are created if missing, and the path is logged at launch, because
    /// silently running against a different store than expected would be
    /// a genuinely confusing way to lose an afternoon.
    private static func storeURL() -> URL {
        let defaultURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NMS", isDirectory: true)
            .appendingPathComponent("default.store")

        #if DEBUG
        var resolved = defaultURL
        if let override = UserDefaults.standard.string(forKey: "NMSStorePath"), !override.isEmpty {
            resolved = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        #else
        let resolved = defaultURL
        #endif

        try? FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        UIStateLogger.log("App.store", resolved.path)
        return resolved
    }

    /// Returns the resolved store URL alongside the container — not just
    /// for logging (that already happens inside `storeURL()`), but so
    /// `ContentView` can read the store's on-disk size later. In the
    /// in-memory fallback path there's no real file at this path at all;
    /// `StoreSizeService` already reports that case as `nil` (the base
    /// file genuinely doesn't exist there) rather than a misleading zero,
    /// so no special-casing is needed here for it.
    private static func makeModelContainer() -> (ModelContainer, URL) {
        let schema = Schema([
            NetworkSnapshot.self,
            DiscoveredDeviceRecord.self,
            ConnectivityCheckRecord.self,
            KnownNetwork.self,
            PublicIPRecord.self,
            DHCPLeaseRecord.self,
            NetworkQualityRecord.self,
            AppEventRecord.self,
            ProviderEdgeRecord.self,
            SNMPDeviceRecord.self,
            WiFiSampleRecord.self
        ])
        let storeURL = Self.storeURL()
        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
            return (container, storeURL)
        } catch {
            print("NMS: failed to open persistent store (\(error)); falling back to in-memory store")
            let container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            return (container, storeURL)
        }
    }
}
