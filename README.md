# NMS

A macOS menu bar network monitor for small networks and home labs —
automatically discovers LAN devices, your ISP's edge router, and your
public IP, monitors Internet connectivity at every layer from interface
to HTTP, persists the history, and correlates outages with the changes
that preceded them.

> **Status: early.** This is a personal project, published so other people
> can try it — not a finished product. It works against the hardware and
> network it was developed on; expect rough edges elsewhere. There's no
> support commitment and no stability guarantee, and because the SwiftData
> models have no migration path yet, a schema change may mean deleting
> accumulated history to get the app to start again.
>
> **The `v0.1.0` download is ad-hoc signed, so Gatekeeper rejects it**
> (confirmed with `spctl -a -t install`). To run it anyway: right-click
> `NMS.app` → Open, or `xattr -cr` the copy you installed.
> `script/release.sh` (see "Signed and notarized releases" below) would
> avoid this, but needs a paid Apple Developer Program membership that
> isn't currently active on either machine this project runs on — so for
> now, ad-hoc-plus-workaround is the actual distribution path, not a
> temporary gap this predates.

A user-facing walkthrough of the popover — install, permissions, what each
section means, and common troubleshooting — is published via GitHub Pages
at **[pjorgens61.github.io/NMS/user-guide.html](https://pjorgens61.github.io/NMS/user-guide.html)**
(source: [`docs/user-guide.html`](docs/user-guide.html), served straight
from this repo's `main` branch — no separate deploy step, just push).

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
│   │   ├── LANDiscoveryService.swift      # Enumerates LAN devices via `arp -n -a`
│   │   ├── ConnectivityService.swift      # Pings a target via `/sbin/ping`
│   │   ├── CorrelationService.swift       # Time-proximity failure/change matching
│   │   ├── PublicIPService.swift          # Looks up WAN IP via api.ipify.org
│   │   ├── LocationAuthorizationService.swift  # Requests Core Location auth (for SSID)
│   │   ├── WiFiSSIDService.swift          # Reads current Wi-Fi SSID via CoreWLAN
│   │   ├── IPClassifier.swift             # RFC 1918 private-address classification
│   │   ├── SubnetCalculator.swift         # IPv4 subnet host enumeration (with a size guard)
│   │   ├── SNMPService.swift              # SNMP GET/sweep via /usr/bin/snmpget
│   │   ├── TracerouteService.swift        # Walks the path via `/usr/sbin/traceroute`
│   │   ├── ReverseDNSService.swift        # PTR lookup via `getnameinfo`, enriches hops after the fact
│   │   ├── DNSResolutionService.swift      # Resolves a hostname via `getaddrinfo`
│   │   ├── HTTPCheckService.swift         # Real HTTP fetch via Apple's captive-portal probe
│   │   ├── OverallStatus.swift            # Menu bar severity: normal/marginal/critical
│   │   ├── BonjourDiscoveryService.swift  # Browses/resolves Bonjour (mDNS) services
│   │   ├── UIStateLogger.swift            # DEBUG-only log of every value pushed into the UI
│   │   ├── SubprocessTracer.swift         # DEBUG-only trace of every shelled-out command
│   │   ├── StoreInspector.swift           # DEBUG-only plain-text dump of every SwiftData table
│   │   └── BuildInfoService.swift         # Reads git HEAD from the known checkout for the popover footer
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
   current interface, IP, subnet, router, DNS server, and public IP.

The popover is arranged top to bottom as: **Network Health**, **Info**
(the interface/IP/subnet/router/public-IP details — this section used to
be titled "NMS"), **Path to Internet**, and **Speed Test**, tiled in a
2-column grid (each its own bordered box — see "Popover layout: tiled
short sections" below) since the first three are short label/value lists
that looked sparse stretched across the full popover width, and Speed
Test's own content (a data-cost note plus a handful of Mbps/timestamp
rows) fit the same half-width shape well; then, full-width below the
grid, **DHCP History**, **Events**, and **SNMP Devices** (this section
was originally titled "Infrastructure"), then Refresh/Quit. There's no
separate Connectivity section anymore — its raw IP-layer check was
folded into Network Health, and the rest of what it showed was already
covered there too. The scrollable list for Path to Internet is
deliberately short (60px, ~3 visible rows) to leave room for everything
else to fit in the popover's limited vertical space.

**Popover layout: tiled short sections.** Widening the popover for the
DHCP History section (see below) left Network Health, Info, and Path to
Internet with wide, pointless gaps between labels and values — short
content stretched across a now-much-wider popover. `ContentView.tile(
title:trailing:content:)` wraps each in a bordered box (`RoundedRectangle`
`.strokeBorder`, replacing the plain `Divider()` those three used to sit
between), arranged via a 2-column `LazyVGrid`
(`ContentView.tileColumns`). Three tiles in a 2-column grid initially left
the second cell of the second row empty; Speed Test (added afterward)
filled it directly rather than becoming its own full-width section,
confirming the empty cell really was a ready-made slot and not just
incidental. Its rows needed their own pass to fit that half-width,
though: a first attempt wrapped each run to two lines (mirroring DHCP
History's fix for the same squeeze), but turned out to be overcautious —
"↓ 765 Mbps  ↑ 173 Mbps" plus a time-only (no date) timestamp fits one
line at this tile's width fine, confirmed directly against a real
screenshot rather than assumed either time. The popover's own width
(`.frame(width: 560)`) went through two more values before landing here:
335pt originally, then 670pt for a first attempt at showing a DHCP
lease's full detail as one unbroken line, then back down to 560pt once
that line wrapped to two instead (its width need dropped from
~950-1000pt to ~440pt) — 670pt at that point was just carrying 670pt's
worth of dead space for no reason.

**LAN Devices and Bonjour Devices are hidden** (their view code was
removed, not just collapsed) — even after every other space-saving pass
in this app's history, the popover was still too tall for a 13" MacBook
screen. `LANDiscoveryViewModel`'s scan keeps running exactly as before:
it's cheap (`arp -a`, no network I/O beyond reading the kernel's table)
and still feeds network recognition (the router-MAC fingerprint) and
`SNMPViewModel`'s discovery candidates, independent of whether its list
displays anywhere. `BonjourDiscoveryViewModel`'s launch-time scan, by
contrast, no longer runs at all: with its UI gone, its only remaining
consumer was also SNMP candidate-sourcing, but Bonjour only ever finds
link-local/same-subnet devices — exactly the address space `SNMPService`'s
own subnet sweep already covers directly — so several real seconds of
mDNS scanning was buying nothing once it wasn't for display. Neither
service was deleted, just no longer driven automatically, so either
section could come back by re-adding its view code.

**A clean build emits four concurrency warnings, and that's expected.**
They're documented individually in DESIGN-NOTES.md's "The four remaining
concurrency warnings" — three are code that deliberately runs off the
main thread inheriting `@MainActor` isolation from an enclosing type,
and one is a SwiftData model captured (but never dereferenced) across a
thread hop. None carries the "this is an error in the Swift 6 language
mode" marker; the thirteen that did have been fixed. If you see more
than four, something changed.

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
`xattr -cr /Applications/NMS.app` after copying it over. `script/release.sh`
would skip this entirely, but see "Signed and notarized releases" below —
it currently needs a paid Apple Developer Program membership that isn't
active on either machine this project runs on, so ad-hoc-plus-workaround
is the real path for now. Note also that the SNMP community list lives in
`UserDefaults`, so it does *not* travel with the app bundle — it has to be
set again on each
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
Separately, if the Bonjour Devices section is ever re-added and scanning
resumes, the first scan will prompt for Local Network access — declining
just leaves that section empty, everything else keeps working. Because
local Xcode debug builds are ad-hoc signed (no stable Developer ID),
macOS may treat each rebuild as a "new" app and re-prompt for both —
expected during development, not a bug.

## What's implemented

- **`SystemConfigurationService`**: reads the current primary interface
  (name, friendly display name, IP, subnet mask, router, DNS server,
  Wi-Fi vs. Ethernet) and can register a callback that fires on network
  changes (interface up/down, IP change, Wi-Fi network switch). The DNS
  server comes from `State:/Network/Global/DNS`'s `ServerAddresses` —
  verified directly against `scutil --dns`'s own resolver #1
  `nameserver[0]` to confirm this is macOS's actual effective primary
  resolver, not a possibly-stale `/etc/resolv.conf` stub. A DNS server
  change is treated as a real topology change for change-detection
  purposes (`NetworkInterfaceInfo`'s `==`), the same as a router change —
  some networks hand out a different upstream resolver via DHCP
  independent of the router's own address, and a VPN can override this
  with its own split-DNS server.
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
- **LAN device discovery**: `LANDiscoveryService` shells out to `arp -n -a`
  and parses the kernel's ARP cache into `DiscoveredDevice` values
  (IP, MAC, hostname, interface). This surfaces hosts the
  Mac has already exchanged traffic with — it's not an active subnet scan.

  **`-n` is load-bearing, and the scan runs off the main thread.** Both came
  out of a real beachball: the menu bar hung with the main thread blocked in
  `readDataToEndOfFile`, and the child `/usr/sbin/arp -a` still running after
  nearly four minutes. Without `-n`, `arp` does a reverse lookup per entry
  *inside the subprocess*, where nothing here can bound it — and mDNS
  `.local` reverse queries have no fast negative answer, so a missing
  responder costs a full timeout each. Started during a network transition,
  that wedged indefinitely. Same failure mode, same fix as `TracerouteService`
  running with `-n`. `LANDiscoveryViewModel.scan` also now dispatches to a
  background queue rather than calling the service inline on `@MainActor`;
  it was the only view model doing subprocess work synchronously on the main
  thread, while SNMP, traceroute and connectivity all already dispatched.
  Hostnames come back afterward through `ReverseDNSService` (which has its
  own timeout) in `enrichHostnames`, mirroring the traceroute path —
  verified end to end: a scan returns five devices unnamed, and enrichment
  restores all five names, mDNS and `/etc/hosts` alike, within ~52ms.
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
  few seconds total (windows run in parallel across service types) — not
  tied to every topology change the way the near-instant ARP scan is, and
  since the popover's own Bonjour Devices section and "Scan" button were
  later hidden (see "Running it" above), nothing currently triggers this
  scan automatically at all; `BonjourDiscoveryViewModel.scan()` still
  works if called. Requires the `NSLocalNetworkUsageDescription`
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
  Network → Local Router → Public IP → ISP Edge Router → Internet Ping by
  address → DNS → HTTP. Network and the chain's original separate Interface row
  used to be two rows, but checked almost the same thing — Interface was
  a pure up/down signal (`info != nil`), and Network's own status matched
  that exactly except in one case (Wi-Fi with no name resolvable at all,
  where the interface is genuinely up but *which* network it is remains
  unknown) — so they're combined into one row now, reusing
  `networkDisplay(_:)` (built for the Info section's equivalent combined
  row, e.g. "Thistle Wi-Fi") for the detail text.

  The raw IP-layer check (ping to `1.1.1.1`) used to only appear in the
  separate Connectivity list; it's now folded in here as its own layer
  between ISP Edge Router and DNS, and the standalone Connectivity
  section was removed from the popover since Network Health already
  covered everything else it showed. Labeled "Internet Ping by address"
  specifically, not just "Internet" — `ConnectivityViewModel.internetHost`
  is a literal `"1.1.1.1"`, never a hostname, so no DNS resolution happens
  for this specific check at all, unlike the DNS/HTTP layers right above
  it. Worth being explicit about given how easy those three are to
  conflate.

  **Local interference is not reported as an outage.** Twice in one day
  every ICMP probe timed out during a clean Xcode build while DNS and HTTP
  stayed green, recovering a second later — each writing a complete,
  fictional outage into the event log. `ConnectivityViewModel
  .isLikelyLocalPingFailure` now catches that signature: if the
  path-critical pings (Router, Public IP, ISP Edge Router, Internet) all
  fail while DNS or HTTP succeeds, the network is demonstrably up, because
  DNS resolves a *random* subdomain to defeat caching and HTTP fetches a
  real remote host. Traffic reaching a remote host means it traversed the
  very hops reporting ICMP unreachable — a contradiction, not a finding.

  Such a round no longer writes transition events or accelerates the
  cadence. The measurements are still persisted: they really happened, and
  the sparklines should show them. What's suppressed is the *claim* that
  they represent a network outage.

  Only the path-critical pings need to fail, not every ping —
  infrastructure devices are excluded in both directions, since a working
  network says nothing about whether an AP or printer is powered on. The
  stricter first version required all of them, and missed the realistic
  case where a genuinely-off printer kept its own check failing and thereby
  blocked detection.

  **Each round records CPU load** (`SystemLoadService`, via `getloadavg` —
  a libc call, deliberately not a subprocess, since shelling out to
  diagnose *subprocess starvation* would stall under the very condition
  it's detecting). Normalized by core count so 1.0 means "as many runnable
  processes as cores" and the figure compares across machines. Persisted on
  every `ConnectivityCheckRecord`, which is worth ~8 bytes on the store's
  largest table because it answers the question that turned two apparent
  outages into a diagnosis: *was the Mac pinned when every ping timed out?*

  Load corroborates, never triggers — a busy Mac is not evidence the
  network is fine, and suppressing real outages because someone was
  compiling would be worse than the bug being fixed. It distinguishes the
  two causes of an identical symptom: elevated load means starved ping
  subprocesses, normal load means ICMP is likely blocked somewhere. Caveat
  worth knowing: load average is a one-minute rolling figure, so an
  isolated one-second spike barely registers — fine for the observed
  incidents, which spanned multi-minute builds.

  **Latency sparklines**: each of the six rows backed by a real timed
  probe (Router, Public IP, ISP Edge Router, Internet, DNS, HTTP) carries
  an inline sparkline of its last 30 checks. Network and Interface don't
  — they're connectivity/identity state with no latency concept.

  Sized to one line of text so it costs width but *no height*, which is
  the constraint that shaped it: the popover fits a 13" MacBook Air
  exactly. Data comes from `SnapshotStore.fetchLatencyHistory`, bounded
  by `fetchLimit` rather than by slicing in Swift — `ConnectivityCheck
  Record` is ~90% of the store, so fetching a label's whole history to
  take the last 30 would cost more every day the app runs. Loaded from a
  `.task` when the section appears rather than maintained continuously,
  since the popover is shut almost all the time.

  **Failures are drawn, not smoothed.** A failed check has `latencyMs ==
  nil`; interpolating across it would render an outage as a *faster*
  response than normal. Instead the line breaks at failures and each one
  gets a red mark along the bottom. Each layer scales independently too —
  Public IP's sub-millisecond wobble and DNS's occasional 60ms+ spike
  can't share an axis without flattening the former into a dead line.

  Hand-drawn with `Canvas` rather than Swift Charts, deliberately: this
  app has been caught out by `ImageRenderer` four times (see "Screenshot
  button"), and a charting framework is a much bigger unknown in that
  renderer than a `Path` — for auto-scaling that's three lines of
  min/max. Verified by capturing the result; they render correctly.

  **Public IP row**: pings the router's own public/WAN address (whatever
  `PublicIPViewModel.currentIP` currently holds), not a remote host — a
  request from the user, who correctly identified that a router's WAN
  interface is typically the demarcation point to the ISP's cable
  modem/ONT, so a check specifically targeting it can catch things a
  LAN-side-only check (the Local Router row) can't, like the ISP device
  itself losing power. Verified directly before implementing, since
  pinging your own public IP from inside your own LAN has a real, common
  failure mode: many routers/ISPs disable responding to ICMP on the WAN
  interface by default, which would make a check like this always fail
  regardless of the ISP device's actual state. On this network it works —
  confirmed `ttl=64` and sub-millisecond round-trip time, meaning the
  gateway answers locally (recognizing the destination as its own
  address) rather than the packet actually leaving and returning across
  the internet — but this isn't guaranteed on every network, and there's
  no way to detect "ICMP is disabled on the WAN side" versus "the
  interface is genuinely down" from inside the LAN; both look identical
  as a plain timeout. 1s timeout (like the Local Router row), since a
  locally-answered ping should be at least as fast, not slower. Skipped
  entirely (not attempted) whenever `PublicIPViewModel` hasn't resolved an
  address yet — shows "Not checked" (`.unknown`), not a failure, since
  there's nothing to ping until that lookup completes. New
  `AppEventKind` pair, `publicIPUnreachable`/`publicIPReachable`,
  distinct from `publicIPChanged` (that's the address *changing*, not a
  ping to whatever it currently is). The ISP Edge Router row
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
  event ("Public IP changed to \<new address\>" — just the new value, not
  "from X to Y", to keep it short enough to fit on one line), except on
  the very first-ever check (nothing to compare against yet). Verified
  directly: seeded a fake "previous" IP in the database, let the app
  fetch the real one on launch, and confirmed both the new
  `PublicIPRecord` and the correctly-worded event were written. Separate
  from this address-*change* tracking, Network Health's own Public IP row
  (see "Network Health" above) pings whatever this address currently is,
  on `ConnectivityViewModel`'s normal cadence — two different concerns
  about the same value, not overlapping features.
- **DHCP lease tracking**: `DHCPLeaseService` shells out to `/usr/sbin/
  ipconfig getpacket <interface>` — a purely local read of the last
  successful lease `configd` already has cached, not a live probe of the
  DHCP server, so it costs no network I/O and can't disrupt the live
  connection the way forcing a fresh negotiation would. Explored in depth
  (including the real output format, verified directly rather than assumed
  from documentation — e.g. `lease_time (uint32): 0x15180`, a raw hex
  `uint32`, not the human-readable duration some descriptions imply) in
  DESIGN-NOTES.md's "DHCP lease tracking" before this was written.

  **What's tracked**: server identifier, assigned address, subnet mask,
  broadcast address, router, DNS servers, DNS search domain, lease/T1/T2
  timings, and the DHCP transaction ID (`xid`). `SnapshotStore.
  recordDHCPLeaseIfChanged` persists a new `DHCPLeaseRecord` only when the
  transaction ID actually changes — same transaction always means the
  same lease content by protocol definition, so comparing just that one
  field is a cheaper and sufficient check for whether to persist a new
  history row. The popover's **DHCP History** section lists every real
  change, newest first; the newest row doubles as "the current lease," so
  there's no separate current-lease display.

  **`.dhcpLeaseChanged` events say what actually changed**, not just that
  a renewal happened: `DHCPLeaseViewModel.fieldChanges` compares every
  tracked field (excluding the transaction ID itself, which changes on
  every renewal by definition and would never be informative) against the
  previous lease, and only logs an event — one line per differing field,
  e.g. "gateway 10.0.0.1 → 10.0.0.2, DNS 10.0.0.1 → 8.8.8.8" — when at
  least one actually differs. A routine renewal that returns the exact
  same values logs nothing at all. Built specifically for spotting a
  change *someone else* made (an admin editing the DHCP scope, say) at
  the moment a problem is reported, rather than only being able to say a
  renewal occurred.

  **Two independent failure signals**, both explored non-disruptively
  before being written: (1) the interface falling back to a self-assigned
  APIPA address (`169.254.0.0/16`, via the new `IPClassifier.isLinkLocal`)
  means DHCP has genuinely failed, logged as `.dhcpFellBackToLinkLocal`/
  `.dhcpAddressRestored`; (2) the DHCP transaction ID failing to change
  past its own lease's T2 (rebinding) deadline means a renewal that should
  have started hasn't, logged as `.dhcpRenewalOverdue`/
  `.dhcpRenewalRecovered`. Signal 2's deadline is anchored to
  `DHCPLeaseRecord.firstObservedAt` — stamped only when a transaction ID is
  first seen — since `ipconfig getpacket` reports lease *durations*, never
  an absolute grant timestamp; a renewal that succeeds on schedule resets
  this anchor before the deadline is ever reached, so a healthy renewal
  never falsely alarms.
- **Speed Test**: `NetworkQualityService` measures throughput against
  Cloudflare's public speed-test backend (the same one behind
  speed.cloudflare.com) — plain `URLSession` HTTPS GET/POST, no account,
  no hosting, no subprocess. Verified directly before choosing a payload
  size: a 1MB download measured ~104 Mbps against a 25MB download's ~725
  Mbps on the same network at the same moment — a transfer that small
  finishes before TCP slow-start ramps up, so it mostly measures TLS
  handshake overhead, not sustained capacity. 25MB (both directions) is
  the minimum that produced a believable number. Download and upload run
  **sequentially, never concurrently** — running both at once would have
  them contend for the same pipe and understate both numbers, defeating
  the point of a speed test.

  Deliberately narrower than Apple's bundled `networkQuality` CLI (which
  also measures RPM/bufferbloat under load): this app measures throughput
  only, trading that signal away for no subprocess/macOS-version
  dependency. `NetworkQualityViewModel` has no timer and no automatic
  trigger of any kind, unlike every other view model in this app —
  `run()` only ever fires from the popover's "Run Speed Test" button,
  since a run costs a real, sizable transfer (~50MB round trip). A small
  "~50MB per run" label sits at the top of the Speed Test tile as an
  always-visible data-cost indicator instead of a confirmation dialog,
  the same low-friction pattern "Scan" and "Trace Now" already use.
  `NetworkQualityRecord` is
  persisted unconditionally per run (not "if changed" like `PublicIPRecord`/
  `DHCPLeaseRecord`) — every run is an intentional data point to compare
  against past ones, not a change to detect. Explored in full, including
  the two implementation candidates and the payload-size measurements
  above, in DESIGN-NOTES.md's "Network Quality" section before this was
  written.
- **Data retention**: `SnapshotStore.pruneIfNeeded` deletes rows older
  than 7 days from the three raw-observation tables —
  `ConnectivityCheckRecord`, `DiscoveredDeviceRecord`,
  `BonjourDeviceRecord` — and nothing else. That's where essentially all
  growth comes from: `ConnectivityCheckRecord` alone measured ~90% of all
  rows (one row per ping target per check round, ~3.5 MB/day), because
  it's the only table driven by a timer rather than by events. The
  change-logs are deliberately never pruned — `AppEventRecord`,
  `PublicIPRecord`, `DHCPLeaseRecord`, `NetworkSnapshot` and
  `NetworkQualityRecord` are small and their whole value is their age.

  Pruning runs from the write that causes the growth (a check round),
  throttled to at most hourly, rather than at launch or on a timer: a
  launch-only prune never fires on an app designed to run for weeks, and
  this way an idle app that writes nothing also cleans nothing. Note
  SwiftData's batch `delete(model:where:)` silently does nothing on
  models holding a relationship, so the two tables with a `snapshot`
  relationship are fetched and deleted individually — see
  DESIGN-NOTES.md's "No retention policy anywhere (measured)" for how
  that was found.
- **Screenshot button**: the camera icon next to Refresh renders the
  popover's own content directly to a PNG via `ImageRenderer` (not a real
  screen capture — no Screen Recording permission needed, and no risk of
  capturing anything outside the app's own window), saved to
  `~/Library/Logs/NMS/screenshots/NMS-<timestamp>.png` and logged as a
  `.screenshotCaptured` event naming the exact file, so it can be found
  by reading the event log rather than guessing which file on disk is
  the relevant one. Exists to remove a step this project's own
  development paid several times a session: manually screenshotting the
  popover and handing the file over.

  A capture is deliberately **more complete than the live popover**, not
  a mirror of it: `ContentView.isCapturingScreenshot` (a plain stored
  property, set on a throwaway struct copy — see DESIGN-NOTES.md for why
  `@Environment` doesn't work here) makes every scrollable section
  render as a plain unclipped list, so the image shows every SNMP device
  and all 10 fetched speed-test runs where the live view clips to ~4 and
  ~6. Events are the one exception, capped at 50 rows in a capture even
  though the popover itself scrolls back through 200: unclipped rows
  become image *height*, and the full fetch would render ~10,000px tall,
  which downscales to unreadable. Since being readable is the whole
  point, a legible window beats a complete but illegible one. The
  rendered copy also gets `.buttonStyle(.plain)` and an explicit
  `windowBackgroundColor` background, both working around
  `ImageRenderer` limitations documented in full (with how each was
  found) in DESIGN-NOTES.md's "Popover screenshot button".
- **Hover tooltips**: on the DHCP History detail line (which of `T1`/`T2`
  is renewal vs. rebinding, and what the trailing transaction ID means)
  and on each SNMP status dot — where the gray case is the one that
  needed explaining, since "not checked yet" and "down" look identical
  at a glance and get confused exactly when someone is scanning the list
  during an outage. Uses `ToolTip.swift`'s `appKitToolTip(_:enabled:)`,
  **not** SwiftUI's `.help(_:)`, which was spiked and renders nothing at
  all inside `MenuBarExtra(.window)`.

  **Adding a tooltip to anything that appears in a screenshot requires
  passing `enabled: !isCapturingScreenshot`.** `ImageRenderer` can't
  render an `NSViewRepresentable` and replaces the whole view with a
  broken-image placeholder, so a missing flag silently turns that element
  into a yellow block in every future capture while the live popover
  looks perfectly fine. See DESIGN-NOTES.md's "UI tooltips".
- **Wi-Fi network name (SSID)**: `WiFiSSIDService` reads the SSID via
  CoreWLAN, gated behind Core Location authorization
  (`LocationAuthorizationService`) — macOS treats Wi-Fi network names as
  location-sensitive since they can be reverse-geocoded via
  SSID-to-location databases, so there's no way to read this without a
  location permission grant (confirmed directly: even
  `system_profiler SPAirPortDataType`, a command-line tool, redacts the
  SSID without it). **Real bug, found and fixed**: the permission dialog
  could fail to appear at all — not denied, genuinely never shown, leaving
  `authorizationStatus` stuck at `.notDetermined` forever with no user
  action to recover from. Root cause: this app runs with `.accessory`
  activation policy (no Dock icon, never the foreground app) and requested
  authorization synchronously from `NMSApp.init()`, before AppKit's shared
  application instance was fully spun up — confirmed directly, an early
  fix attempt that called the bare `NSApp` global at that point crashed
  with a nil-unwrap. TCC permission prompts for a background/agent app
  that's never been foregrounded can fail to surface at all, which reads
  identically to "no prompt happened" from the user's side — worth knowing
  since it's easy to mistake for the (different, already-handled) case of
  the user actually clicking "Don't Allow." Fixed by dispatching to the
  next run-loop turn and calling `NSApplication.shared.activate(
  ignoringOtherApps: true)` (the lazy singleton, not the possibly-nil
  `NSApp` global) immediately before `requestWhenInUseAuthorization()`.
  Verified end-to-end on real hardware: prompt appeared, Allow was
  clicked, SSID resolved correctly afterward. `WiFiSSIDViewModel.refresh`
  runs at launch, after every observed topology change, and on manual
  "Refresh."

  **Moving between two Wi-Fi networks logs a `wifiNetworkChanged` event.**
  This was previously invisible: `interfaceChanged` only fires when the
  *physical* interface changes (Ethernet ↔ Wi-Fi), and roaming SSID-to-SSID
  keeps the same `en1`, so nothing in `NetworkInterfaceInfo` identified it —
  `handleObservedChange` persisted a snapshot and triggered scans but logged
  no event at all. Confirmed against a real session switching Thistle →
  ThistleGuest (which changed subnet, router *and* DNS server): the only
  events were a generic interfaceDown/interfaceUp pair that named neither
  network, and no event anywhere in the run mentioned either SSID.

  Only genuine named-to-named moves are logged. Joining from nothing is
  deliberately silent — `currentSSID` starts nil, so every launch on Wi-Fi
  would otherwise log a "joined" event reporting no change — and the
  Ethernet ↔ Wi-Fi direction is already covered by `interfaceChanged` on the
  same handoff. Comparison is against the last *known* SSID rather than the
  previous value of `currentSSID`, because that goes nil whenever Ethernet
  takes over: Thistle → Ethernet → Thistle is correctly silent, while
  Thistle → Ethernet → ThistleGuest is still reported. Verified against the
  transition rules directly, including a replay of the real session above.
  The "Info"
  section's top row shows, in order of preference: your manual label (if
  one is set some other way) → the live SSID (if on Wi-Fi and authorized)
  → the generic interface name.

  **BSSID and router fingerprint**: on Wi-Fi, `WiFiSSIDService.currentInfo()`
  reads the associated access point's own MAC address (`bssid()`) from the
  same `CWInterface` lookup used for the SSID — one call, so the two can't
  describe two different moments if the association changes in between. The
  Info section shows it as its own "BSSID" row, only when on Wi-Fi and a
  value is available (no dash-fallback row on Ethernet, to avoid clutter for
  a Wi-Fi-only property). Separately, the "Router" row now appends the
  gateway's MAC in parentheses — `192.168.1.1 (a1:b2:c3:...)` — sourced from
  `KnownNetwork.fingerprint`, the same value network recognition already
  uses as identity, once a LAN scan has resolved it this session; before
  that (or on a router whose MAC isn't yet known) the row still just shows
  the plain IP. Together these make a VRRP-style AP/router swap at an
  unchanged IP/SSID visible without cross-referencing the SNMP device list.
  Other Wi-Fi telemetry (RSSI, channel/band, PHY rate, security type) and
  Ethernet link speed/DHCP lease detail were considered alongside this and
  deliberately deferred — see "Deferred Wi-Fi/link telemetry" in
  `DESIGN-NOTES.md`.
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

  **Live reachability dot, not just Events.** Each device row in the SNMP
  Devices list carries a small colored dot (green/red/gray, matching the
  Network Health rows), sourced from `ConnectivityViewModel.checks` and
  matched by `displayName` (`ContentView.deviceReachability`) — the same
  ping data driving the Events log, just read directly instead of inferred
  from log order. That distinction matters because the two subsystems that
  report on a device can disagree about *when* to speak: the ping check can
  detect a recovery within 5s, while `poll()`'s restart detection only
  fires on its own 60s cadence and can log `snmpDeviceRestarted` *after*
  the matching `infrastructureReachable` recovery event for the same
  episode — confirmed directly from a real log, an 11-second gap between
  "BrotherLaserPrinter reachable again" and "BrotherLaserPrinter restarted
  unexpectedly" for one blip. Read by Events order alone, that looks like a
  fresh problem; the dot answers "is it up right now" without needing to
  interpret which event logged last.

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

  **"Scan" is a genuine clear-and-rediscover**, not just a fresh
  in-memory list layered on old rows: `SNMPViewModel.scan()` now calls
  `SnapshotStore.deleteAllSNMPDevices()` before sweeping, so a device no
  longer present doesn't linger in the persisted store and reappear on
  next launch (previously, only the *displayed* list was replaced on
  scan — the underlying `SNMPDeviceRecord` rows were never pruned, so
  stale entries survived indefinitely since `SNMPViewModel.init()`
  rehydrates from everything ever persisted). Real cost, accepted since
  this only runs on an explicit, manual click: any device still around
  gets a fresh `firstSeenAt` on rediscovery instead of keeping its actual
  history.

  **Devices from networks you've left are hidden, not deleted.**
  `SNMPViewModel.pruneStaleDevices` runs at launch and after every poll or
  scan, rebuilding the list from the persisted set and keeping only devices
  that belong to the network currently attached. The case that prompted it:
  joining a guest SSID discovered its gateway at `10.0.102.1`, and coming
  back to the main LAN left it listed forever alongside `10.0.0.1` — the
  same Alta router, identical `sysName` *and* `sysDescr`, showing up twice.

  **It hides rather than deletes for a reason learned the hard way.** The
  first implementation deleted the persisted rows, which was actively
  destructive: joining a guest SSID makes *every* main-LAN device off-subnet
  at once, so a brief visit to the guest network silently wiped the entire
  device inventory, recoverable only by a manual Scan from the main network.
  Observed live — six devices at `00:18:01.910`, zero 54ms later. Rebuilding
  from the store instead means leaving a network hides its devices and
  returning brings them straight back. `apply` upserts every polled device
  before this runs, so the store is never staler than memory.

  Hiding is still much worse to get wrong than showing a stale row, so a
  device survives on *either* of two independent grounds: it's on the
  current subnet, or it's an address the next sweep would probe anyway
  (`candidateAddresses`, covering an off-subnet router or an off-subnet
  local traceroute hop — both legitimate, both invisible to a plain subnet
  test). `SubnetCalculator.isOnSameSubnet` returns `nil` rather than `false`
  when it can't parse an input, and "can't tell" always means keep.

  **One device answering at two addresses is merged by MAC.** AP1 answers
  both its own `10.0.0.17` and the VRRP virtual `10.0.0.16`, and the ARP
  table already proves they're one interface:

  ```
  ? (10.0.0.16) at e8:10:98:ca:a9:22 on en0
  ? (10.0.0.17) at e8:10:98:ca:a9:22 on en0   <- same MAC
  ? (10.0.0.18) at e8:10:98:ca:9f:66 on en0   <- AP2, its own
  ```

  `SNMPViewModel.mergingSharedMACs` collapses entries sharing a MAC, using
  the ARP data `LANDiscoveryService` already collects. Keyed on MAC rather
  than `sysName` (which was tried and reverted): two addresses sharing a MAC
  is a fact about the hardware, needs no community string, and can't be
  fooled by two devices configured with the same name — two devices cannot
  share a NIC. Devices with no ARP entry are left alone rather than guessed
  at.

  Neither address is discarded. The lowest becomes primary — a deterministic
  tie-break, not a claim about which is "real", since nothing available can
  distinguish a virtual address from an individual one — and the rest are
  carried as `aliasAddresses` and shown in the row, so a merged device still
  reveals every address it answers at. Verified against the real ARP data
  above plus order-independence, three-addresses-on-one-MAC, distinct MACs,
  and the no-ARP-data case.

  **The merge depends on ARP data, so it can't run at launch.**
  `LANDiscoveryViewModel.scan()` is asynchronous (it had to become so, to
  stop `arp` blocking the main thread), which means `SNMPViewModel.init()`
  rebuilds its device list before any MACs exist — the subprocess trace
  shows `arp -n -a` starting 1ms *after* that rebuild. Left alone, the merge
  wouldn't land until the first poll 60 seconds later, which is exactly what
  the log showed. `NMSApp` therefore calls `snmp.rebuildDeviceList()` again
  from `lanDiscovery.onScanCompleted`. Verified live: merge now lands 657ms
  after launch instead of 60s, and `10.0.0.17` correctly disappears from the
  ping target list, so AP1 is probed once rather than twice.

  The asymmetry bounds what this can do: a MAC match *proves* one device, but
  a MAC mismatch proves nothing. It works here because Aruba answers the
  virtual address from the master's own physical MAC; a proper VRRP virtual
  MAC (`00:00:5e:00:01:XX`, RFC 5798) would resolve differently and the two
  would look like separate devices. A sound positive signal, not a complete
  VRRP solution — see `DESIGN-NOTES.md`.

  **Device identity is IP-based**, including for VRRP pairs — a
  `sysName`-based identity was tried and reverted (it collapsed a VRRP
  pair member's own address and the shared virtual address it holds as
  master into one ambiguous entry, which doesn't actually model VRRP,
  just hides the duplicate that results from it). See "Classical
  dual-router VRRP identity" in `DESIGN-NOTES.md` for what was tried and
  what a proper fix likely needs.
- **Overall status (menu bar color)**: `OverallStatus` reduces everything
  down to one at-a-glance signal on the menu bar icon itself — green
  (normal), yellow (marginal), or red (critical) — verified against 10
  severity scenarios (interface down overriding everything, each of
  router/IP/DNS/HTTP failing alone, a LAN device failing alone, and
  critical+marginal failing together; predates the ISP edge router and
  public IP pings joining `criticalLabels`, not independently re-verified
  since). **Critical**
  (red): the interface is down, or router/IP/DNS/HTTP/ISP-edge-router/
  public-IP is unreachable — these mean the network is actually broken. **Marginal**
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
  which isn't worth parsing for what this app needs. Also `-n` (no reverse
  DNS), `-w 1` (1s per-hop timeout, down from 2s), and `-m 4` (4 hops max,
  down from 20) — measured directly on a real 14-hop path: reverse DNS
  itself wasn't the actual bottleneck (14.1s with it vs. 14.1s with `-n`
  alone; unresponsive/filtered hops each waiting out the full probe
  timeout dominated), but `-n` + `-w 1` with the hop range untouched still
  measured 7.1s (2x), and adding the `-m 4` cap brought it to 1.06s (13x).
  The hop cap is a real, deliberate accuracy tradeoff, not just a speed
  knob — see the campus/enterprise note below, which this interacts with
  directly. `-n` also means `TracerouteHop.hostname` is always `nil`
  immediately after a trace; the hostname-resolved parsing branch is kept
  for robustness, not because traceroute will actually produce that form
  anymore. Hostnames come back separately: `ReverseDNSService` (a bounded,
  timeout-protected `getnameinfo` call — the same defensive shape as
  `DNSResolutionService.probe()`, since an unbounded reverse lookup could
  hang exactly the way the earlier DNS-check bug did) resolves each
  responsive hop's PTR record in the background, independently per hop,
  *after* `hops` is already published — the popover shows bare IPs
  immediately, then each hop's hostname fills in as its own lookup
  resolves, rather than the trace waiting on any of them the way it used
  to. Verified against a known answer: `75.101.33.52` correctly resolves
  back to `lo0.bng3.snfcca05.sonic.net`, the same hostname traceroute used
  to provide inline. A stale enrichment result landing after a *newer*
  trace already replaced `hops` with a different path is guarded against —
  it only applies if the hop at that position still shows the same
  address the lookup was actually for. If the enriched hop is the
  currently-monitored one, `SnapshotStore.updateLatestProviderEdgeHostname`
  also patches the hostname onto the already-written `ProviderEdgeRecord`
  row, since `recordProviderEdgeIfChanged` runs (with `hostname: nil`)
  before enrichment has had a chance to resolve anything. `IPClassifier`
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
  `UserDefaults`, independent of the SwiftData store). **This is now in
  real tension with the `-m 4` hop cap above**: on exactly the
  campus/enterprise topology this paragraph describes, if the real ISP
  edge sits past hop 4 (plausible with several internal routers before
  the actual ISP boundary), it can never appear in the hop list at all —
  not just harder to find manually, genuinely unreachable by this trace.
  Chosen anyway, knowingly, for the speed; worth knowing if traceroute
  ever seems to stop suspiciously short of a hop you expected to see.
  Until you confirm
  one, nothing is persisted to `ProviderEdgeRecord` at all — verified
  directly (fresh store, no confirmation, zero rows) — only the suggestion
  displays. Once confirmed, `TracerouteViewModel` looks up that hop by
  position on every subsequent trace and persists a `ProviderEdgeRecord`
  row only when its address actually changes (mirrors `PublicIPRecord`).
  `TracerouteViewModel` runs at launch, after every observed topology
  change (the path can change along with the network), every 10 minutes
  (still heavier than a single ping or HTTP lookup — up to 4 hops now,
  each potentially waiting out the 1s timeout, so worst case ~4s rather
  than the pre-`-m 4` worst case of up to 40s — but still enough that it
  runs far less often than connectivity checks), and on the popover's
  "Trace Now" button. **This
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
  to `1.1.1.1`) transitions to unreachable — not router/DNS/HTTP — and
  `NMSApp` wires that straight to an immediate
  `traceroute.run()`, since a real path change (not just the same hop
  going quiet) still needs a fresh trace to detect, and that's the
  earliest signal something broke upstream.

  `onInternetReachable` is the recovery counterpart, and exists because of
  a bug caught in a real upstream-outage test (an uplink pulled between a
  desktop switch and the switch above it, visible in the UI state log): the
  outage's own re-trace runs *while the path is still down*, so it fails
  and clears `monitoredHop` — which removes the ISP Edge Router target from
  `buildTargets()` entirely. With no check left, connectivity returning
  produced no recovery, and the run ended with `peRouterUnreachable` = 2
  against `peRouterReachable` = 1, an outage never bracketed by its own
  recovery. Nothing else re-traced, since an upstream break never touches
  the Mac's interface and so never fires `onChangePersisted`; the check
  simply stayed missing until the next periodic trace, up to 10 minutes
  later. Recovery now re-traces, restoring the hop and the check.

  `TracerouteViewModel.run()` defers rather than drops a call that arrives
  mid-trace (`rerunRequested`, fired from `finishRun()`). Without that, the
  recovery re-trace would be swallowed by the existing `guard !isRunning`
  for any outage shorter than a failing trace takes to finish — quietly
  reintroducing the same bug for exactly the short outages most likely to
  occur. Verified against the state machine directly: a deferred re-run
  fires exactly once, ten rapid calls collapse to one, and a
  continuously-failing trace stays bounded to one extra run rather than
  chaining.

  **`TracerouteViewModel.onTraceCompleted` closes a separate, launch-time
  race**, diagnosed from the UI state log: `traceroute` and `connectivity`
  are constructed back-to-back in `NMSApp.init()`, and `connectivity`'s very
  first check round — fired synchronously from its own `init()` — decides
  whether to include the ISP Edge Router target by reading
  `traceroute.monitoredHop` *at that instant*, before the launch-time
  `traceroute.run()` (dispatched, not awaited) has resolved anything. The
  trace itself finishes in under a second — confirmed directly, hops
  populated 655ms after launch — but the row was simply absent from Network
  Health (not red, not pending — not built at all) until the next periodic
  check, up to 30s later. `onTraceCompleted` fires from
  `TracerouteViewModel.finishRun()` (both the success and failure paths,
  since `monitoredHop` can change either way) and `NMSApp` wires it straight
  to `connectivity.runChecks()` — which also means every later trace (the
  10-minute periodic one, "Trace Now", and the two re-traces above) reflects
  a changed edge-router address immediately instead of waiting out whatever
  interval happened to be running.

  This reintroduces the identical collision `onInternetReachable` already
  hit: the callback can land while `connectivity`'s own launch-time round is
  still running its async pings. `ConnectivityViewModel.runChecks()` now
  defers rather than drops a call that arrives mid-round
  (`recheckRequested`, fired from `finishChecking()`), mirroring
  `TracerouteViewModel`'s fix exactly. Verified against the state machine
  directly, including the specific launch collision (round already in
  flight when the completion callback lands): deferred rather than dropped,
  fires exactly once on completion, and rapid-fire calls collapse to a
  single extra round rather than chaining.

  **`TracerouteViewModel.monitoredHopAddress` closes a gap the recovery fix
  above didn't**: during the outage itself (not just its recovery), the
  ISP Edge Router row read "Not checked" instead of "unreachable." Cause:
  `apply(_:)` fully replaces `hops` on every trace, and a hop that times out
  parses as `address: nil` — indistinguishable from a hop that's simply
  never been resolved yet. The outage's own re-trace (from
  `onInternetUnreachable`) runs while the path is down, every hop times out,
  and `monitoredHop.address` goes nil — so `buildTargets` had nothing left
  to ping and omitted the row entirely, rather than pinging a known address
  and reporting it unreachable. `persistMonitoredHopIfNeeded` already
  tolerated exactly this for the *persisted* `ProviderEdgeRecord` (it simply
  skips updating on an unresolved hop); `monitoredHopAddress` extends the
  same tolerance to the *live* ping target by falling back to that same
  persisted address when the current trace didn't resolve one, rather than
  caching a second copy of it.

  **The first sign of trouble now triggers an immediate recheck**, not just
  a faster subsequent cadence. Every Network Health target was already
  pinged together in one round; what "speed up detection" adds is that the
  very first transition from healthy to unhealthy reuses the same
  `recheckRequested`/`finishChecking()` deferred-rerun mechanism to re-run
  that whole round again immediately, rather than waiting even the 5s fast
  interval — settling a full, current picture of an outage sooner (e.g. a
  device whose ARP/DNS state is momentarily stale right as a failure
  starts). Scoped to the *transition* into failure, not every round an
  outage continues, so a real, ongoing outage still settles into the fast
  interval rather than busy-looping at no delay. Verified directly: fires
  once on the transition into failure, doesn't refire while the outage
  continues, and fires again on a fresh failure after a recovery.

  **Pings, the DNS probe and the HTTP fetch now run concurrently**, not one
  after another. Diagnosed from a real failing round's subprocess trace:
  the pings (already parallel among themselves) finished at 49.700s, but
  the round wasn't recorded until 53.743s — a measured 4.04s of pure serial
  dead time from DNS's 2s timeout, then HTTP's 2s timeout, each running
  only after the previous one finished. `HTTPCheckService`'s check is
  genuinely `async`, so it's kicked off immediately, before the pings even
  start; the ping batch and the DNS probe both block their own thread
  (`Process`/`waitUntilExit`, and a semaphore-gated `getaddrinfo`
  respectively) so each runs on its own queue via a small `DispatchGroup`,
  concurrently with each other and with HTTP. Worst case for a round is now
  whichever single one of the three is slowest, not their sum. Verified a
  healthy round still includes real DNS/HTTP results (12.7ms/8.9ms) and
  completes the round only ~4ms after the last ping, rather than the
  ~20ms-plus a sequential healthy round would add — the difference is much
  larger during a real outage, where DNS and HTTP would each otherwise be
  timing out in turn.

  Once a hop is confirmed, the
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

