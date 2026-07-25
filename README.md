# NMS

A macOS menu bar network monitor for small networks and home labs —
automatically discovers LAN devices, your ISP's edge router, and your
public IP, monitors Internet connectivity at every layer from interface
to HTTP, persists the history, and correlates outages with the changes
that preceded them.

All four original build-plan steps have a first working version: interface
monitoring, persistence, LAN discovery, connectivity testing, and
correlation. Plus two later additions: network recognition/labeling and
Wi-Fi SSID display. See "What's implemented" for the specifics and current
limitations of each.

This is a real Xcode project (`NMS.xcodeproj`), not a bare Swift package.
It started as one (see the sibling `NMS 2` folder, now superseded) but
moved to a proper project specifically because reading the Wi-Fi SSID
needs a `NSLocationUsageDescription` Info.plist key — and Xcode's "open
Package.swift directly" workflow generates its own Info.plist for the Run
action's `.app` wrapper, silently ignoring anything a bare package tries
to embed. A real project gives reliable, standard control over Info.plist
and entitlements.

## Project layout

```
NMS/
├── NMS.xcodeproj
├── NMS/
│   ├── NMSApp.swift                       # App entry point, menu bar scene, model container
│   ├── Assets.xcassets
│   ├── Models/
│   │   ├── NetworkInterfaceInfo.swift     # Interface snapshot value type
│   │   ├── NetworkSnapshot.swift          # SwiftData model, persisted interface history
│   │   ├── DiscoveredDevice.swift         # LAN device value type
│   │   ├── DiscoveredDeviceRecord.swift   # SwiftData model, persisted per-snapshot device list
│   │   ├── ConnectivityCheck.swift        # Reachability check value type
│   │   ├── ConnectivityCheckRecord.swift  # SwiftData model, persisted check history
│   │   ├── KnownNetwork.swift             # SwiftData model, one row per recognized network
│   │   ├── PublicIPInfo.swift             # Public-IP lookup value type
│   │   ├── PublicIPRecord.swift           # SwiftData model, persisted public-IP change history
│   │   ├── AppEventRecord.swift           # SwiftData model, the event log (+ AppEventKind)
│   │   ├── TracerouteHop.swift            # One hop's value type (+ RFC1918 classification)
│   │   ├── ProviderEdgeRecord.swift       # SwiftData model, persisted ISP edge router history
│   │   ├── BonjourDevice.swift            # Bonjour-discovered device value type
│   │   ├── BonjourDeviceRecord.swift      # SwiftData model, persisted per-snapshot Bonjour list
│   │   ├── SNMPDevice.swift               # SNMP-discovered infrastructure device value type
│   │   └── SNMPDeviceRecord.swift         # SwiftData model, current state per SNMP device
│   ├── Services/
│   │   ├── SystemConfigurationService.swift  # Reads/observes network state
│   │   ├── SnapshotStore.swift            # Reads/writes all persisted history
│   │   ├── LANDiscoveryService.swift      # Enumerates LAN devices via `arp -a`
│   │   ├── ConnectivityService.swift      # Pings a target via `/sbin/ping`
│   │   ├── CorrelationService.swift       # Time-proximity failure/change matching
│   │   ├── PublicIPService.swift          # Looks up WAN IP via api.ipify.org
│   │   ├── LocationAuthorizationService.swift  # Requests Core Location auth (for SSID)
│   │   ├── WiFiSSIDService.swift          # Reads current Wi-Fi SSID via CoreWLAN
│   │   ├── IPClassifier.swift             # RFC 1918 private-address classification
│   │   ├── SubnetCalculator.swift         # IPv4 subnet host enumeration (with a size guard)
│   │   ├── SNMPService.swift              # SNMP GET/sweep via /usr/bin/snmpget
│   │   ├── TracerouteService.swift        # Walks the path via `/usr/sbin/traceroute`
│   │   ├── DNSResolutionService.swift      # Resolves a hostname via `getaddrinfo`
│   │   ├── HTTPCheckService.swift         # Real HTTP fetch via Apple's captive-portal probe
│   │   ├── OverallStatus.swift            # Menu bar severity: normal/marginal/critical
│   │   └── BonjourDiscoveryService.swift  # Browses/resolves Bonjour (mDNS) services
│   ├── ViewModels/
│   │   ├── NetworkMonitorViewModel.swift  # Bridges SystemConfigurationService -> SwiftUI
│   │   ├── LANDiscoveryViewModel.swift    # Bridges LANDiscoveryService -> SwiftUI
│   │   ├── ConnectivityViewModel.swift    # Bridges ConnectivityService -> SwiftUI
│   │   ├── NetworkIdentityViewModel.swift # Recognizes/labels the current network
│   │   ├── PublicIPViewModel.swift        # Bridges PublicIPService -> SwiftUI
│   │   ├── WiFiSSIDViewModel.swift        # Bridges WiFiSSIDService -> SwiftUI
│   │   ├── EventLogViewModel.swift        # Fetches/exposes the event log
│   │   ├── TracerouteViewModel.swift      # Bridges TracerouteService -> SwiftUI
│   │   ├── BonjourDiscoveryViewModel.swift  # Bridges BonjourDiscoveryService -> SwiftUI
│   │   └── SNMPViewModel.swift            # SNMP discovery, polling, restart/upgrade events
│   └── Views/
│       └── ContentView.swift              # Menu bar popover UI
├── NMSTests/                              # Default template test target (unused so far)
└── NMSUITests/                            # Default template UI test target (unused so far)
```

## Running it

1. Open `NMS.xcodeproj` in Xcode.
2. Select the `NMS` scheme and Run (⌘R).
3. A network icon (📶 or 🔌) appears in the menu bar. Click it to see the
   current interface, IP, subnet, router, and public IP.

The popover is arranged top to bottom as: **Network Health**, **Info**
(the interface/IP/subnet/router/public-IP details — this section used to
be titled "NMS"), **Events**, **Path to Internet**, **Infrastructure**
(SNMP devices), **LAN Devices**, **Bonjour Devices**, then Refresh/Quit. There's no separate Connectivity
section anymore — its raw IP-layer check was folded into Network Health,
and the rest of what it showed was already covered there too. The
scrollable lists for Path to Internet, LAN Devices, and Bonjour Devices are
deliberately short (60/90/90px — Path to Internet sized for ~3 visible
rows) to leave room for everything else to fit in the popover's limited
vertical space.

## Building a universal (Intel + Apple Silicon) binary

