# NMS

A macOS native menu bar app that automatically discovers your local
network and Internet connectivity path. Monitors the status of critical
network elements, reports failures and locates problems. Use it to
monitor your small networks or homelab. Identifies each network it
connects to and remembers what it learns. Discovers SNMP devices and
monitors for software changes and restarts.

Built with SwiftUI (a `MenuBarExtra` popover) and SwiftData for local
persistence, with no third-party dependencies. It reads network state
through macOS's own SystemConfiguration framework, calls directly into
system libraries for the checks that run most often (`getaddrinfo` for
DNS, `URLSession` for HTTP and throughput), and shells out to the
command-line tools already bundled with macOS for everything else
(`ping`, `traceroute`, `snmpget`, `ipconfig`, `networkQuality`) rather
than reimplementing any of those protocols itself. That's not laziness,
it's lineage: Darwin is a BSD-derived kernel, `ping` and `traceroute`
are the direct descendants of the tools Berkeley shipped with 4.2BSD
networking in 1983, and the sockets API underneath all of it — invented
at Berkeley, not Apple — is still, unmodified in spirit, what every
`socket()` call on macOS, Linux, and Windows rests on four decades
later. Everything it shows is read directly from this Mac: no account,
no cloud service, nothing collected ever leaves the machine.

> **Status: early.** This is a personal project, published so other people
> can try it — not a finished product. It works against the hardware and
> network it was developed on; expect rough edges elsewhere. There's no
> support commitment and no stability guarantee, and because the SwiftData
> models have no migration path yet, a schema change may mean deleting
> accumulated history to get the app to start again.