## Store dumps (DEBUG builds only)

`StoreInspector` writes a plain-text snapshot of every SwiftData table to
`~/Library/Logs/NMS/state-dumps/NMS-state-<timestamp>.txt` — per table, the
row count, the time span it covers, and the newest few rows with real
timestamps.

It exists because the alternative is running `sqlite3` against the store by
hand, and Core Data's on-disk schema is hostile to that: tables and columns
are all `Z`-prefixed (`ZAPPEVENTRECORD`, `ZOCCURREDAT`), and dates use
Apple's 2001 epoch, so even "show me recent events" needs
`datetime(ZOCCURREDAT + 978307200, 'unixepoch', 'localtime')`. That query
got hand-written more than a dozen times in one debugging session before
this existed.

**Written by the same camera button that takes a screenshot**, sharing its
timestamp, and deliberately so: the recurring question during debugging is
rarely "what did the UI show" or "what's in the store" separately — it's
whether the two *agree*. Capturing them at different moments is exactly when
a mismatch stops being evidence.

The row counts and time spans matter as much as the rows themselves. "4280
rows spanning 4h29m" is what made the growth rate measurable in the first
place (see "Data retention" above), and a count that doesn't move after a
prune is how a silently-failing delete gets noticed — which is precisely how
the SwiftData batch-delete bug was caught.

