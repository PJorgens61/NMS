# NMS

macOS network management app — discovers the local LAN, tests connectivity
to local and internet targets, persists history, and correlates problems
with environment changes.

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
│   │   └── BonjourDeviceRecord.swift      # SwiftData model, persisted per-snapshot Bonjour list
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
│   │   └── BonjourDiscoveryViewModel.swift  # Bridges BonjourDiscoveryService -> SwiftUI
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

Requires macOS 14+ (for `SwiftData`; `MenuBarExtra` itself only needs 13+)
and Xcode 15+.

**Three non-default project settings, all load-bearing — don't "fix" them
back to template defaults:**
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
  **DNS** (`DNSResolutionService` resolves `apple.com` via the POSIX
  `getaddrinfo` call — a real system-resolver lookup, isolated from any
  other network I/O), and **HTTP** (`HTTPCheckService` fetches Apple's own
  captive-portal probe, `http://captive.apple.com/hotspot-detect.html` —
  deliberately plain HTTP, not HTTPS, since captive portals intercept port
  80 to inject their redirect — and checks for its known 200/"Success"
  response). All three verified directly: real DNS resolution of
  `apple.com`, a real captive-portal-probe fetch, both against actual
  network traffic, both succeeding with real latency numbers.
  `ConnectivityViewModel` runs a round of checks every 30s — router, up to
  2 currently-known LAN devices, IP, DNS, HTTP — plus once at launch and on
  demand via the popover's "Check Now" button. Ping and DNS resolution
  block for up to a couple of seconds each, so they run on a background
  queue; the HTTP fetch is genuinely async and doesn't need that. Checks
  aren't tied to a `NetworkSnapshot` by relationship — correlation (below)
  matches them up by comparing timestamps instead.
- **Correlation**: `CorrelationService` flags a connectivity failure as
  `correlatedWithChange` when it lands within 90 seconds (either
  direction) of some `NetworkSnapshot.capturedAt` — a coarse
  time-proximity heuristic, not causal proof. `SnapshotStore` computes
  this at write time (only for failures; successes are never flagged) and
  looks back over the last 50 snapshots. The popover shows correlated
  failures in orange with a `*`, plain failures in red.
- **Network recognition**: `KnownNetwork` fingerprints a network by its
  gateway's MAC address (not SSID — see "Notes on network identity"
  below), since MAC survives DHCP lease changes and IP/subnet coincidences
  across genuinely different networks (many home routers default to the
  same `192.168.1.1`). `NetworkIdentityViewModel.recognize` runs after
  every LAN scan (it needs that scan's ARP data to find the router's MAC),
  looks up or creates the matching `KnownNetwork`, and bumps its
  `timesSeen`/`lastSeenAt`. The popover shows "New network" vs "Known
  network (seen N×)" and a text field to give it a friendly label (e.g.
  "Home") — that label round-trips through `SnapshotStore.setLabel`.
- **Public IP tracking**: `PublicIPService` asks `api.ipify.org` (a no-auth,
  plain-text "what's my IP" endpoint — there's no way to learn your
  WAN-facing address purely locally, since it's whatever your network's
  NAT/router presents to the internet) and `PublicIPViewModel` checks
  every 5 minutes, once at launch, right after every observed topology
  change (the likeliest moment it'd actually change), and on the popover's
  "Refresh" button. Like `NetworkSnapshot`, `SnapshotStore` only persists a
  `PublicIPRecord` row when the IP actually changed — a change timeline,
  not a per-check log.
- **Wi-Fi network name (SSID)**: `WiFiSSIDService` reads the SSID via
  CoreWLAN, gated behind Core Location authorization
  (`LocationAuthorizationService`) — macOS treats Wi-Fi network names as
  location-sensitive since they can be reverse-geocoded via
  SSID-to-location databases, so there's no way to read this without a
  location permission grant (confirmed directly: even
  `system_profiler SPAirPortDataType`, a command-line tool, redacts the
  SSID without it). `WiFiSSIDViewModel.refresh` runs at launch, after
  every observed topology change, and on manual "Refresh." The popover's
  top row shows, in order of preference: your manual label (if you've set
  one) → the live SSID (if on Wi-Fi and authorized) → the generic
  interface name. The label text field's placeholder also suggests the
  live SSID as a starting point instead of "Home" when one's available.
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
  at all — not around ordinary network-to-network switches, which aren't
  outages and are already visible via network recognition/labeling.
  `interfaceDown` was previously silently dropped entirely (the old code
  only handled "now have an interface," never "now have none"), so that
  transition never appeared in any persisted history until this feature
  added the missing branch. `ConnectivityViewModel` logs
  `routerUnreachable`/`internetUnreachable`/`dnsUnreachable`/
  `httpUnreachable`/their recovery counterparts by comparing each check
  round against the previous one, per-label. Both post through
  `onEventLogged` callbacks so `EventLogViewModel` can refresh. The popover
  shows recent events in a fixed-height (~10 rows), scrollable list —
  recoveries in green, bad states in red — with timestamps.
- **Overall status (menu bar color)**: `OverallStatus` reduces everything
  down to one at-a-glance signal on the menu bar icon itself — green
  (normal), yellow (marginal), or red (critical) — verified against 10
  severity scenarios (interface down overriding everything, each of
  router/IP/DNS/HTTP failing alone, a LAN device failing alone, and
  critical+marginal failing together). **Critical** (red): the interface
  is down, or router/IP/DNS/HTTP is unreachable — these mean the network
  is actually broken. **Marginal** (yellow): a monitored LAN device (not
  the router) is unreachable — worth noting, not itself a real problem.
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
  each potentially waiting out a timeout — so it runs far less often), and
  on the popover's "Trace Now" button. The popover shows the confirmed (or
  suggested) edge router plus the hop list — local hops greyed out, the
  confirmed hop in blue, unresponsive hops shown as "no response." Once a
  hop is confirmed, `ContentView.displayedHops` hides everything beyond
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