A user-facing walkthrough of the popover — install, permissions, what each
section means, and common troubleshooting — lives at
[`docs/user-guide.md`](https://github.com/PJorgens61/NMS/blob/main/docs/user-guide.md),
rendered directly by GitHub — no separate build or deploy step, just push.

## Contents

- [Running it](#running-it)
- [The popover](#the-popover)
  - [Open in Window](#open-in-window)
  - [Network Health](#network-health)
  - [Info](#info)
  - [Path to Internet](#path-to-internet)
  - [Speed Test](#speed-test)
  - [Events](#events)
  - [SNMP Devices](#snmp-devices)
  - [DHCP History](#dhcp-history)
  - [Correlation](#correlation)
  - [What's hidden](#whats-hidden)
  - [Data retention](#data-retention)
- [Debug tooling (DEBUG builds only)](#debug-tooling-debug-builds-only)
- [Project layout](#project-layout)
- [Building a universal (Intel + Apple Silicon) binary](#building-a-universal-intel--apple-silicon-binary)
- [Notes on sandboxing](#notes-on-sandboxing)
- [Signed and notarized releases](#signed-and-notarized-releases)
- [Network activity and privacy](#network-activity-and-privacy)
- [Tests](#tests)
- [Known limitations](#known-limitations)
- [Contributing](#contributing)
- [License](#license)

## Running it

1. Open `NMS.xcodeproj` in Xcode.
2. Select the `NMS` scheme and Run (⌘R).
3. A network icon (📶 or 🔌) appears in the menu bar. Click it to open the
   popover.

Requires macOS 14+ (`SwiftData`; `MenuBarExtra` itself only needs 13+) and
Xcode 15+.

## The popover

560pt wide, arranged top to bottom:

- A 2×2 tile grid — **Network Health** and **Path to Internet** in the
  left column, **Info** and **Speed Test** in the right — each its own
  bordered box. The two columns size independently (not a synchronized
  grid), so one column can run longer than the other without leaving a
  gap under the shorter tile.
- **Events**, **SNMP Devices**, and **DHCP History**, full width, in that
  order.
- A footer: **Refresh**, a camera icon (screenshot), **Open in Window**,
  **Networks…**, and **Quit**, with a small build-hash / store-size line
  and, when a debug override is active, an orange warning line beneath
  it.

### Open in Window

`MenuBarExtra(.window)` forces a fixed-height popover with no scrolling,
which means every screen-fit problem has to be solved by trimming
content rather than letting the container adapt — a recurring source of
work documented at length in `DESIGN-NOTES.md`. **Open in Window** opens
the same live data in a real, resizable window instead: each history
section (Events, SNMP Devices, DHCP History, Speed Test, traceroute
hops) scrolls independently in its own taller box, and an always-visible
scrollbar on the right reaches whatever doesn't fit on screen. It's a
comparison alternative alongside the popover for now, not a replacement
— both stay open to the same underlying state.

The window also has one section the popover never will: **Wi-Fi**
(signal strength with a short trend line, channel/band, negotiated PHY
rate, security), visible only on Wi-Fi. It's gated to the window
specifically rather than a feature flag, since the popover's fixed
height is exactly the budget a new full-width section shouldn't spend
on every fresh install by default.

### Network Health

Seven rows, ordered bottom-to-top as the actual dependency chain out of
this Mac — read it that way when something's wrong, since a failure low
in the list explains everything failing above it:

| Row (bottom → top) | What it checks |
|---|---|
| Network | Is there an active interface, and do we know what it's connected to |
| Local Router | Ping to the gateway's LAN address |
| Public IP | Ping to the router's own WAN-facing address — catches a dead modem/ONT a LAN-side check can't see |
| ISP Edge Router | Ping to the traceroute hop you've confirmed as the ISP's own router — "Not confirmed" until you do |
| Internet Ping by address | Ping to a fixed public address (`1.1.1.1`) — bypasses DNS entirely |
| DNS | A fresh, cache-busting name resolution |
| HTTP | A real HTTPS fetch — catches a captive portal or filtering that a raw ping wouldn't |

Each of the six probe-backed rows (everything but Network) carries an
inline sparkline of its last 30 checks, scaled independently per row so a
sub-millisecond row and a tens-of-milliseconds row don't share an axis. A
failed check breaks the line rather than interpolating across it, and
gets a red mark along the bottom — an outage should never render as a
fast response.

**If you're watching DNS query logs on this network, here's why you'll
see nonsense lookups against `apple.com` every 30 seconds (5s during an
outage): that's this app, not malware.** A plain repeated resolution of
a fixed hostname would get served from macOS's own resolver cache after
the first lookup — successful answers are cached for their record's TTL,
so a later check could report "healthy" using a stale, cached answer with
no actual network round trip at all. The DNS row instead resolves a
freshly randomized subdomain every time (`nms-check-<random>.apple.com`)
and treats the resulting `NXDOMAIN` as the successful result, not a
failure — a label that's never been queried before can't be served from
a cache entry that doesn't exist yet, so this forces a genuine round trip
on every check. This is deliberately *not* a reserved-invalid TLD like
`.invalid`/`.test`/`.example`, even though those are guaranteed to never
resolve: macOS's resolver short-circuits those locally in a couple of
milliseconds with no real network traffic, which would report "reachable"
identically whether the network was actually up or down.

When several rows fail together, only the lowest shows full-intensity
red; everything above it shows a dimmed red, since it's presumed a
consequence rather than an independent problem. A `*` next to a failure
means it landed within 90 seconds of a network change this app also
observed (see Correlation, below).

**Local CPU load can look like a network outage, and is filtered out.**
If every path-critical ping (Router, Public IP, ISP Edge Router, Internet)
fails in the same round while DNS or HTTP still succeeds, the network is
demonstrably up — DNS resolves a random subdomain and HTTP fetches a real
host, so a contradiction like that means something local (most often a
CPU-saturating build) starved the ping subprocesses, not a real outage.
Such a round writes no events and doesn't accelerate the polling cadence,
though the raw measurements are still persisted and still show up in the
sparklines. Every round also records normalized CPU load
(`getloadavg`, core-count-normalized) for exactly this diagnosis.

Checks run every 30s, dropping to 5s while anything in the table above is
unhealthy, and settle back to 30s once everything recovers. The first
transition into failure triggers an immediate extra round rather than
waiting out even the 5s interval.

### Info

Network name and type, IP address in CIDR notation, router and DNS
server addresses (router shown with its MAC fingerprint once known, e.g.
`10.0.0.1 (bc:b9:...)`, so a router swap or VRRP failover at the same IP
is visible), current public IP, and — on Wi-Fi — the BSSID. A "Known
network" / "New network (seen N×)" line tracks how often this app has
recognized the current network before — identified by gateway MAC
*and* subnet, so a main LAN and a guest VLAN on the same router (which
share a MAC) still count as distinct networks.

Events, SNMP Devices, and DHCP History are all scoped to whichever
network is current — visiting another network never mixes its data into
your own history. **Networks…** in the footer opens a list of every
network this Mac has connected to, with a way to forget one (and every
event/lease/device it was the source of) entirely.

### Path to Internet

Traces the route to the internet (`traceroute -n -q 1 -w 1 -m 4`) and
suggests the first non-private hop as the likely ISP edge — a starting
point, not an auto-trusted answer, since a campus/enterprise network can
hand out public address space before traffic reaches the real ISP. Tap
the star next to the correct hop to confirm it; from then on that
address is pinged on the same cadence as the rest of Network Health
("ISP Edge Router" above), not re-traced from scratch each time.
"Trace Now" re-runs the trace on demand; it also re-runs automatically on
every topology change, every 10 minutes, right when internet
reachability changes in either direction, and right after the confirmed
hop's ISP-edge ping itself transitions.

### Speed Test

Two independent sources, one shared history list:

- **Cloudflare** (`Run Speed Test`): a plain HTTPS GET/POST against
  Cloudflare's public speed-test endpoint, sequential (never concurrent,
  so the two numbers don't understate each other). Each direction starts
  with a small 2MB probe and only escalates to a full 25MB transfer if
  the probe suggests a fast-enough link that the small one would
  understate it — accurate on a fast connection, and no longer minutes
  (or a timeout) on a slow one, like DSL. Takes about a second on a fast
  connection.
- **Apple** (`Run Network Quality`, next to the "up to ~50MB per run" label):
  shells out to `/usr/bin/networkQuality -c -s -M 45`, for the one signal
  Cloudflare's plain transfer can't produce — responsiveness under load
  (RPM, round-trips-per-minute while the link is saturated — a
  bufferbloat measurement), always in sequential mode, since RPM is only
  emitted that way. Takes 25–40 seconds.

Both write to the same history list (10 most recent, newest first) and
share one "running" state, so they can't contend for the link at the same
time. A Cloudflare row is one line; an Apple-sourced row gets a second
line for RPM and idle base latency.

### Events

A transition log, not a stream of every check — one line when something
starts failing, one when it recovers, nothing while a state persists.
Recoveries render in green, failures in red, neutral changes
(`interfaceChanged`, `publicIPChanged`, `dhcpLeaseChanged`,
`screenshotCaptured`) in the default text color. Scrollable, ~8 visible
rows.

### SNMP Devices

Discovers switches, APs, routers, and printers that answer SNMP
(`snmpget`, community string `public` by default — editable as an
ordered, comma-separated list under "Change," tried in sequence). Each
row shows a live reachability dot (from the same ping cadence Network
Health uses), name, uptime, and software descriptor. An uptime that
resets logs a restart; a changed descriptor logs a software change; both
together (a reboot following an upgrade) log as the latter, not the
alarming former.

"Scan" clears and re-sweeps the subnet (up to ~15–20s on a full /24) —
discovery is manual, never automatic at launch. Already-known devices
are re-polled every 60s automatically. Two addresses that resolve to the
same MAC (a VRRP virtual address answered from the master's own
hardware) are shown as one entry with every address listed, not two
separate devices.

### DHCP History

Every real lease change (server, address, or timing actually differed),
newest first — the newest entry doubles as the current lease. Each entry
is two lines: server + assigned address + timestamp on the first, every
other parsed field (broadcast, gateway, DNS, domain, lease/T1/T2 timers,
transaction ID) on the second, with a tooltip explaining T1/T2 and the
transaction ID. Checked every 5 minutes. Two failure signals fire
independently of a normal renewal: falling back to a self-assigned
`169.254.x.x` address, and the transaction ID failing to change past its
own lease's T2 (rebinding) deadline.

### Correlation

A connectivity failure gets a `*` when it lands within 90 seconds (either
direction) of a topology change this app observed — a coarse
time-proximity heuristic, not causal proof. Only failures on Local
Router, Internet, DNS, or HTTP can carry it.

### What's hidden

LAN Devices has no popover section — removed entirely to fit a 13"
MacBook Air's shorter screen, not just collapsed. `LANDiscoveryViewModel`'s
ARP-based scan keeps running regardless (it still feeds network
recognition and SNMP's discovery candidates). Bonjour discovery was
removed from the app entirely (not just hidden) — see DESIGN-NOTES.md's
"mDNS/Bonjour" section for why: it was never actually being triggered to
run, and even when it had been, found nothing the SNMP subnet sweep
didn't already cover.

### Data retention

`SnapshotStore.pruneIfNeeded` deletes rows older than 7 days from the
two tables driven by the polling timer rather than by events —
`ConnectivityCheckRecord`, `DiscoveredDeviceRecord`
— throttled to run at most once an hour, from the write that causes the
growth. Change-log tables (`AppEventRecord`, `PublicIPRecord`,
`DHCPLeaseRecord`, `NetworkSnapshot`, `NetworkQualityRecord`) are never
pruned — they're small, and their whole value is their age.

## Experimental features

A couple of features aren't on by default for a fresh install, now that
this runs on more than the two Macs it was developed on — friends testing
it on their own machines get the stable, core experience unless they
opt in. Unlike the debug tooling below, these work in *any* build
(Release included), backed by plain `UserDefaults`:

```
defaults write Thistle.NMS FeatureComparisonWindow -bool true
defaults write Thistle.NMS FeatureSNMPDevices -bool true
```

- **`FeatureComparisonWindow`** — the resizable "Open in Window"
  alternative to the popover. Still genuinely experimental: see
  `DESIGN-NOTES.md`'s "The MacBook Air height constraint" for the
  ongoing comparison against the popover.
- **`FeatureSNMPDevices`** — SNMP device discovery/monitoring. Off by
  default specifically because it's active network probing (SNMP
  sweeps) against whatever LAN the Mac is on — worth turning on only if
  you're comfortable with that on your own network. When off, the
  feature is fully inert (no sweeps, no polling), not just hidden from
  the popover.

Delete either key (`defaults delete Thistle.NMS <key>`) to go back to
the default (off).

## Debug tooling (DEBUG builds only)

Everything below compiles out entirely in Release — every method body is
`#if DEBUG`, verified to leave zero trace in a Release binary. All of it
writes to `~/Library/Logs/NMS/`, which `sysdiagnose` collects, so it
matters that a shipping build cannot be made to produce it.

- **UI state log** (`ui-state.log`) — one line per value pushed into the
  UI (`ConnectivityViewModel.checks`, `NetworkMonitorViewModel
  .currentInterface`, and a handful of others), plus subprocess start/end
  events and a 20s main-thread heartbeat, all in one ordered, sequenced
  stream. Exists because the popover (`MenuBarExtra(.window)`) dismisses
  on any focus loss, making screenshot-based verification a timing race;
  reading a log isn't. Truncated at each launch, not appended across
  runs.
- **Store dumps** — the camera button also writes a plain-text snapshot
  of every SwiftData table (row count, time span, newest rows) to
  `~/Library/Logs/NMS/state-dumps/`, sharing the screenshot's timestamp
  so the two can be checked against each other.
- **Live-height tracking** — the camera button also logs the popover's
  real, on-screen height (`ContentView.liveHeight`) before the capturing
  copy swaps every scrollable section for an unclipped list — a
  screenshot's own height is always the *uncapped* size, never the
  actual on-screen one, so this is the only way to track whether the
  popover still fits a given screen.
- **Store size** — the footer shows the store's real on-disk size
  (summing the base SQLite file plus its WAL and shared-memory sidecars),
  read fresh on every render.
- **Failure injection** (`FailureInjector`) — forces connectivity checks,
  interface-down, DHCP signals, or SNMP restart/software-change, via
  `defaults write ~/Library/Preferences/Thistle.NMS.plist <key> ...`
  rather than any in-app UI. Injected events carry an `[injected]` prefix
  so a test is never mistaken for a real outage later. `NMSPollSpeedup`
  divides every poll interval (a divisor, preserving the ratio between
  the 30s/5s connectivity cadence); `NMSStorePath` points the whole app
  at a scratch SwiftData store so scripted runs never touch real history.
- **`script/scenarios.sh`** — drives the injection keys above and asserts
  on the results, 11 checks across connectivity, DHCP, and SNMP in about
  a minute. Seeds a scratch store from the real one, runs at 30×, and
  restores normal operation on exit (including on failure or Ctrl-C).
- **Active-overrides banner** — a single method
  (`FailureInjector.activeOverridesSummary()`) answers "is anything
  debug-injected right now," logged at launch and on every change, and
  shown directly in the popover footer in orange whenever anything is
  active — so a forgotten override can't go unnoticed the way it
  previously did.

## Project layout

```
NMS/
├── NMS.xcodeproj
├── NMS/
│   ├── NMSApp.swift                          # App entry point, menu bar scene, model container
│   ├── Assets.xcassets
│   ├── Models/
│   │   ├── AppEventRecord.swift               # SwiftData model, the event log (+ AppEventKind)
│   │   ├── ConnectionLayer.swift              # Network Health row value type
│   │   ├── ConnectivityCheck.swift            # Reachability check value type (+ CPU load)
│   │   ├── ConnectivityCheckRecord.swift      # SwiftData model, persisted check history
│   │   ├── DHCPLeaseInfo.swift                # Parsed DHCP lease value type
│   │   ├── DHCPLeaseRecord.swift              # SwiftData model, persisted DHCP lease history
│   │   ├── DiscoveredDevice.swift             # LAN device value type
│   │   ├── DiscoveredDeviceRecord.swift       # SwiftData model, persisted per-snapshot device list
│   │   ├── KnownNetwork.swift                 # SwiftData model, one row per recognized network
│   │   ├── LatencySample.swift                # Sparkline data point value type
│   │   ├── NetworkInterfaceInfo.swift         # Interface snapshot value type
│   │   ├── NetworkQualityRecord.swift         # SwiftData model, persisted speed-test history
│   │   ├── NetworkQualityResult.swift         # Speed-test result value type (Cloudflare or Apple)
│   │   ├── NetworkSnapshot.swift              # SwiftData model, persisted interface history
│   │   ├── ProviderEdgeRecord.swift           # SwiftData model, persisted ISP edge router history
│   │   ├── PublicIPInfo.swift                 # Public-IP lookup value type
│   │   ├── PublicIPRecord.swift               # SwiftData model, persisted public-IP change history
│   │   ├── SNMPDevice.swift                   # SNMP-discovered infrastructure device value type
│   │   ├── SNMPDeviceRecord.swift             # SwiftData model, current state per SNMP device
│   │   ├── TracerouteHop.swift                # One hop's value type (+ RFC1918 classification)
│   │   └── WiFiSampleRecord.swift             # SwiftData model, periodic Wi-Fi signal/link history
│   ├── Services/
│   │   ├── AppleNetworkQualityService.swift   # networkQuality CLI wrapper (RPM/responsiveness)
│   │   ├── BuildInfoService.swift             # Reads git HEAD from the known checkout
│   │   ├── ConnectivityService.swift          # Pings a target via /sbin/ping
│   │   ├── CorrelationService.swift           # Time-proximity failure/change matching
│   │   ├── DHCPLeaseService.swift             # Reads the cached lease via ipconfig getpacket
│   │   ├── DNSResolutionService.swift         # Resolves a hostname via getaddrinfo
│   │   ├── FailureInjector.swift              # DEBUG-only failure/override injection
│   │   ├── FeatureFlags.swift                 # UserDefaults-backed experimental-feature gating
│   │   ├── HTTPCheckService.swift             # Real HTTP fetch via Apple's captive-portal probe
│   │   ├── IPClassifier.swift                 # RFC 1918 private-address classification
│   │   ├── LANDiscoveryService.swift          # Enumerates LAN devices via arp -n -a
│   │   ├── LocationAuthorizationService.swift # Requests Core Location auth (for SSID)
│   │   ├── NetworkQualityService.swift        # Cloudflare-endpoint throughput measurement
│   │   ├── OverallStatus.swift                # Menu bar severity: normal/marginal/critical
│   │   ├── PrinterDiscoveryService.swift      # Configured-printer discovery via lpstat -v
│   │   ├── PublicIPService.swift              # Looks up WAN IP via api.ipify.org
│   │   ├── ReverseDNSService.swift            # PTR lookup via getnameinfo
│   │   ├── SNMPService.swift                  # SNMP GET/sweep via /usr/bin/snmpget
│   │   ├── ScreenshotService.swift            # ImageRenderer capture + live-height measurement
│   │   ├── SnapshotStore.swift                # Reads/writes all persisted history, retention/pruning
│   │   ├── StoreInspector.swift               # DEBUG-only plain-text dump of every SwiftData table
│   │   ├── StoreSizeService.swift             # Real on-disk store size (base + WAL + shm)
│   │   ├── SubnetCalculator.swift             # IPv4 subnet host enumeration (with a size guard)
│   │   ├── SubprocessTracer.swift             # DEBUG-only trace of every shelled-out command
│   │   ├── SystemConfigurationService.swift   # Reads/observes network state
│   │   ├── SystemLoadService.swift            # Normalized CPU load via getloadavg
│   │   ├── TracerouteService.swift            # Walks the path via /usr/sbin/traceroute
│   │   ├── UIStateLogger.swift                # DEBUG-only log of every value pushed into the UI
│   │   └── WiFiSSIDService.swift               # Reads current Wi-Fi SSID/BSSID via CoreWLAN
│   ├── ViewModels/
│   │   ├── ConnectivityViewModel.swift        # Bridges ConnectivityService -> SwiftUI
│   │   ├── DHCPLeaseViewModel.swift           # Bridges DHCPLeaseService -> SwiftUI
│   │   ├── EventLogViewModel.swift            # Fetches/exposes the event log
│   │   ├── LANDiscoveryViewModel.swift        # Bridges LANDiscoveryService -> SwiftUI
│   │   ├── NetworkIdentityViewModel.swift     # Recognizes/labels the current network
│   │   ├── NetworkMonitorViewModel.swift      # Bridges SystemConfigurationService -> SwiftUI
│   │   ├── NetworkQualityViewModel.swift      # Bridges both speed-test sources -> SwiftUI
│   │   ├── PublicIPViewModel.swift            # Bridges PublicIPService -> SwiftUI
│   │   ├── SNMPViewModel.swift                # SNMP discovery, polling, restart/upgrade events
│   │   ├── ScreenshotViewModel.swift          # Screenshot + store-dump + live-height capture action
│   │   ├── TracerouteViewModel.swift          # Bridges TracerouteService -> SwiftUI
│   │   └── WiFiSSIDViewModel.swift            # Bridges WiFiSSIDService -> SwiftUI
│   └── Views/
│       ├── ContentView.swift                  # Menu bar popover UI
│       ├── KnownNetworksView.swift            # Known-networks list window, with delete
│       ├── NoBounceScrollView.swift           # AppKit-backed non-bouncing scroll container
│       ├── PreferencesView.swift              # Experimental-feature toggles window
│       ├── Sparkline.swift                    # Hand-drawn Canvas latency sparkline
│       └── ToolTip.swift                      # AppKit-backed tooltip (SwiftUI's .help() doesn't render here)
├── NMSTests/                                  # Default template test target (unused so far)
└── NMSUITests/                                # Default template UI test target (unused so far)
```

## Building a universal (Intel + Apple Silicon) binary

**In Xcode: Product → Archive.** The archive product is universal
(`x86_64 arm64`) with no extra settings. In the Organizer window that
opens, use Distribute App → Custom → Copy App, or right-click the
archive → Show in Finder → Show Package Contents →
`Products/Applications/NMS.app`.

Equivalently:

```bash
cd ~/Developer/NMS && xcodebuild -project NMS.xcodeproj -scheme NMS -configuration Release -archivePath ~/Desktop/NMS.xcarchive archive
```

A plain `xcodebuild ... build` (not `archive`) produces a binary for the
*host* architecture only, regardless of `ARCHS`/`ONLY_ACTIVE_ARCH`
settings. If you need `build` specifically, force it:

```bash
xcodebuild -project NMS.xcodeproj -scheme NMS -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

Confirm either way with `lipo -info /path/to/NMS.app/Contents/MacOS/NMS`.

To package for another Mac, use `ditto` (preserves symlinks/extended
attributes correctly), not the Finder's Compress or a plain `zip`:

```bash
ditto -c -k --keepParent /path/to/NMS.app ~/Desktop/NMS.zip
```

Local builds are ad-hoc signed (no Developer ID), so Gatekeeper blocks
the first launch on another Mac: right-click `NMS.app` → Open, or
`xattr -cr /Applications/NMS.app` after copying it over — see "Signed
and notarized releases" for the real fix. The SNMP community list lives
in `UserDefaults`, so it doesn't travel with the app bundle; it has to be
set again on each machine.

**Four non-default project settings, all load-bearing:**

- `ENABLE_HARDENED_RUNTIME = YES` (Release only) — required for
  notarization. Doesn't restrict subprocess spawning: `ping`,
  `traceroute`, `arp`, and `snmpget` are all signed system binaries.
- `ENABLE_APP_SANDBOX = NO` — the App template defaults to sandboxed.
  This app shells out to `/sbin/ping` and `/usr/sbin/arp`, which App
  Sandbox blocks outright with no error message — just silent failure of
  LAN discovery, connectivity testing, network recognition, and
  traceroute all at once.
- `INFOPLIST_KEY_NSLocationUsageDescription` /
  `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` — required for the
  Wi-Fi SSID feature's Core Location prompt to appear at all.
- `INFOPLIST_KEY_NSLocalNetworkUsageDescription` — required for LAN
  discovery and the SNMP subnet sweep to find anything at all; without
  it, both silently return zero results.

The first time you're on Wi-Fi, macOS prompts for Location access (for
the SSID; decline and the popover falls back to the generic interface
name). Because local Xcode debug builds are ad-hoc signed, macOS may
treat each rebuild as a "new" app and re-prompt — expected during
development.

## Notes on sandboxing

This app **cannot be sandboxed as-is** — raw ICMP and process-spawning
(`ping`, `traceroute`, `arp`) aren't available under App Sandbox. If Mac
App Store distribution ever becomes a goal: swap `ConnectivityService`
for `NWConnection`-based TCP reachability (connect-time, not true ping
latency, but sandbox-safe), `LANDiscoveryService` for `NWBrowser`-based
discovery, and drop or reimplement traceroute (no sandbox-safe
equivalent exists — it fundamentally needs raw ICMP/UDP with TTL
control).

## Signed and notarized releases

> **Not set up on the machines this project currently runs on** — neither
> has a paid Apple Developer Program membership ($99/yr), which both a
> Developer ID Application certificate and notarization require. If you
> already have one, `script/release.sh` works today; the two
> prerequisites below are the only setup needed. Without it, a free
> Apple ID can't generate a "Developer ID Application" certificate or
> notarize anything, and ad-hoc builds remain the distribution path.

`script/release.sh` produces a universal, Developer ID-signed, notarized,
stapled `NMS.app` plus a `ditto` zip. Two one-time prerequisites, neither
stored in this repository:

**1. A Developer ID Application certificate.** Xcode → Settings →
Accounts → select your team → Manage Certificates… → **+** → *Developer
ID Application*. Confirm with `security find-identity -v -p codesigning`.

**2. Notarization credentials in a keychain profile.** Generate an App
Store Connect API key (App Store Connect → Users and Access →
Integrations → Keys), then:

```bash
xcrun notarytool store-credentials "NMS-notary" --key ~/private_keys/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
```

Then, for each release: `./script/release.sh`. It checks both
prerequisites first, archives universal, exports signed, submits to
Apple and waits, staples the ticket, and verifies with `codesign
--verify`, `spctl -a -t install`, and `stapler validate`.
`NOTARY_PROFILE`, `TEAM_ID`, and `BUILD_DIR` can be overridden by
environment variable. The zip must be built *after* stapling (the
archive submitted to Apple doesn't contain the ticket) — the script
handles this automatically.

## Network activity and privacy

Nearly everything stays on the local network: `arp -a`, SNMP GETs,
ping/traceroute, `lpstat` (reads local CUPS configuration, no network
I/O at all). Persistence is local SwiftData;
nothing is uploaded anywhere. Two checks leave the network, both on a
timer:

- **`https://api.ipify.org`** — public-IP lookup. Reveals your public IP
  to a third party; see [ipify's terms](https://www.ipify.org/).
  `PublicIPService` holds the endpoint in a single constant.
- **`http://captive.apple.com/hotspot-detect.html`** — captive-portal
  detection, the same endpoint macOS itself uses. Plain HTTP is
  deliberate: a captive portal is detected by its interception of the
  response, which TLS would prevent.

SNMP community strings are stored with the app's other configuration,
not the Keychain — a deliberate call, since they're shared, read-only,
and usually the well-known default (`public`). If you use them as real
access control, they aren't protected at rest here.

## Tests

Two suites, covering deliberately different ground:

```bash
xcodebuild test -project NMS.xcodeproj -scheme NMS -destination "platform=macOS" -only-testing:NMSTests
script/scenarios.sh
```

**`NMSTests`** (38 tests, Swift Testing, runs in about a second) covers
the logic that is *pure* — no network, no SwiftData container, no
`@MainActor` view model construction, so it runs anywhere including CI:
`SubnetCalculator`'s sweep-size guard and subnet math, `IPClassifier`'s
RFC 1918 / CGNAT / link-local boundaries, `OverallStatus`'s severity
tiers, `StoreSizeService`'s WAL-sidecar summing, and the two pieces of
logic most consequential to get wrong —
`ConnectivityViewModel.isLikelyLocalPingFailure` (a false positive
silently swallows a real outage) and `SNMPViewModel.mergingSharedMACs`
(the VRRP shared-MAC merge).

Both of those were `private` and are now `nonisolated static`, which is
a genuine improvement rather than a testing concession: neither reads
any instance state, so inheriting `@MainActor` from the enclosing class
bought nothing, and the signature now says so.

**`script/scenarios.sh`** covers what unit tests can't — the live
behaviour of a running app against a real network, driven through the
failure-injection keys.

The unit suite is verified to actually catch regressions, not just pass:
deliberately breaking `isLikelyLocalPingFailure` (dropping its DNS/HTTP
survival requirement, so it suppresses unconditionally) fails exactly
one test — `doesNotSuppressRealOutage`, the one guarding against a real
outage going unlogged.

## Known limitations

- No history/timeline view — every persisted table beyond the event log
  serves only live display and correlation math today, not browsing.
- Correlation is a fixed 90-second time-proximity window, not causal
  proof.
- LAN discovery only sees hosts already in the ARP cache (plus whatever
  SNMP/CUPS find by other means) — no active ping sweep populates it.
- SNMP v1/v2c only; no SNMPv3 auth/privacy.
- The bundled net-snmp (5.6.2.1, ~2011) hasn't been updated by Apple in
  over a decade and is deprecation-listed — `SNMPService.isAvailable`
  degrades gracefully if a future macOS drops it.
- No sandboxing (see above) — not currently Mac App Store-eligible.

## Contributing

Issues and pull requests are welcome. No CLA, no formal style guide —
matching the surrounding code is enough.

Three workflows run in CI:

- **Tests** (`.github/workflows/tests.yml`) — runs `NMSTests` on every
  push and PR. Includes a guard that fails the job if the suite reports
  zero tests, since these are Swift Testing tests and `xcodebuild`'s own
  legacy XCTest summary prints "Executed 0 tests" while still exiting 0
  — an empty or mis-filtered bundle would otherwise pass silently.
- **CodeQL** (`.github/workflows/codeql.yml`) — static analysis for
  Swift, on PRs and weekly (a run is ~20 minutes, so not on push).
- **gitleaks** (`.github/workflows/gitleaks.yml`) — scans full history
  for committed secrets, on push, PR, and weekly.

Note `NMS.xcodeproj/xcshareddata/xcschemes/NMS.xcscheme` is committed
deliberately: `xcodebuild test` requires a scheme (there's no `-target`
equivalent), and without a *shared* scheme a CI checkout — which has no
`xcuserdata` — can't resolve one.

## License

[MIT](LICENSE) © 2026 Paul Jorgensen.

No third-party dependencies — everything used is an Apple system
framework (SwiftUI, SwiftData, Network, CoreLocation) or a standard
macOS command-line tool invoked at runtime (`ping`, `traceroute`, `arp`,
`snmpget`). No bundled third-party licenses to comply with.