`#if DEBUG` throughout, for the same reason `UIStateLogger` is: these files
contain SSIDs, MAC addresses, the public IP and full event history, and
`~/Library/Logs/` is collected by `sysdiagnose`.

## UI state log (DEBUG builds only)

A development aid, not a feature: `UIStateLogger` writes one line per value
pushed into the UI to `~/Library/Logs/NMS/ui-state.log`, so "did this change
what's actually displayed?" can be answered by reading a file. The popover is
a `MenuBarExtra(.window)`, which dismisses on *any* focus loss — including
clicking into another app — so screenshotting it is a timing race; this
isn't, and unlike a screenshot it captures a sequence over time.

```
0 | 2026-07-27T23:20:11.958Z | UIStateLogger | session started
1 | 2026-07-27T23:20:11.958Z | NetworkMonitorViewModel.currentInterface | NetworkInterfaceInfo(interfaceName: "en0", …)
4 | 2026-07-27T23:20:12.098Z | WiFiSSIDViewModel.currentSSID | nil
5 | 2026-07-27T23:20:12.316Z | ConnectivityViewModel.checks | [ConnectivityCheck(label: "Router", success: true, …)]
6 | 2026-07-27T23:20:42.417Z | ConnectivityViewModel.checks | [ConnectivityCheck(label: "Router", success: true, …)]
```