**In Xcode: Product → Archive.** That's it — the archive product is
universal (`x86_64 arm64`) with no extra settings. In the Organizer window
that opens, use Distribute App → Custom → Copy App to export it, or
right-click the archive → Show in Finder → Show Package Contents →
`Products/Applications/NMS.app`.

Equivalently, from the command line:

```bash
cd ~/Developer/NMS && xcodebuild -project NMS.xcodeproj -scheme NMS -configuration Release -archivePath ~/Desktop/NMS.xcarchive archive
```

**The gotcha worth knowing**: a plain `xcodebuild ... build` (rather than
`archive`) produces a binary for the *host* architecture only — verified
directly, an ordinary Release build on an Intel Mac came out x86_64-only
and would not have run natively on Apple Silicon. This is not a project
misconfiguration: `-showBuildSettings` correctly reports
`ARCHS = arm64 x86_64` and `ONLY_ACTIVE_ARCH = NO`, but the destination
`build` resolves narrows it to the native arch anyway. `archive` doesn't
do that. If you do want `build` specifically, force it:

```bash
xcodebuild -project NMS.xcodeproj -scheme NMS -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

Confirm the result either way with `lipo`, which should list both:

```bash
lipo -info /path/to/NMS.app/Contents/MacOS/NMS
```

To package it for another Mac, use `ditto` rather than the Finder's
Compress or a plain `zip` — it preserves the bundle's symlinks and
extended attributes correctly:

```bash
ditto -c -k --keepParent /path/to/NMS.app ~/Desktop/NMS.zip
```

Because local builds are ad-hoc signed (no Developer ID), Gatekeeper
blocks the first launch on another Mac: right-click `NMS.app` → Open, or
`xattr -cr /Applications/NMS.app` after copying it over. For builds you
intend to hand to other people, use `script/release.sh` instead and skip
the warning entirely — see "Signed and notarized releases" below. Note
also that the SNMP community list lives in `UserDefaults`, so it does
*not* travel with the app bundle — it has to be set again on each
machine.

Requires macOS 14+ (for `SwiftData`; `MenuBarExtra` itself only needs 13+)
and Xcode 15+.

**Four non-default project settings, all load-bearing — don't "fix" them
back to template defaults:**
- `ENABLE_HARDENED_RUNTIME = YES` (target build settings, Release only).
  Required for notarization — Apple rejects submissions without it. Left
  off for Debug, where it interferes with SwiftUI Previews and the
  debugger. It does not restrict this app's subprocess spawning: `ping`,
  `traceroute`, `arp`, and `snmpget` are all signed system binaries, so
  no additional entitlements are needed.
- `ENABLE_APP_SANDBOX = NO` (target build settings). The template defaults
  to sandboxed. This app shells out to `/sbin/ping` and `/usr/sbin/arp`
  (see "Notes on sandboxing"), which App Sandbox blocks outright — leaving
  sandboxing on breaks LAN discovery, connectivity testing, network
  recognition (which depends on LAN discovery's ARP data), and traceroute
  all at once, with no error message, just silent failure.
- `INFOPLIST_KEY_NSLocationUsageDescription` /
  `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` (target build
  settings, no physical Info.plist file needed). Required for the Wi-Fi
  SSID feature's Core Location authorization request to do anything at
  all — without it, `requestWhenInUseAuthorization()` fails completely
  silently: no prompt, no error, no SSID.
- `INFOPLIST_KEY_NSLocalNetworkUsageDescription` (same mechanism). Required
  for Bonjour discovery — without it, `NWBrowser` silently finds zero
  devices, no error, no permission prompt, even when devices are
  confirmed present on the network via `arp -a`.

The first time you're on Wi-Fi, macOS will show a system permission
prompt asking to grant NMS access to Location Services — required to read
the Wi-Fi network name (SSID), no other purpose in this app. If you
decline, the popover falls back to the generic interface name instead.
Separately, the first Bonjour scan will prompt for Local Network access —
decline and the Bonjour Devices section just stays empty, everything else
keeps working. Because local Xcode debug builds are ad-hoc signed (no
stable Developer ID), macOS may treat each rebuild as a "new" app and
re-prompt for both — expected during development, not a bug.

## What's implemented

- **`SystemConfigurationService`**: reads the current primary interface
  (name, friendly display name, IP, subnet mask, router, Wi-Fi vs.
  Ethernet) and can register a callback that fires on network changes
  (interface up/down, IP change, Wi-Fi network switch).
- **Live updates**: the menu bar view refreshes automatically when
  `SystemConfigurationService` detects a change — try toggling Wi-Fi or
  switching networks while the app is running.
- **Persistence**: a SwiftData `NetworkSnapshot` model mirrors
  `NetworkInterfaceInfo`. `SnapshotStore` writes a row each time
  `NetworkMonitorViewModel` receives an actual `observeChanges` callback
  (not on the manual Refresh button, and not on a timer) — so the store is
  a timeline of real topology changes. The on-disk store lives in the
  default SwiftData application-support location; if it fails to open
  (e.g. after a schema change), the app falls back to an in-memory store
  for that run rather than failing to launch.
- **LAN device discovery**: `LANDiscoveryService` shells out to `arp -a`
  and parses the kernel's ARP cache into `DiscoveredDevice` values
  (IP, MAC, hostname when resolved, interface). This surfaces hosts the
  Mac has already exchanged traffic with — it's not an active subnet scan.
  Results are de-duplicated by IP (the same device often appears once per
  local interface, and — confirmed against real output — the same MAC can
  legitimately appear at two different IPs briefly, e.g. an access point
  mid-DHCP-renewal) and multicast addresses are filtered out.
  `LANDiscoveryViewModel` runs a scan automatically every time
  `NetworkMonitorViewModel` persists an observed topology change, tying
  the resulting `DiscoveredDeviceRecord` rows to that `NetworkSnapshot`;
  the popover's "Scan" button triggers the same scan on demand (tied to
  the latest snapshot), and one runs once at launch too. **Rendering note**:
  this list (and Bonjour's below) used `.frame(maxHeight:)` on their
  `ScrollView`s, which — like the event log earlier — could collapse to
  *zero visible height even with real data present*, showing nothing at
  all rather than an empty-state message. Diagnosed conclusively via a
  screenshot: both sections appeared completely blank while the
  Connectivity section was visibly pinging `router.local` and `10.0.0.16`
  — proof `lanDiscovery.devices` wasn't actually empty, since those two
  targets come directly from it. Fixed the same way as the event log: a
  fixed `.frame(height:)` instead of `maxHeight`.
- **Bonjour device discovery**: `BonjourDiscoveryService` complements the
  ARP-based scan above with active mDNS/DNS-SD discovery via `NWBrowser` —
  it finds devices that advertise a service even if the Mac has never
  exchanged traffic with them, and tells you *what kind* of device it is
  (a printer, an AirPlay receiver, etc.), neither of which ARP can provide.
  There's no "browse everything" Bonjour API — discovery is always scoped
  to one specific service type — so it checks a curated set of ~9 common
  ones (AirPlay, printers, file sharing, SSH, Chromecast, HomeKit, …) in
  parallel, then resolves each result to an IP via `NWConnection`.
  Verified directly against the real network: correctly found a Brother
  printer and multiple AirPlay devices (including two variants of the same
  physical device — `_airplay._tcp` and `_raop._tcp` are separate
  services), with real resolved IPs. One real bug this surfaced and fixed:
  `IPv4Address`'s string form can carry a meaningless `%interface` zone-ID
  suffix (a concept that only makes sense for IPv6) — stripped for IPv4,
  kept for IPv6 where it's actually needed (verified: a Roku's IPv6
  link-local address correctly kept its `%en0` suffix while IPv4 addresses
  came back plain). Two more real bugs surfaced by testing on a second
  machine, after this feature initially looked correct on the first:
  (1) **A genuine ordering race**: `browse`/`resolveIP` originally tracked
  callback-reported state in an `actor`, but each callback (which can fire
  more than once and isn't itself `async`) updated that actor via a
  fire-and-forget `Task { await box.update(...) }` — spawned, never
  awaited. The final read happened right after `Task.sleep` + `cancel()`,
  with no guarantee the last spawned update had actually landed before
  that read ran. An actor prevents *corrupted* concurrent access, but
  doesn't by itself guarantee *ordering* between "last callback fired" and
  "final read" when the callback's effect is deferred into an unawaited
  task — on a fast/idle machine that race quietly resolves in your favor
  most of the time, which is exactly why it looked fine on the first
  machine tested. Fixed by confining both the callback writes and the
  final read to the same serial `DispatchQueue`, giving a real
  happens-before relationship instead of a race — the *only* remaining
  continuation use is a single one-shot read of already-settled state,
  which can't double-resume because there's exactly one code path that
  calls it. (2) **Insufficient timing headroom**: even after the ordering
  fix, a launch-time scan intermittently came back empty — reproduced 3
  consecutive times, root-caused to Bonjour discovery competing with LAN
  scan, traceroute, connectivity checks, and SSID/location auth all firing
  concurrently at startup. Confirmed by widening the browse/resolve
  windows (3s/2s → 4s/3s) and re-running the exact same scenario 3
  consecutive times with consistent, complete results afterward. Takes a
  few seconds total (windows run in parallel across service types), so
  `BonjourDiscoveryViewModel` only scans once at launch and on the
  popover's "Scan" button — not tied to every topology change the way the
  near-instant ARP scan is. Requires the `NSLocalNetworkUsageDescription`
  Info.plist key (see below) — without it, discovery silently returns zero
  results, no error, no permission prompt at all (confirmed directly: a
  bare test executable with no Info.plist found nothing on a network with
  devices confirmed present via `arp -a`, and adding the key to the real
  app's Info.plist fixed it).
- **Connectivity testing**: `ConnectivityService` pings a target once via
  `/sbin/ping -c 1 -t 2` and parses real ICMP round-trip time (see "Notes
  on sandboxing" below for the tradeoff this implies). Three layers of "is
  the internet actually usable" are checked independently, since each can
  fail while the others still work: **IP** (the existing ping to `1.1.1.1`),
  **DNS** (`DNSResolutionService.probe()`, via the POSIX `getaddrinfo`
  call — a real system-resolver lookup, isolated from any other network
  I/O), and **HTTP** (`HTTPCheckService` fetches Apple's own captive-portal
  probe, `http://captive.apple.com/hotspot-detect.html` — deliberately
  plain HTTP, not HTTPS, since captive portals intercept port 80 to inject
  their redirect — and checks for its known 200/"Success" response). All
  three verified directly: real DNS resolution, a real captive-portal-probe
  fetch, both against actual network traffic, both succeeding with real
  latency numbers.

  **DNS check caching bug, found and fixed**: the original version resolved
  a fixed hostname (`apple.com`) and treated success as "reachable" — but
  macOS's system resolver caches successful answers for their record's
  TTL, so once `apple.com` had resolved once, later calls could be served
  entirely from that cache with zero actual network traffic. Confirmed
  directly: disabling an upstream switch (between the local router and the
  ISP) didn't make this check report unreachable at all, since `apple.com`
  had already resolved and cached before the outage started — the same
  category of bug as the HTTP cache issue above, one layer down in DNS
  instead. Unlike HTTP, there's no simple "bypass cache" flag for
  `getaddrinfo`. The fix: `probe()` queries a *freshly randomized*
  subdomain of `apple.com` every call (e.g. `nms-check-<random>.apple.com`)
  and treats the resulting `EAI_NONAME` — a genuine NXDOMAIN-equivalent —
  as success, not failure. A label that's never been queried before can't
  possibly be served from a prior cache entry (a cache can only serve a
  hit for an exact name it's already seen), so this forces a real round
  trip every time; the negative answer itself is proof resolution reached
  real authority and got a definitive response. `EAI_AGAIN` (returned when
  no DNS server could be reached at all) is still a real failure. One
  wrong turn along the way, corrected before landing: RFC 2606's
  reserved-for-failure TLDs (`.invalid`, `.test`, `.example`) seemed like a
  cleaner base domain at first, since they're guaranteed to never resolve
  — but measured directly, macOS's resolver short-circuits those locally
  in ~1-2ms with no real network round trip at all, which would report
  "reachable" identically whether the network was actually up or down. A
  real, ordinary domain's nonexistent random subdomain measured ~5ms in
  the same test, consistent with an actual round trip to real DNS
  infrastructure — confirming an ordinary domain, not a reserved TLD, is
  the right base.

  Randomizing the label alone still wasn't enough: a real upstream-outage
  test showed `getaddrinfo` blocking for ~30s (retrying across configured
  resolvers internally) and *still* ultimately returning `EAI_NONAME` at
  the end — reported as "reachable" with an implausible ~30000ms latency,
  not the failure this exists to catch. `probe()` now races the call
  against an explicit 2s timeout (`getaddrinfo` has no native
  cancellation, so the underlying call is simply left to finish on its own
  in the background and its result discarded) and treats not finishing in
  time as failure regardless of what `getaddrinfo` eventually decides —
  the same principle as `ping`'s own `-t 2`, applied here explicitly since
  `getaddrinfo` doesn't bound itself the same way. The same 30s-style gap
  existed for the HTTP check too, just less visibly: an unset
  `URLRequest.timeoutInterval` defaults to 60s, so `HTTPCheckService` could
  have blocked for up to a minute during a real outage before failing —
  fixed the same way, an explicit 2s timeout. And `ConnectivityService
  .check(targets:)` ran pings sequentially (`targets.map(check)`) — with
  up to 5 targets (router, 2 LAN devices, internet, ISP edge router) each
  capable of blocking for their own full 2s timeout, that could add up to
  10s just for pings alone. Now runs them concurrently via `DispatchGroup`,
  bounding the whole batch to the single slowest ping (~2s) instead of
  their sum. All three together matter because of how `runChecks()` is
  structured: it only calls `apply()` — the point where results actually
  reach the UI — once *all* of a round's checks finish, so one slow check
  used to silently stall the whole round (confirmed directly: the same
  upstream-outage test showed the popover not updating at all — not just
  DNS's status, everything's — until a manual "Refresh" click, since
  ISP-edge-router and internet had almost certainly already finished
  correctly but stayed unapplied, queued up behind the ~30s DNS call).

  **A second, subtler variant of the same bug class**, found testing the
  interface fully down (not just an upstream outage) rather than assuming
  the earlier fixes covered every case: with zero interfaces up at all,
  the randomized-label DNS probe still returned "success" — `EAI_NONAME`
  in ~1ms, the same code used elsewhere in this app as proof of a genuine
  round trip, but ~1ms is implausibly fast for one (matches the earlier
  `.invalid`-TLD measurement, not the ~5ms real-round-trip one). With no
  interface at all, `getaddrinfo` apparently takes some local shortcut and
  still returns the same "success" code — not a real answer, but
  indistinguishable from one by return code alone. Rather than chase
  another return-code-based heuristic, `ConnectivityViewModel.runChecks()`
  now checks `networkMonitor.currentInterface` *before* attempting
  Internet/DNS/HTTP/ISP-edge-router at all: with no interface,
  `SCDynamicStore` (see `SystemConfigurationService`) already gives
  definitive ground truth that none of them can possibly be reachable, so
  there's nothing to gain — and, confirmed directly, real risk — in asking
  the network layer to confirm what's already known. All four are marked
  unreachable immediately instead, skipping the underlying checks (and
  their OS-shortcut risk) entirely.

  This surfaced one more inconsistency worth fixing at the same time: in
  `ContentView.connectionLayersLowToHigh`, Network and Local Router used to
  fall back to `.unknown` (gray, "not evaluated") whenever there was no
  interface — but that's not genuine uncertainty the way it is when, say,
  a connectivity round just hasn't run yet. With Interface itself already
  down, Network and Local Router being down too is a certain consequence,
  not an open question, so they now report `.unhealthy` in that specific
  case (still `.unknown` otherwise, e.g. before the first check completes)
  and correctly join the existing root-cause dimming — Interface renders
  full red as the actual root cause, everything above it (now including
  Network and Local Router) renders dimmed red as a consequence, instead
  of an inconsistent mix of red/gray/(previously, buggy green) that read
  as unrelated rather than cascading from one cause.
  `ConnectivityViewModel` runs a round of checks every 30s — router, up to
  2 currently-known LAN devices, IP, DNS, HTTP, and (once a hop is
  confirmed — see "Path to internet" below) the ISP edge router itself —
  plus once at launch and immediately on every observed topology change
  (`NMSApp`'s `onChangePersisted`), rather than leaving Network Health's
  router/internet/DNS/HTTP/ISP-edge-router layers showing stale status for
  up to 30s after an interface comes back up or fails over to a different
  one. The 30s cadence itself is reactive, not fixed: whenever any of
  those five currently has an unhealthy result, the *next* round is
  scheduled 5s later instead of 30s, so Network Health catches a recovery
  (or confirms it's still down) much sooner during an actual outage — it
  drops back to the 30s cadence once everything's healthy again. Scoped to
  just those five checks (`OverallStatus.criticalLabels`), not the LAN
  device ones also in the same round, so a single sleeping/offline LAN
  device (not a real outage) can't pin polling to the fast interval
  indefinitely. Implemented as a one-shot `Timer` that reschedules itself
  after every round (replacing a fixed repeating one), since the delay
  before the next round now depends on the result of the round that just
  finished. Ping and DNS resolution block for up to a couple of seconds
  each, so they run on a background queue; the HTTP fetch is genuinely
  async and doesn't need that. Checks aren't tied to a `NetworkSnapshot`
  by relationship — correlation (below) matches them up by comparing
  timestamps instead. There's no dedicated Connectivity section in the
  popover anymore (see "Network Health" below) — these checks still run
  on the same schedule. The LAN device pings still aren't surfaced
  anywhere in the UI (there's no layer for them in Network Health), but
  the `correlatedWithChange` `*` flag is — it moved to the Network Health
  rows instead.
- **Network Health (layered hierarchy view)**: `ConnectionLayer` models
  "is the internet actually working" as a dependency chain, ordered low
  (most fundamental) to high (most dependent on everything below it):
  Interface → Network (SSID/Ethernet) → Local Router → ISP Edge Router →
  Internet → DNS → HTTP. The raw IP-layer check (ping to `1.1.1.1`) used
  to only appear in the separate Connectivity list; it's now folded in
  here as its own layer between ISP Edge Router and DNS, and the standalone
  Connectivity section was removed from the popover since Network Health
  already covered everything else it showed. The ISP Edge Router row
  reports a ping round-trip time now, not a re-trace's resolved hostname —
  every other row already reported timing, the hostname is still visible
  in the Path to Internet section, and (see "Path to internet" below)
  ongoing health of that hop is `ConnectivityViewModel`'s job now, not
  `TracerouteViewModel`'s. Each layer is `.healthy`,
  `.unhealthy`, or `.unknown` (not a failure — e.g. the ISP router hop
  hasn't been confirmed yet, or Wi-Fi's SSID couldn't be read).
  `ContentView.rootCauseLayerID` scans low-to-high for the *first*
  unhealthy layer and treats it as the actual root cause; anything
  unhealthy *above* that is rendered as a dimmed red (not full red) rather
  than an independent problem, since each layer's failure is the expected
  consequence of whatever's already broken below it — e.g. if DNS is
  down, HTTP will obviously fail too, but DNS is "the" problem, not HTTP.
  An HTTP-only failure (DNS/router/interface all healthy — a captive
  portal, say) correctly renders as full red since it's the lowest (only)
  failing layer. Verified against 8 scenarios (all healthy, single-layer
  failures at different depths, multiple simultaneous failures with
  correct root-cause selection and dimming, unknown layers correctly not
  interfering with root-cause detection) before the Internet layer was
  added; not independently re-verified against the 7-layer version beyond
  a build/launch check.
- **Correlation**: `CorrelationService` flags a connectivity failure as
  `correlatedWithChange` when it lands within 90 seconds (either
  direction) of some `NetworkSnapshot.capturedAt` — a coarse
  time-proximity heuristic, not causal proof. `SnapshotStore` computes
  this at write time (only for failures; successes are never flagged) and
  looks back over the last 50 snapshots. Only the four Network Health
  layers backed by a `ConnectivityCheck` (Local Router, Internet, DNS,
  HTTP) can carry this — Interface/Network/ISP Edge Router aren't derived from
  one, so `ConnectionLayer.correlatedWithChange` defaults to `false` for
  them. A correlated, currently-unhealthy layer gets a `*` appended to its
  detail text (still colored by the existing root-cause/dimming rules,
  not a separate color), with a footnote below the list — "* possibly
  related to a recent network change" — shown whenever any layer has one.
- **Network recognition**: `KnownNetwork` fingerprints a network by its
  gateway's MAC address (not SSID — see "Notes on network identity"
  below), since MAC survives DHCP lease changes and IP/subnet coincidences
  across genuinely different networks (many home routers default to the
  same `192.168.1.1`). `NetworkIdentityViewModel.recognize` runs after
  every LAN scan (it needs that scan's ARP data to find the router's MAC),
  looks up or creates the matching `KnownNetwork`, and bumps its
  `timesSeen`/`lastSeenAt`. The popover shows read-only "New network" vs
  "Known network (seen N×)" status — there's no in-popover way to enter or
  change a label anymore (the text field/Edit button were removed
  entirely). `NetworkIdentityViewModel.setLabel`/`SnapshotStore.setLabel`
  still exist and still work if a label is set some other way — a label,
  once set, still shows via the "Info" section's "Network" row — but
  nothing in the UI currently calls them.
- **Public IP tracking**: `PublicIPService` asks `api.ipify.org` (a no-auth,
  plain-text "what's my IP" endpoint — there's no way to learn your
  WAN-facing address purely locally, since it's whatever your network's
  NAT/router presents to the internet) and `PublicIPViewModel` checks
  every 5 minutes, once at launch, right after every observed topology
  change (the likeliest moment it'd actually change), and on the popover's
  "Refresh" button. Like `NetworkSnapshot`, `SnapshotStore` only persists a
  `PublicIPRecord` row when the IP actually changed — a change timeline,
  not a per-check log. A real change also logs a neutral (not positive or
  negative — it's information, not a problem or a fix) `publicIPChanged`
  event with the from/to addresses, except on the very first-ever check
  (nothing to compare against yet). Verified directly: seeded a fake
  "previous" IP in the database, let the app fetch the real one on launch,
  and confirmed both the new `PublicIPRecord` and the correctly-worded
  event were written.
- **Wi-Fi network name (SSID)**: `WiFiSSIDService` reads the SSID via
  CoreWLAN, gated behind Core Location authorization
  (`LocationAuthorizationService`) — macOS treats Wi-Fi network names as
  location-sensitive since they can be reverse-geocoded via
  SSID-to-location databases, so there's no way to read this without a
  location permission grant (confirmed directly: even
  `system_profiler SPAirPortDataType`, a command-line tool, redacts the
  SSID without it). `WiFiSSIDViewModel.refresh` runs at launch, after
  every observed topology change, and on manual "Refresh." The "Info"
  section's top row shows, in order of preference: your manual label (if
  one is set some other way) → the live SSID (if on Wi-Fi and authorized)
  → the generic interface name.
- **Event log**: `AppEventRecord` is a narrow, curated timeline — five bad
  states (`interfaceDown`, `routerUnreachable`, `internetUnreachable`,
  `dnsUnreachable`, `httpUnreachable`), each paired with a recovery
  counterpart (`interfaceUp`, `routerReachable`, `internetReachable`,
  `dnsReachable`, `httpReachable`), so an outage is bracketed by a start
  and an end event rather than only ever showing when things broke.
  Every kind is logged only on the *transition* in either direction, never
  repeatedly while a state persists (a router down for an hour produces
  two events total — down, then up — not one per 30s connectivity-check
  cycle) — verified against 9 transition scenarios (first-ever failure,
  still-failing, recovers, stays recovered, fails again, first-ever
  failure at launch, simultaneous router+internet recovery, unrelated LAN
  device change out of scope). `NetworkMonitorViewModel` logs
  `interfaceDown`/`interfaceUp` around the interface having no connection
  at all. `interfaceDown` was previously silently dropped entirely (the
  old code only handled "now have an interface," never "now have none"),
  so that transition never appeared in any persisted history until this
  feature added the missing branch. A separate `interfaceChanged` (neutral
  — not a failure or recovery) fires when the *primary* interface itself
  switches — e.g. an Ethernet/Wi-Fi failover on a Mac with both connected
  — without ever going through a `nil` gap in between: confirmed this was
  otherwise invisible on a Mac with Ethernet (macOS's higher-priority
  interface) and Wi-Fi both enabled, since disabling/re-enabling either
  one just hands primary status to the other fast enough that
  `currentInterface` never actually goes nil, so `interfaceDown`/
  `interfaceUp` never had anything to fire on. Compares
  `NetworkInterfaceInfo.interfaceName` (the underlying BSD name, e.g.
  `en0` vs `en1`) specifically, not the full struct equality already used
  for change detection, so an ordinary IP/subnet change on the *same*
  interface (a DHCP lease renewal, say) doesn't also fire this.
  `ConnectivityViewModel` logs
  `routerUnreachable`/`internetUnreachable`/`dnsUnreachable`/
  `httpUnreachable`/their recovery counterparts by comparing each check
  round against the previous one, per-label. `PublicIPViewModel` logs
  `publicIPChanged` the same way — a real change, not a first-ever
  reading. All post through `onEventLogged` callbacks so
  `EventLogViewModel` can refresh. The popover shows recent events in a
  fixed-height (~10 rows), scrollable list — recoveries in green, bad
  states in red, `publicIPChanged`/`interfaceChanged` in the default text
  color (neither is a problem or a fix) — with timestamps.
- **SNMP infrastructure discovery**: SNMP devices are, almost by
  definition, the managed infrastructure whose failure explains the
  outages the rest of this app tracks — switches, APs, routers, printers,
  UPSes. `SNMPService` shells out to `/usr/bin/snmpget`: macOS bundles
  net-snmp, so this needs no third-party dependency and no hand-rolled
  ASN.1/UDP, the same free ride already taken with `ping`/`arp`/
  `traceroute`. Three OIDs are fetched in one GET — `sysDescr.0` (model
  *and* running software version, e.g. "Alta Route10 1.5b"), `sysName.0`
  (configured hostname), and `sysUpTime.0` (restart detection).

  Three things were measured against the real tool before any code was
  written, rather than assumed. **The default timeout is ~6s per
  unresponsive host** (1s × 5 retries) — unusable across a 254-host sweep,
  and exactly the class of unbounded-timeout bug that had already bitten
  this app three separate times (DNS, HTTP, sequential pings); `-t 1 -r 1`
  brings it to ~2s. **`-Oqvt` is the parse-friendly output format**:
  values only, no OID or type prefix, and TimeTicks as a raw integer
  (`287237340`) instead of `"33 days, 5:52:37.22"` — essential, since
  restart detection is a numeric comparison. **Failure semantics are
  clean**: exit 0 with values one-per-line in requested order, or exit 1
  with empty stdout and the error on stderr.

  **Discovery and monitoring are deliberately separate**, the same split
  applied to traceroute (see "Path to internet"), but here it's three
  tiers rather than two. *Discovery* (`scan()`) sweeps the local subnet
  plus every address the app already knows — gateway, ARP entries,
  Bonjour IPs, and private traceroute hops (routers by definition, and
  possibly on a different subnet than ours, so the sweep alone would miss
  them). *Reachability* is a plain ping on the existing fast/reactive
  5s/30s connectivity cadence — SNMP responders replaced the old
  "first 2 arbitrary ARP entries" as ping targets, which is a strict
  improvement: a managed switch going quiet is a real event, a random
  laptop from the ARP cache going to sleep is not. That also finally gives
  those pings a reason to exist in the UI, having been write-only before.
  *SNMP data* (`poll()`, 60s) re-queries only known responders for uptime
  and descriptor changes.

  **`sysUpTime` and `sysDescr` are more useful together than separately**,
  which is what the event logic keys on: uptime going *backwards* means a
  restart, `sysDescr` changing means the software changed, and the two
  *together* mean a reboot that followed an upgrade — explained, rather
  than mysterious. So a bare restart logs `snmpDeviceRestarted` (negative,
  red — the genuinely unplanned case), while a restart accompanying a
  descriptor change logs `snmpDeviceSoftwareChanged` (neutral) with a
  "restarted after software change: <old> → <new>" message. Deliberately
  no "device discovered" event: the first sweep would log one per device
  and flood a 10-row event list with things that aren't changes.

  **Sweep safety.** `SubnetCalculator` refuses to enumerate anything
  larger than 512 hosts (`maxSweepHosts`), so a /24 (254) and /23 (510)
  sweep but a /22 or /16 returns `nil` and falls back to known addresses
  only — at ~2s per silent host, nobody wants to start a 65,534-host
  sweep by accident. Verified against 17 cases including the /16 and /22
  refusals, /30 /31 /32 edges, network/broadcast exclusion, and
  top-of-range (255.255.255.254) overflow. Probes run concurrently
  bounded by a semaphore at 32 — a ceiling on forked processes, not just
  traffic. Measured on a real /24: **253 hosts in 2.5s**, far faster than
  the ~16s worst case, because most hosts reject the UDP packet
  immediately rather than timing out silently.

  **Community strings (plural).** SNMP v1/v2c authenticates with a
  community string; `public` is the near-universal read-only default.
  Real networks routinely mix vendors or eras of gear using different
  strings, so this takes an *ordered list* rather than a single value —
  entered comma-separated in the popover, stored in `UserDefaults`
  (alongside the monitored-hop setting), with the pre-existing
  single-string key read once on upgrade so an old setting carries over.

  Order is meaningful and worth getting right: strings are tried in
  sequence, so every one ahead of the correct one costs a full ~2s
  timeout on a silent host, and on a device that *is* listening but
  rejects it, typically leaves an `authenticationFailure` entry in that
  device's own log. Which is why **the string a device actually answered
  on is remembered per device** (`SNMPDevice.community`, persisted on
  `SNMPDeviceRecord`): only *discovery* tries the whole list, since which
  one works is exactly what's unknown then. The 60s re-poll queries each
  known device on its own string alone — measured at **0.12s versus 2.2s**
  when a wrong string would otherwise be tried first, and, more
  importantly, generating no recurring auth-failure noise on someone
  else's console.

  These are deliberately *not* treated as Keychain-grade secrets: they're
  shared read-only passwords, usually the well-known default, and putting
  them in the Keychain would imply a confidentiality guarantee SNMPv2c
  itself doesn't provide — the string crosses the wire in cleartext on
  every query. Changing the list discards the current device list, since
  devices found under the old strings may not answer under the new ones.
  Duplicates and blanks are dropped; an empty input falls back to the
  default rather than leaving nothing to try. SNMPv3 (real auth/privacy)
  is not supported.

  Multi-community behavior verified against a real device: correct string
  alone succeeds; a wrong string *first* still finds the device and
  records the winner (not the failure); an all-wrong list correctly
  returns nothing rather than a false positive; and a two-string /24
  discovery sweep took 4.8s against 2.5s for one string, as expected.

  **Not auto-run at launch.** Unlike Bonjour, discovery is manual — a full
  sweep during startup, alongside the LAN scan, Bonjour discovery,
  traceroute, connectivity checks and location auth, is precisely the
  launch-time contention that already produced an intermittent
  empty-results bug in Bonjour. Instead, previously-found devices are
  rehydrated from SwiftData at init, so they display, poll, and get pinged
  immediately, while the sweep itself waits for the "Scan" button.

  **Dependency risk worth knowing**: the bundled net-snmp is 5.6.2.1
  (~2011) and Apple hasn't updated it in over a decade — it has been
  deprecation-listed for a while. `SNMPService.isAvailable` checks for the
  binary so the feature degrades to a clear "snmpget unavailable on this
  macOS version" message rather than silently breaking if a future macOS
  drops it. This is a higher removal risk than `arp`/`ping`/`traceroute`.

  **Verified on a real network**: the sweep found the gateway (an Alta
  Route10 running 1.5b, 33 days uptime) with `sysDescr`, `sysName` and
  raw uptime ticks all parsed correctly. Only that one device answered on
  the network tested — other hosts either have SNMP disabled (a common
  default) or use a non-default community. Restart and software-change
  event generation is logic-verified but has *not* been observed against a
  real device reboot or firmware upgrade yet.
- **Overall status (menu bar color)**: `OverallStatus` reduces everything
  down to one at-a-glance signal on the menu bar icon itself — green
  (normal), yellow (marginal), or red (critical) — verified against 10
  severity scenarios (interface down overriding everything, each of
  router/IP/DNS/HTTP failing alone, a LAN device failing alone, and
  critical+marginal failing together; predates the ISP edge router ping
  joining `criticalLabels`, not independently re-verified since). **Critical**
  (red): the interface is down, or router/IP/DNS/HTTP/ISP-edge-router is
  unreachable — these mean the network is actually broken. **Marginal**
  (yellow): a monitored LAN device (not the router) is unreachable —
  worth noting, not itself a real problem.
  **Normal** (green): everything else. `NMSApp` computes this from
  `networkMonitor.currentInterface` and `connectivity.checks`. Getting the
  color to actually show up took a second pass: a plain SwiftUI `Image`
  with `.foregroundStyle` inside `MenuBarExtra`'s label renders as a
  monochrome "template" image regardless of the color — confirmed by
  testing it directly, no color appeared at all. The fix,
  `NMSApp.statusIcon`, rasterizes the SF Symbol into an `NSImage` and
  explicitly sets `isTemplate = false`, which is what actually bypasses
  that. Verified by screenshotting the real menu bar (`screencapture`) with
  the app running vs. quit and diffing the two — a green `cable.connector`
  icon was present only while running, confirming both that it's genuinely
  our icon and that it renders in actual color, not monochrome.
- **Path to internet / ISP edge router**: `TracerouteService` shells out to
  `/usr/sbin/traceroute` (setuid root on macOS — same free ride as
  `arp`/`ping`) with `-q 1` (one probe per hop) specifically to keep output
  at one line per hop; the default 3-probes-per-hop mode can print multiple
  differing hosts under ECMP load balancing, spanning multiple lines,
  which isn't worth parsing for what this app needs. `IPClassifier`
  classifies each hop's address as RFC 1918 private or not (verified
  against the actual boundary cases: 172.16/172.32 range edges, and
  100.64.0.0/10 CGNAT — not RFC 1918, so correctly treated as "internet"
  per the private/internet split this app uses). `suggestedEdgeHop` is
  **the first hop that isn't RFC 1918** — a starting suggestion, not an
  auto-trusted answer: it's correct for a simple single-NAT home network
  (verified directly — ran a real traceroute, got `10.0.0.1` (hop 1,
  private) → `75.101.33.52` / `lo0.bng3.snfcca05.sonic.net` (hop 2,
  public) → …, exactly as expected), but on a campus/enterprise network
  the organization's own border router often already has a public IP long
  before traffic actually reaches the ISP, so "first non-private hop"
  would misidentify *your own* infrastructure as "the ISP." Rather than
  guess further with something like ASN/WHOIS lookups (an external
  dependency with its own reliability/rate-limit tradeoffs), the popover
  lets you confirm the real hop yourself — tap ★ next to any hop in the
  list to designate it "the one to monitor" (persisted across launches via
  `UserDefaults`, independent of the SwiftData store). Until you confirm
  one, nothing is persisted to `ProviderEdgeRecord` at all — verified
  directly (fresh store, no confirmation, zero rows) — only the suggestion
  displays. Once confirmed, `TracerouteViewModel` looks up that hop by
  position on every subsequent trace and persists a `ProviderEdgeRecord`
  row only when its address actually changes (mirrors `PublicIPRecord`).
  `TracerouteViewModel` runs at launch, after every observed topology
  change (the path can change along with the network), every 10 minutes
  (traceroute is much heavier than a ping or HTTP lookup — up to 20 hops,
  each potentially waiting out a timeout — so it runs far less often than
  connectivity checks), and on the popover's "Trace Now" button. **This
  view model is deliberately discovery-only** — finding the path and
  letting you confirm which hop is the ISP edge — not ongoing health
  monitoring of that hop. Re-running a full multi-hop trace on a fast
  cadence just to check whether one already-known address still responds
  turned out to be both slow and the wrong tool for the job (see
  "Connectivity testing" above): actual monitoring of the confirmed hop is
  a plain ping, run by `ConnectivityViewModel` on the same fast/reactive
  cadence as router/internet/DNS/HTTP (`OverallStatus.peRouterLabel`;
  failures/recoveries log `peRouterUnreachable`/`peRouterReachable`
  events, same as the other three). `ContentView`'s star-button handler
  calls `connectivity.runChecks()` right after confirming or clearing a
  hop, so the new ping target takes effect immediately rather than waiting
  up to 30s. This split was prompted by a real gap: disabling an
  *upstream* switch (between the local router and the ISP, not the Mac's
  own interface) doesn't change the Mac's interface/IP/router at all, so
  `onChangePersisted` above never fires for it, and re-tracing only every
  10 minutes made that kind of outage slow to notice. `ConnectivityViewModel
  .onInternetUnreachable` fires specifically when the raw IP check (ping
  to `1.1.1.1`) transitions to unreachable — not router/DNS/HTTP, and not
  recoveries — and `NMSApp` wires that straight to an immediate
  `traceroute.run()`, since a real path change (not just the same hop
  going quiet) still needs a fresh trace to detect, and that's the
  earliest signal something broke upstream. Once a hop is confirmed, the
  Path to
  Internet section just shows a "Stop monitoring hop N" button plus the hop
  list (local hops greyed out, the confirmed hop in blue, unresponsive hops
  shown as "no response") — it used to also show a separate "ISP Edge
  Router: <hostname>" summary row above that, but that was purely
  redundant with the same hop's starred row right below it in the list,
  so it was cut as a spare line. Before confirmation (just a suggestion),
  the equivalent summary row is still shown, since there's no starred row
  yet to fall back on. `ContentView.displayedHops` hides everything beyond
  it — hops further toward the actual destination (e.g. `1.1.1.1`) aren't
  relevant to "the path to my ISP" once you've told the app which one that
  is. Before confirmation, the full path still shows, since you need to
  see hops beyond the auto-suggested one to pick a different, correct one
  on networks where the suggestion doesn't hold.

## Notes on network identity

Recognition depends on resolving the router's MAC via ARP, which needs a
moment to populate right after connecting — if a topology-change scan
fires before the OS has ARP-resolved the gateway, that round is silently
skipped (recognition state just doesn't update yet) rather than guessing.
In practice the manual "Scan" button or the next automatic scan picks it
up. This can't misfire (there's no incorrect data), it can only be
momentarily stale.

## Suggested next steps (in order)

1. **A history view** — everything so far only surfaces the *current*
   state in the popover (the event log is the one exception — it's
   inherently historical). All the other persisted tables
   (`NetworkSnapshot`, `DiscoveredDeviceRecord`, `BonjourDeviceRecord`,
   `ConnectivityCheckRecord`, `KnownNetwork`, `PublicIPRecord`) are sitting
   there unused for anything but live display and correlation math; a
   simple timeline/list view (including a browsable, labelable list of all
   known networks, not just the current one) would make the persistence
   layer actually useful day-to-day.
2. **Smarter correlation** — the current heuristic is pure time-proximity
   with a fixed 90s window. Consider tightening it (e.g. only correlate a
   failure with the *nearest* snapshot, not "any within window") or
   widening it adaptively based on how often changes happen.
3. **A ping sweep before ARP discovery** — `LANDiscoveryService` still only
   sees hosts already in the ARP cache; actively pinging the subnet first
   would populate it with devices that haven't been talked to recently,
   complementing Bonjour discovery (which only finds devices that
   advertise a service, not silent ones).

## Notes on sandboxing

`ConnectivityService` shells out to `/sbin/ping` for real ICMP round-trip
latency, chosen over `Network`-framework TCP probes for accurate numbers
and consistency with `LANDiscoveryService`'s `arp -a` approach.
`TracerouteService` shells out to `/usr/sbin/traceroute` for the same
reason. Combined, this means the app **cannot be sandboxed as-is** — raw
ICMP / process-spawning aren't available under the App Sandbox, which is
why `ENABLE_APP_SANDBOX` is explicitly set to `NO` in the target's build
settings (Xcode's App template defaults new projects to sandboxed). If Mac
App Store distribution becomes a goal, swap `ConnectivityService`'s
implementation for `NWConnection`-based TCP reachability (connect-time
instead of true ping latency, but sandbox-safe), `LANDiscoveryService` for
`NWBrowser`-based Bonjour discovery, and drop or reimplement traceroute
(there's no sandbox-safe equivalent — it fundamentally needs raw ICMP/UDP
with TTL control), rather than trying to sandbox the `arp`/`ping`/
`traceroute` shell-outs directly.

## Signed and notarized releases

`script/release.sh` produces a universal, Developer ID-signed, notarized,
stapled `NMS.app` plus a `ditto` zip ready to publish. Without this, anyone
you hand a build to hits a Gatekeeper block on first launch — which is a
particularly bad first impression for an unsandboxed tool that scans their
network.

Two one-time prerequisites, both local to your machine; **neither is stored
in this repository**, and the script references only the keychain profile
*name*, never a secret.

**1. A "Developer ID Application" certificate.** Xcode → Settings →
Accounts → select your team → Manage Certificates… → **+** → *Developer ID
Application*. Confirm with:

```bash
security find-identity -v -p codesigning
```

**2. Notarization credentials in a keychain profile.** An App Store Connect
API key is preferable to an app-specific password — it's scoped and
revocable. Generate one at App Store Connect → Users and Access →
Integrations → Keys, then:

```bash
xcrun notarytool store-credentials "NMS-notary" --key ~/private_keys/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
```

Then, for each release:

```bash
./script/release.sh
```

It checks both prerequisites before starting, since a missing certificate
otherwise surfaces as an opaque `xcodebuild` failure several minutes into
the archive. Then it archives universal, exports signed, submits to Apple
and waits, staples the ticket, and verifies the result three ways —
`codesign --verify`, `spctl -a -t install` (what Gatekeeper will actually
do on someone else's Mac), and `stapler validate`. Notarization typically
takes a few minutes.

`NOTARY_PROFILE`, `TEAM_ID`, and `BUILD_DIR` can be overridden by
environment variable; the Team ID is otherwise read from the installed
certificate.

Note that the stapled ticket is written into the bundle, so the zip has to
be rebuilt *after* stapling — the archive submitted to Apple doesn't
contain the ticket. The script handles this, but it's an easy step to miss
when doing it by hand, and the symptom (Gatekeeper still complains, but
only when offline) is confusing.

## Network activity and privacy

Nearly everything the app does stays on the local network: `arp -a`,
Bonjour browsing, SNMP GETs to LAN devices, and ping/traceroute to the
targets you configure. Persistence is local SwiftData; nothing is uploaded
anywhere. Two checks do leave your network, both on a timer rather than
on demand:

- **`https://api.ipify.org`** — public-IP lookup, used to detect WAN
  address changes. This necessarily reveals your public IP to a third
  party; review [ipify's terms](https://www.ipify.org/) if that matters to
  you. `PublicIPService` holds the endpoint in a single constant and is
  straightforward to repoint at your own service.
- **`http://captive.apple.com/hotspot-detect.html`** — captive-portal
  detection, the same endpoint macOS itself uses. Plain HTTP is
  deliberate: a captive portal is detected precisely by its interception
  of the response, which TLS would prevent.

SNMP community strings you enter are stored with the app's other
configuration rather than in the Keychain. That's a deliberate call —
they're shared, read-only, and usually the well-known default (`public`) —
but if you use SNMP v2c community strings as a real access control on your
network, be aware they aren't protected at rest here.

## Contributing

Issues and pull requests are welcome. There's no CLA and no formal style
guide; matching the surrounding code is enough.

Two workflows run on every push and PR, and weekly on a schedule:

- **CodeQL** (`.github/workflows/codeql.yml`) — static analysis for Swift.
  Runs on a macOS runner and builds the target directly, since this
  project has no shared scheme.
- **gitleaks** (`.github/workflows/gitleaks.yml`) — scans full history for
  committed secrets. Free for public repositories.

## License

[MIT](LICENSE) © 2026 Paul Jorgensen.

The app has no third-party dependencies — everything it uses is an Apple
system framework (SwiftUI, SwiftData, Network, CoreLocation) or a standard
macOS command-line tool invoked at runtime (`ping`, `traceroute`, `arp`,
`snmpget`). So there are no bundled third-party licenses to comply with.