### Failure injection (DEBUG builds only)

`FailureInjector` forces connectivity checks to fail, so the app's outage
behaviour can be exercised without unplugging anything. Every outage path in
this app was previously tested by physically pulling a cable.

```bash
defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectFailures -array Router DNS
defaults delete ~/Library/Preferences/Thistle.NMS.plist NMSInjectFailures
```

Labels match `ConnectivityCheck.label` exactly: `Router`, `Internet`, `DNS`,
`HTTP`, `Public IP`, `ISP Edge Router`, or any SNMP device's display name.
A running app picks the key up within one check round — no relaunch needed.

Other signals — booleans, plus two more device-name arrays:

```bash
defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectInterfaceDown -bool YES
defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectDHCPLinkLocal -bool YES
defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectDHCPRenewalOverdue -bool YES
defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectSNMPRestart -array Switch
defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectSNMPSoftwareChange -array AP1
```

The SNMP pair rewrites *inputs* rather than forcing outcomes — a low
`uptimeTicks`, a modified `sysDescr` — so `recordSNMPDevice`'s real
comparison logic runs. Setting **both keys for one device** exercises the
branch neither covers alone: an uptime reset accompanied by a descriptor
change reports as the neutral `snmpDeviceSoftwareChanged` ("restarted after
software change"), *not* the alarming `snmpDeviceRestarted`, since a reboot
following an upgrade is explained rather than mysterious. Verified across all
three branches in one poll.

These fire once per injection without needing the key cleared: the forced
values persist as the new baseline, so the next poll compares 1 against 1 and
finds nothing changed. Clearing the keys produces genuine (unprefixed)
revert events, because the descriptor really does change back.

The two DHCP ones cover signals that had **never been exercised at all**
before this existed: producing a genuine APIPA fallback means breaking DHCP
on the real network, and a real overdue renewal means waiting 21 hours for T2
on a 24h lease *and* the server misbehaving. Both are additive (`||`), so
injection can force a failure but never mask a real one.

**The scenario suite.** `script/scenarios.sh` drives all of the above and
asserts on the results — 11 checks across connectivity, DHCP and SNMP, in
about a minute:

```bash
script/scenarios.sh          # exit 0 if everything passed
```

It seeds a scratch store from the real one (never opening the real store
itself), runs at 30×, toggles injections live, and restores normal operation
on exit — including on failure or Ctrl-C. Seeding rather than starting empty
is load-bearing: `SNMPViewModel.poll()` guards on a non-empty device list and
discovery only runs from the Scan button, so a fresh store would leave every
SNMP scenario silently passing by doing nothing.

It fails fast if the app doesn't actually come up against the scratch store.
That guard exists because of a real false-pass found while building it —
running the script from a copied path broke the app lookup, the app never
launched, and **four assertions still "passed"**, since every `assert_absent`
succeeds vacuously when there's no data at all.

**Keeping test runs out of real history.** `NMSStorePath` points the
SwiftData store somewhere disposable:

```bash
defaults write ~/Library/Preferences/Thistle.NMS.plist NMSStorePath /tmp/nms-test/scratch.store
defaults delete ~/Library/Preferences/Thistle.NMS.plist NMSStorePath
```

Injected failures write genuine `AppEventRecord` and
`ConnectivityCheckRecord` rows, so without this every scenario run
permanently added `[injected]` entries to the same event log and DHCP
history the app exists to keep honest — they had to be deleted by hand
twice before this existed. Verified: a run against a scratch path produced
the injected events and 177 connectivity rows there while the real store
stayed byte-identical at 85 / 5084 / 2 / 6 rows.

It also gives a scenario a *known* starting state, which matters beyond
tidiness — SNMP restart detection compares against a stored uptime, so
against a fresh store the first poll is `.firstSeen` and logs nothing. A
script wanting that event has to let two polls run.

The active store path is logged at launch (`App.store`), because silently
running against a different store than you think is a confusing way to lose
an afternoon.

**Speeding everything up.** `NMSPollSpeedup` divides every poll interval, so
a scripted scenario doesn't spend most of its runtime asleep:

```bash
defaults write ~/Library/Preferences/Thistle.NMS.plist NMSPollSpeedup -int 30
```

A divisor rather than a flat interval, deliberately — flattening every timer
to one value would destroy the relationships between them, and one of those
is itself under test: the connectivity cadence drops from 30s to 5s while
anything is unhealthy, which can't be observed if both become the same
number. Measured at 6×: healthy rounds land at 5.1s and injected-failure
rounds at 1.1s, preserving the ratio. At 30×, 42 rounds run in the 25 seconds
that would normally produce one.

Floored at one second, since the connectivity round shells out to ~10 real
`ping` targets and sub-second scheduling would be self-inflicted load rather
than a faster test. Applied to the connectivity, SNMP, DHCP and traceroute
timers — deliberately *not* to `PublicIPViewModel`, which calls a third-party
service whose 300s cadence is partly politeness.

**How long each takes to bite differs, which is worth knowing before you sit
watching a log:**

| Key | Takes effect |
|---|---|
| `NMSInjectFailures` | 5–30s — the next check round |
| `NMSInjectSNMP*` | up to 60s — `SNMPViewModel`'s poll timer |
| `NMSInjectDHCP*` | up to 5 minutes — `DHCPLeaseViewModel`'s poll timer |
| `NMSInjectInterfaceDown` | only on the Refresh button or a real topology change; nothing polls `networkMonitor.refresh()` |

`NMSInjectInterfaceDown` also has a real limit: it can make
`currentInterface` nil — exercising `runChecks`' no-interface short-circuit,
the "No active network connection" row, and the critical menu bar state — but
it **cannot** produce `interfaceDown`/`interfaceUp` events. Those are logged
only from the `SCDynamicStore` change callback, which injection doesn't fake.

**Clear the key in place rather than relaunching, if you want to see the
recovery.** `logTransitions` compares against the previous round's in-memory
results, which start empty at launch — so relaunching with the key cleared
logs nothing, while clearing it live produces the real down/up pair.

**Use the full plist path, not `defaults write Thistle.NMS`.** The bare
domain silently writes somewhere the app never reads: a stale sandbox
container at `~/Library/Containers/Thistle.NMS/` survives from an earlier
sandboxed build, and the CLI resolves the bare domain there, while the
(now unsandboxed) app reads `~/Library/Preferences/Thistle.NMS.plist`. Both
`defaults read` spellings then cheerfully confirm the key is set, which makes
this a genuinely confusing failure — the key *is* written, just not where
it's read.

Injection happens in `ConnectivityViewModel.apply`, before persistence, so
the whole downstream chain reacts exactly as it would to a real outage —
verified end to end: events fire (`[injected] Router became unreachable`),
the cadence drops from 30s to 5.1s, and the immediate-first-recheck path
fires. Failure events carry the `[injected]` prefix so a test is never
mistaken for a real outage in the event log or a store dump weeks later;
recovery events don't, because by then the check genuinely succeeded.

It tests the app's *reaction* to failure, not its *detection* of failure. A
`ping` that hangs rather than fails, or a resolver returning a bogus success,
still needs real conditions — a class that has bitten this app before
(`getaddrinfo` returning success in ~1ms with no interface up).

### Main-thread heartbeat

`UIStateLogger.startMainThreadHeartbeat()` writes one line every 20s from a
`Timer` on the main run loop:

```
81 | 2026-07-29T03:59:54.533Z | heartbeat | main thread alive
99 | 2026-07-29T04:00:14.534Z | heartbeat | main thread alive
```

**One beat proves two threads.** A line only reaches the file if the main
thread scheduled it *and* the writer thread drained it, so reading the log
against it discriminates every failure worth naming:

| What you see | What it means |
|---|---|
| Beats present | Main and writer both alive |
| Beats absent, other lines present | **Main thread wedged** |
| File entirely silent | Writer stalled, or process dead |

That middle row is why this exists. A beachballed menu bar that `kill -9`
wouldn't touch previously had to be diagnosed with `lsof`, `ps` and
guesswork — "is the main thread stuck, is the process gone, or is a debugger
holding it?" A `Timer` on the main run loop *cannot* fire while that thread
is blocked, so the absence of these lines is the answer.

Registered in `.common` run loop modes, not the default: a menu bar popover
puts the run loop into event-tracking while the user interacts with it, and a
default-mode timer would silently pause for exactly that span — a false
"wedged" reading at the one moment the app is most obviously alive. Verified
with the popover held open across two intervals: beats stayed at 20.0s,
20.0s, 20.0s with no gap.

This largely silences `WriterThread`'s own heartbeat, which only fires after
its queue idles for a full interval — subprocess traces, check rounds, SNMP
polls and this beat keep it busy, so it essentially never idles that long.
Net gain rather than loss: the writer beat existed to tell "nothing is
happening" apart from "the writer died" during quiet periods, and a
main-thread beat that had to pass *through* the writer to reach the file
proves the same thing more strongly, every interval, without needing quiet.

### Subprocess tracing

`SubprocessTracer` writes every external command — `ping`, `arp`,
`traceroute`, `snmpget` — into that *same* stream, so subprocess activity and
UI state interleave in one ordered timeline:

```
4  | 16:15:27.543Z | proc.start | #1 traceroute -m 4 -n -q 1 -w 1 1.1.1.1
5  | 16:15:27.543Z | proc.start | #2 ping -c 1 -t 1 10.0.0.1
9  | 16:15:27.550Z | proc.end   | #4 ping -c 1 -t 2 1.1.1.1 — ok in 7ms, 245 bytes
28 | 16:15:28.622Z | proc.end   | #1 traceroute … — ok in 1079ms, 85 bytes
```

**Two-phase on purpose.** Logging only on completion would produce nothing
whatsoever for a process that never returns — which is the exact failure this
was built for, after a beachballed menu bar turned out to be a four-minute-old
`arp -a` and needed `sample` to diagnose. A `start` with no matching `end`
*is* the signal; unmatched `proc.start` lines are the interesting ones.

**Correlation ids are required, not decorative.** Invocations overlap heavily
— an SNMP sweep runs up to 32 `snmpget`s at once and connectivity checks fan
out across every target — so start and end lines interleave and can only be
paired by `#id`.

It pays for itself on the second failure mode too. Contrast two lines from
one real run:

```
#2  ping -c 1 -t 1 10.0.0.1  — ok in 69ms          <- gateway
#11 ping -c 1 -t 2 10.0.0.24 — exit 2 in 2072ms    <- LAN peer
```

Gateway answers instantly while every LAN peer burns its full timeout and
exits non-zero: the signature of macOS Sequoia's Local Network privacy
denying the process. That previously took several rounds of manual shell
testing to identify, and presented as an app bug (an SNMP scan finding only
the router). Here it's one line.

**Ordering under concurrency needed a fix.** The first version took the
sequence number under a lock and *then* enqueued the write, which let two
concurrent callers hand work to the writer queue in the opposite order from
the numbers they were given — observed directly, two pings finishing in the
same millisecond wrote seq 14 to the file ahead of seq 13.
`UIStateLogger.record` now holds the lock across the enqueue as well, so file
order, sequence order and timestamp order all agree. Verified across a real
run: 54 lines, zero sequence problems, zero timestamp inversions, and all 14
subprocess invocations correctly paired.

### Degraded derivations

Two view models compute state from other view models —
`ConnectivityViewModel` (reads `networkMonitor`, `traceroute`, `publicIP`,
`snmp`) and `SNMPViewModel` (reads `networkMonitor`, `lanDiscovery`,
`bonjourDiscovery`, `traceroute`). Every one of those reads is
optional-chained with a silent fallback: `snmp?.devices ?? []`,
`traceroute?.monitoredHop?.address`, `lanDiscovery?.devices ?? []`.

That tolerance is what makes a whole class of bug invisible. A dependency
that isn't ready yet doesn't error — it yields a quietly incomplete result,
which then sits cached until some unrelated *timer* recomputes it. This app
hit it twice in one session: the ISP Edge Router row was absent for 30
seconds at launch because `traceroute.monitoredHop` hadn't resolved, and the
SNMP MAC merge didn't land for 60 seconds because the ARP table was still
empty. Neither looked wrong; both just showed less than they should have.

So both derivations now log what they *couldn't* use:

```
ConnectivityViewModel.buildTargets   | 4 targets — unavailable: monitoredHop
SNMPViewModel.rebuildDeviceList      | 6 devices — unavailable: arpMACs (no MAC merge this pass)
```

This prevents nothing — it makes the omission legible instead of silent, so
"why is that row missing?" is a line you read rather than a bug you report.
Logged only when an input is genuinely absent, so healthy rounds stay quiet
and this doesn't add noise every 30 seconds.

### One place for cross-view-model wiring

`NMSApp.wireDependencies` holds every connection between view models,
grouped into topology fan-out, derived-state dependencies, reachability
transitions, and event-log refresh. It was extracted from `init()` for the
reason above: the dependency matrix is only about eight edges, small enough
to audit by reading one function, and a missing edge in the "derived state"
group is precisely the shape both bugs above took. Each edge there carries a
comment naming the bug that shipped without it.

`UIStateLogger.record` is `nonisolated` for this`UIStateLogger.record` is `nonisolated` for this — `log` is `@MainActor`
(it must render SwiftData models on the main thread), but subprocess events
originate on whatever background queue the shell-out is running on.

Currently instrumented — deliberately staged rather than all 28 `@Published`Currently instrumented — deliberately staged rather than all 28 `@Published`
properties at once: `ConnectivityViewModel.checks`,
`NetworkMonitorViewModel.currentInterface`, `WiFiSSIDViewModel.currentSSID`,
`EventLogViewModel.events`, `SNMPViewModel.devices`, `LANDiscoveryViewModel.devices`, plus
`TracerouteViewModel`'s `hops`, `lastError` and `monitoredHopNumber`.

The traceroute three were added after the first real use of this log: working
out why the ISP Edge Router check vanished during an upstream outage required
reading source to deduce that `monitoredHop` had been cleared, because none
of that state was observable. Instrumenting it turned the next occurrence
from an inference into a reading.

Things worth knowing before relying on it:

- **It logs writes, not changes.** `didSet` fires on identical reassignment
  too, so `checks` produces a line every 30s whether or not anything moved
  (seq 5 and 6 above). That's deliberate: it separates "the code never ran"
  from "the code ran and produced the same value," usually the more useful
  distinction. Don't read it as a diff.
- **It won't catch rendering bugs.** Truncated text, wrong colors, or a view
  that fails to re-render despite correct backing data all look perfectly
  healthy here. This replaces visual inspection only for *data* questions.
- **Truncated at each launch**, not appended forever — session-scoped
  tooling, so it never grows without bound. The corollary: a crash and
  relaunch destroys the log covering the crash.
- **Ordering is guaranteed, and that took some care.** Sequence numbers and
  timestamps are captured at the call site rather than on the writer queue
  (a timestamp taken at drain time would measure queue latency), and the
  writer queue is *serial* — `DispatchQueue.global()` is concurrent and could
  complete two writes out of order. Verified over a real run: no sequence
  gaps, no timestamp regressions.
- **Values are escaped to exactly one line.** SNMP `sysDescr` is multi-line
  on plenty of gear and `lastError` comes straight from
  `error.localizedDescription`, so a stray newline would silently split one
  write into two apparent ones.

`AppEventRecord` conforms to `UIStateLoggable` because it's a SwiftData
`@Model` *class*: verified that a class without a custom description renders
as bare `NMS.AppEventRecord`, so an event list would otherwise log as
`[NMS.AppEventRecord, NMS.AppEventRecord]`. The struct-backed value types
need no conformance — they render their full contents already.

Release builds compile it out entirely: every method body is `#if DEBUG`, and
a Release binary was checked to contain zero occurrences of the log path or
queue label. That's what bounds the privacy question — these lines contain
SSIDs, the public IP and SNMP descriptors, and `~/Library/Logs/` is collected
by sysdiagnose, so it matters that a shipping build *cannot* be made to write
them. This is also why it's on by default in DEBUG with no runtime flag: a
log you must opt into before the fact is empty at the exact moment you want
it, and a runtime flag would reopen the privacy question that compile-time
gating closes. See `DESIGN-NOTES.md` for the reasoning in full, including why
`os_log` can't serve this purpose.

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

## Build identification

The popover's footer shows `Build <short hash>`, with a trailing `+` if the
checkout has uncommitted changes at launch (e.g. `Build 78b8296+`).
`BuildInfoService` reads this by shelling out to `git -C ~/Developer/NMS`
at launch — a build-time stamp (an Xcode Run Script phase writing a
generated Swift file) would be more correct in general, but this project
only ever runs on the machine it was just built on via Cmd+R, so "current
checkout state at launch" and "what got compiled" are the same thing in
practice here, without adding a build phase to a project that just had its
build-file duplication cleaned up.

The hardcoded path is a deliberate, narrow limitation: this only ever runs
against this one checkout. If the repo moves, or this ships anywhere else,
`current()` degrades to `nil` (hidden in the UI) rather than showing stale
or wrong data.

Also logged to the UI state log at launch as `App.build`, so a build can be
identified from the log alone without needing the popover open.

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

> **Not currently usable — requires a paid Apple Developer Program
> membership ($99/yr).** Both prerequisites below need one; a free Apple ID
> can't generate a "Developer ID Application" certificate or notarize
> anything, no matter which Mac you're on. Confirmed directly on both
> machines actually used for this project: `security find-identity -v -p
> codesigning` reports `0 valid identities found` on each, and no
> `NMS-notary` keychain profile exists on either. `script/release.sh` is
> real, working code — the gap is the Apple account tier, not the script —
> but until that's resolved, `v0.1.0`-style ad-hoc builds (see the status
> note at the top of this README) remain the actual distribution path.

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
