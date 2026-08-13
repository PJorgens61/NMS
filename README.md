# NMS

**[Who's it for? →](https://pjorgens61.github.io/NMS/)** — a short
project site, styled like a traceroute, with a hop for whoever you are
(remote worker, field tech, homelab enthusiast, corporate IT, Swift
programmer, or just open-source curious).

A macOS native menu bar app that automatically discovers your local
network and Internet connectivity path. Monitors the status of critical
network elements, reports failures and locates problems. Use it to
monitor your small networks or homelab. Identifies each network it
connects to and remembers what it learns. Discovers SNMP devices and
monitors for software changes and restarts.

Built with SwiftUI (a `MenuBarExtra` popover) and SwiftData for local
persistence, with no third-party code bundled or linked (see
[License](#license) for the one optional exception, used only as a
subprocess). It reads network state
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

No reputation, no company behind this — just one person's commit log.
Rather than ask you to take that on faith, [**TRUST.md**](TRUST.md) has
a ready-to-use prompt for having your own LLM audit this codebase
directly (privacy, security, dependencies, licensing), plus pointers to
exactly what to check its answer against.

## Contents

- [Running it](#running-it)
- [Developing across more than one Mac](#developing-across-more-than-one-mac)
- [The popover](#the-popover)
- [The web pages](#the-web-pages)
  - [Path Discovery](#path-discovery)
  - [Data retention](#data-retention)
- [Debug tooling](#debug-tooling)
- [Project layout](#project-layout)
- [System requirements](#system-requirements)
- [Building a universal (Intel + Apple Silicon) binary](#building-a-universal-intel--apple-silicon-binary)
- [Notes on sandboxing](#notes-on-sandboxing)
- [Signed and notarized releases](#signed-and-notarized-releases)
- [Network activity and privacy](#network-activity-and-privacy)
- [Trust and verification](TRUST.md)
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

## Developing across more than one Mac

This project is developed across two Macs, kept in sync by git alone —
see [`DEV-SETUP.md`](DEV-SETUP.md) for first-clone setup, permissions,
signing, why the persisted store never migrates automatically, and the
real (non-bug) differences to expect between machines with different
screen sizes or macOS versions.

## The popover

280pt wide, `MenuBarExtra(.window)`. This is the third UI shape this app
has had — an original popover-only design, then a single resizable
window (`ContentView`, since deleted), now back to a popover, this time
deliberately paired with the local web pages below rather than trying to
cram everything native. See `DESIGN-NOTES.md` for the two-tier
history — the window shape wasn't a mistake, it's what proved out the
web-page infrastructure this popover now leans on for anything
data-dense.

Three status lines, always visible, each a tap target that opens its
detail page in your browser:

- **MyApps** (only shown if SaaS monitoring is on) — worst-of-N across
  every monitored SaaS vendor. Opens `/saas`.
- **Internet** — the public internet/DNS/HTTP/ISP-edge/gateway-WAN
  layer, i.e. "is the internet actually reachable past my own router."
  Opens `/network`.
- **MyWifi** — local link health: interface up, router reachable, DHCP
  nominal. Labeled "MyWifi" even on Ethernet today (the plan called for
  swapping the label, that part just didn't get built) — the detail
  text and glance line below still correctly describe whichever
  interface is actually active. Opens `/network`.

Below that, a compact glance line (SSID/channel/security on Wi-Fi;
speed/duplex on Ethernet — RSSI shows in the MyWifi status line's own
detail text instead, not here), then a **Simple**/**Expert** toggle
(`@AppStorage`, persisted):

- **Simple Mode**: two controls — **View Network Summary** (opens
  `/network`) and **Run Quick Check**, a bundled, gentler run of five
  tests (path discovery, DNS check, DHCP status, a probe-only speed
  test, a Wi-Fi stress burst) behind one upfront confirmation. Deliberately
  excludes DHCP Renew (a real lease-renewal side effect) and SNMP/
  Firewall scanning (enterprise-oriented, slower, not relevant to a
  non-technical user).
- **Expert Mode**: the same two controls, plus a **Run Test ▾** menu
  covering all nine individual tests — Trace Now, Check DNS, Check DHCP
  Status, Run Speed Test, Run Apple Test, Run Wi-Fi Stress Test, Scan
  (SNMP), Scan Now (Firewall), Renew (DHCP), each keeping its own
  one-time "this has a real effect" confirmation where it already had
  one natively. Collapsing every action into one `Menu` is a deliberate
  fix for a real historical failure: this app's original popover
  attempt crammed everything in directly and repeatedly outgrew a 13"
  MacBook Air's screen — seven individual action buttons would have
  risked the same thing, one `Menu` costs exactly one row regardless of
  how many tests are behind it.

Every test's label, Quick Check membership, confirmation text, and
runtime parameters live in `NMS/Services/NetworkTestCatalogAssets/
test-catalog.json`, read fresh from disk — tuning a value (a byte size,
a duration, a timeout) is a JSON edit, not a rebuild.

Below the tests: **Known Networks…** (opens the separate window, see
below) and **Preferences…** (opens the `Settings` scene), then a
build-hash line.

## The web pages

Everything data-dense lives here now instead of in native SwiftUI —
`SWIFTUI-NOTES.md`'s standing rule, learned the hard way from this
project's own native-rendering interop bugs (`ImageRenderer` races,
SwiftData traps, a compiler crash) in earlier UI iterations. Served by
`LocalDiagnosticServer` — loopback-only (`127.0.0.1`), an ephemeral port
plus a random per-launch path token (defense in depth on top of the
loopback binding), stops itself after 10 minutes idle. Ships in Release
now, not gated to debug builds — a real end user needs the same
drill-down an agent/developer would get, the same choice RoonWatch (a
sibling project this pattern was ported from, and back to) already made
for the identical reason.

- **`/network`** — the full local-link/internet health picture: Network,
  Local Router, Public IP, ISP Edge Router, Internet, DNS, HTTP, DHCP,
  and DDNS status, ordered bottom-to-top as the actual dependency chain
  (a failure low in the list explains everything failing above it),
  plus a Wi-Fi/Ethernet glance card and Path to Internet's current hop
  list.
- **`/saas`** — every monitored SaaS vendor's status (green/yellow/red/
  blue-for-maintenance/gray-for-unparseable), plus "Your Own Sites" (a
  plain reachability check, not a real vendor status API, in Preferences).
- **`/log`** — the Diagnostic Log: a merged, chronological view of
  Events, Speed Test/Apple Test/Wi-Fi Stress Test history, plus standing
  inventories for SNMP Devices and DHCP lease history.
- **`/quickcheck`** — the Simple Mode bundle's landing page. Currently a
  stub: each bundled test fires for real, but there's no synchronized
  combined report yet (each of the five tests is independently
  fire-and-forget, same as clicking its own button — building a real
  report needs new plumbing across all five). Results land on `/network`
  and `/log` as each test finishes in the meantime.
- **`/path-discovery`** — a Globalping-based reverse traceroute from
  several external vantage points back toward this Mac's own public IP
  (see "Path Discovery" below), plus an ISP-topology diagram.
- **`/compare`** — a side-by-side table of two or more previously-visited
  networks, for spotting a recurring chain-store deployment across
  separate visits (`PJorgens61/NMS#15`, "is every Starbucks the same
  network?"). Router MAC prefix, confirmed ISP edge address, DHCP lease
  shape, and discovered SNMP device descriptors only — no automatic
  similarity scoring, and ISP org name/CGNAT status aren't included yet
  (neither is a structured per-network fact today, only free text logged
  on a later *change*, which a single visit never triggers). Reached via
  Known Networks' multi-select "Compare Selected" button, not a
  standalone nav destination.

**Networks…** (in the popover) opens a separate window listing every
network this Mac has connected to, with a way to forget one (and
everything it was the source of) entirely, or **Review** one to see its
recorded Events/SNMP Devices/DHCP History/Wi-Fi telemetry read-only —
no Scan or Refresh, since you aren't actually connected to it. Useful
for a field technician revisiting a site who wants to see what this Mac
last saw there. Kept as a native window deliberately — real CRUD
(rename/delete/mark-home) has no good popover fit, and this is data a
user actively manages, not just reads.

### Path Discovery

Traces the route to the internet (`traceroute -n -q 1 -w 1 -m 4`) via
**Trace Now**, and separately, **Path Discovery…** runs a reverse
traceroute from several external Globalping vantage points back toward
this Mac's own public IP, checking whether any of them corroborate
the confirmed ISP edge hop. Also folds in a Firewall-visibility vantage
point when configured, a Scamper "same device, different interface"
second opinion when installed (`brew install scamper`, plus a one-time
setuid step — no in-app UI for this setup step, by design; see
`ScamperService`), and Hoiho geo hints for the topology diagram. Not
gated behind confirmation — matches its native precedent, which was
just disabled until a public IP is known.

Every trace also checks for **more than one non-private hop before
reaching the real internet** — an extra NAT layer, either an extra
router of your own or your ISP's own carrier-grade NAT (CGNAT) — logged
as an Events entry only when it changes, not on every trace.

### Data retention

`SnapshotStore.pruneIfNeeded` deletes rows older than 7 days from the
two tables driven by the polling timer rather than by events —
`ConnectivityCheckRecord`, `DiscoveredDeviceRecord`
— throttled to run at most once an hour, from the write that causes the
growth. Change-log tables (`AppEventRecord`, `PublicIPRecord`,
`DHCPLeaseRecord`, `NetworkSnapshot`, `NetworkQualityRecord`) are never
pruned — they're small, and their whole value is their age.

## Experimental features

Two feature flags control whether a section is even active, now that
this runs on more than the two Macs it was developed on — friends
testing it on their own machines get to decide what they're
comfortable with rather than everything being on by default. Unlike the
debug tooling below, both work in *any* build (Release included),
backed by plain `UserDefaults`, and both apply immediately in
Preferences with no restart needed:

```
defaults write Thistle.NMS FeatureSNMPDevices -bool true
defaults write Thistle.NMS FeatureSaaSMonitoring -bool false
```

- **`FeatureSNMPDevices`** — SNMP device discovery/monitoring. **Off by
  default**, specifically because it's active network probing (SNMP
  sweeps) against whatever LAN the Mac is on — worth turning on only if
  you're comfortable with that on your own network. When off, the
  feature is fully inert (no sweeps, no polling), not just hidden from
  the window.
- **`FeatureSaaSMonitoring`** — the SaaS Status section. **On by
  default** — it only ever reaches out to third-party status pages
  directly, never your own LAN, so it doesn't carry the same
  on-your-own-network tradeoff SNMP discovery does. Which services are
  checked is a separate sub-preference (`FeatureSaaSEnabledServices`,
  a `[String]` of service names), set via the checkboxes in
  Preferences rather than a single on/off default — a fresh install
  with no customization checks every service in the list; once any
  box is touched, newly-added services stop being included
  automatically until re-checked (or "Select All" is clicked again).
  A second sub-preference, `FeatureUserAddedSaaSSites`, holds your own
  added URL+nickname pairs (JSON-encoded, since it isn't a plain
  `[String]`) — see "SaaS Status" above for how those are checked
  differently from the curated list.

Delete a key (e.g. `defaults delete Thistle.NMS FeatureSNMPDevices`) to
go back to its default.

Expert Mode (see above) used to live here too, behind
`FeatureComparisonWindow` — that flag is gone; it's a permanent,
always-on part of the app now, not an experiment.

## Debug tooling

Not gated to `#if DEBUG` builds the way it once was — since the popover
no longer carries the dense, hard-to-screenshot content that made a
live UI-state log the only reliable way to verify a change (that
content lives in the web pages now, which a browser's own dev tools
already cover), what remains here is smaller and genuinely
always-available diagnostics, not a Debug-only surface:

- **UI state log** (`~/Library/Logs/NMS/ui-state.log`) — one line per
  value pushed into the UI (`ConnectivityViewModel.checks`,
  `NetworkMonitorViewModel.currentInterface`, and a handful of others),
  plus subprocess start/end events (`SubprocessTracer`) and a 20s
  main-thread heartbeat, all in one ordered, sequenced stream. Truncated
  at each launch, not appended across runs. `sysdiagnose` collects
  `~/Library/Logs/NMS/`.
- **Failure injection** (`FailureInjector`) — forces connectivity checks,
  interface-down, DHCP signals, SNMP restart/software-change, SaaS
  outages, or DDNS staleness, via `defaults write
  ~/Library/Preferences/Thistle.NMS.plist <key> ...` rather than any
  in-app UI. Injected events carry an `[injected]` prefix so a test is
  never mistaken for a real outage later. `NMSPollSpeedup` divides every
  poll interval (a divisor, preserving the ratio between the 30s/5s
  connectivity cadence); `NMSStorePath` points the whole app at a
  scratch SwiftData store so scripted runs never touch real history.
  `FailureInjector.activeOverridesSummary()` is logged to the UI state
  log at launch and on every change, but — unlike the old single-window
  app's orange footer banner, which had no popover-row budget to spare —
  has no dedicated popover surface right now; check the log if a stale
  override is suspected.
- **`script/scenarios.sh`** — drives the injection keys above and asserts
  on the results across connectivity, DHCP, and SNMP in about a minute.
  Seeds a scratch store from the real one, runs at high speed, and
  restores normal operation on exit (including on failure or Ctrl-C).

## Project layout

Services/ViewModels/Models below cover every file that exists today, but
some descriptions are lighter-touch than a from-scratch audit would give —
this pass prioritized getting the popover conversion's own additions and
deletions exactly right (Views, and everything that moved because of it)
over re-verifying every pre-existing one-liner untouched by this work.

```
NMS/
├── NMS.xcodeproj
├── NMS/
│   ├── NMSApp.swift                          # App entry point, MenuBarExtra scene, model container
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
│   │   ├── FirewallScanRecord.swift           # SwiftData model, persisted FW visibility-scan history
│   │   ├── KnownNetwork.swift                 # SwiftData model, one row per recognized network
│   │   ├── LatencySample.swift                # Sparkline-shaped data point value type
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
│   │   ├── WiFiSampleRecord.swift             # SwiftData model, periodic Wi-Fi signal/link history
│   │   ├── WiFiStressTestRecord.swift         # SwiftData model, persisted stress-test run history
│   │   └── WiFiStressTestResult.swift         # Stress-test run summary value type
│   ├── Services/
│   │   ├── AppleNetworkQualityService.swift   # networkQuality CLI wrapper (RPM/responsiveness)
│   │   ├── BlockingWork.swift                 # Runs a genuinely blocking call off the async context
│   │   ├── BuildInfoService.swift             # Reads git HEAD from the known checkout
│   │   ├── ConnectivityService.swift          # Pings a target via /sbin/ping
│   │   ├── CorrelationService.swift           # Time-proximity failure/change matching
│   │   ├── CPULoadSampler.swift               # Samples system-wide CPU load (for stress-test attribution)
│   │   ├── DDNSResolutionService.swift        # Resolves a configured DDNS hostname via dig
│   │   ├── DeviceWebDetectionService.swift    # Probes a LAN IP for an admin web server
│   │   ├── DHCPLeaseService.swift             # Reads the cached lease via ipconfig getpacket
│   │   ├── DNSResolutionService.swift         # Resolves a hostname via getaddrinfo
│   │   ├── EthernetLinkService.swift          # Reads negotiated Ethernet speed/duplex via networksetup
│   │   ├── FailureInjector.swift              # Failure/override injection (defaults-backed)
│   │   ├── FeatureFlags.swift                 # UserDefaults-backed experimental-feature gating
│   │   ├── FWClient.swift                     # Async client for the FW companion service
│   │   ├── FWKeychain.swift                   # Stores FW's device bearer token in the login Keychain
│   │   ├── FWTraceService.swift               # Converts an FW trace into GlobalpingReverseTraceService's shape
│   │   ├── GlobalpingReverseTraceService.swift + Assets/  # Reverse traceroute via Globalping's public API
│   │   ├── HoihoService.swift                 # Router-hostname geo hints via CAIDA's Hoiho API
│   │   ├── HTTPCheckService.swift             # Real HTTP fetch via Apple's captive-portal probe
│   │   ├── IPClassifier.swift                 # RFC 1918 private-address classification
│   │   ├── ISPIdentityService.swift           # Identifies the ISP behind the public IP via RDAP
│   │   ├── LANDiscoveryService.swift          # Enumerates LAN devices via arp -n -a
│   │   ├── LocalDiagnosticServer.swift + Assets/  # Loopback HTTP server: /network, /saas, /log, /quickcheck
│   │   ├── LocationAuthorizationService.swift # Requests Core Location auth (for SSID)
│   │   ├── NetworkQualityService.swift        # Cloudflare-endpoint throughput measurement
│   │   ├── NetworkTestCatalog.swift + Assets/ # Loads test-catalog.json — labels/params/Quick-Check membership
│   │   ├── OverallStatus.swift                # Menu bar + popover severity: normal/marginal/critical
│   │   ├── PathDiscoveryRunner.swift          # Runs Path Discovery (Globalping + FW + scamper + Hoiho), opens the result page
│   │   ├── PrinterDiscoveryService.swift      # Configured-printer discovery via lpstat -v
│   │   ├── PublicIPService.swift              # Looks up WAN IP via api.ipify.org
│   │   ├── ReverseDNSService.swift            # PTR lookup via getnameinfo
│   │   ├── SaaSStatusService.swift            # Checks business SaaS vendors' public status pages
│   │   ├── ScamperService.swift               # Second-opinion alias resolution via CAIDA's scamper
│   │   ├── SNMPService.swift                  # SNMP GET/sweep via /usr/bin/snmpget
│   │   ├── SnapshotStore.swift                # Reads/writes all persisted history, retention/pruning
│   │   ├── StoreSizeService.swift             # Real on-disk store size (base + WAL + shm)
│   │   ├── SubnetCalculator.swift             # IPv4 subnet host enumeration (with a size guard)
│   │   ├── SubprocessTracer.swift             # Traces every shelled-out command to the UI state log
│   │   ├── SystemConfigurationService.swift   # Reads/observes network state
│   │   ├── SystemLoadService.swift            # Normalized CPU load via getloadavg
│   │   ├── TopologyBuilder.swift              # Merges frontside + backside traces into one topology
│   │   ├── TracerouteService.swift            # Walks the path via /usr/sbin/traceroute
│   │   ├── UIStateLogger.swift                # Sequenced log of every value pushed into the UI
│   │   ├── UntrustedText.swift                # Length ceiling for network-supplied strings (SNMP, etc.)
│   │   ├── WiFiSSIDService.swift              # Reads current Wi-Fi SSID/BSSID via CoreWLAN
│   │   ├── WiFiStressTestAggregator.swift     # Turns a stress-test burst's raw RTTs/CPU into summary stats
│   │   └── WiFiStressTestService.swift        # Runs a bounded local-hop latency-under-load burst
│   ├── ViewModels/
│   │   ├── ConnectivityViewModel.swift        # Bridges ConnectivityService -> SwiftUI
│   │   ├── DDNSViewModel.swift                # Bridges DDNSResolutionService -> SwiftUI
│   │   ├── DHCPLeaseViewModel.swift           # Bridges DHCPLeaseService -> SwiftUI
│   │   ├── EthernetLinkViewModel.swift        # Bridges EthernetLinkService -> SwiftUI
│   │   ├── FirewallVisibilityViewModel.swift  # Bridges FWClient/FWTraceService -> SwiftUI
│   │   ├── ISPIdentityViewModel.swift         # Bridges ISPIdentityService -> SwiftUI
│   │   ├── LANDiscoveryViewModel.swift        # Bridges LANDiscoveryService -> SwiftUI
│   │   ├── NetworkIdentityViewModel.swift     # Recognizes/labels the current network
│   │   ├── NetworkMonitorViewModel.swift      # Bridges SystemConfigurationService -> SwiftUI
│   │   ├── NetworkQualityViewModel.swift      # Bridges both speed-test sources -> SwiftUI
│   │   ├── NetworkReviewViewModel.swift       # One-shot, read-only load of a past network's history
│   │   ├── PublicIPViewModel.swift            # Bridges PublicIPService -> SwiftUI
│   │   ├── SaaSMonitoringViewModel.swift      # Periodic checks against SaaSStatusService's vendor list
│   │   ├── SNMPViewModel.swift                # SNMP discovery, polling, restart/upgrade events
│   │   ├── TracerouteViewModel.swift          # Bridges TracerouteService -> SwiftUI
│   │   ├── WiFiSSIDViewModel.swift            # Bridges WiFiSSIDService -> SwiftUI
│   │   └── WiFiStressTestViewModel.swift      # Bridges WiFiStressTestService -> SwiftUI, filters history by medium
│   └── Views/
│       ├── DDNSHostnamesSection.swift         # Preferences sub-section: configured DDNS hostnames
│       ├── FirewallVisibilityServerSection.swift  # Preferences sub-section: FW server URL/token
│       ├── KnownNetworksView.swift            # Known-networks list window, with delete + Review
│       ├── MenuBarIcon.swift                  # Menu bar glyph, tinted by OverallStatus
│       ├── MenuBarView.swift                  # The popover: status lines, glance line, Simple/Expert controls
│       ├── NetworkReviewView.swift            # Read-only Events/SNMP/DHCP/Wi-Fi view of a past network
│       ├── PreferencesView.swift              # Experimental-feature toggles window (Settings scene)
│       ├── SaaSServicePickerSection.swift     # Preferences sub-section: which SaaS vendors to monitor
│       ├── TileHelpers.swift                  # Shared row()/.help(optional:) view helpers
│       └── UserAddedSitesSection.swift        # Preferences sub-section: "Your Own Sites" URL+nickname pairs
├── NMSTests/                                  # 209 unit tests (Swift Testing)
└── NMSUITests/                                # 3 UI tests (XCTest)
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
I/O at all). Persistence is local SwiftData; nothing is uploaded
anywhere, and no analytics, crash reports, or telemetry of any kind
leave the machine — `UIStateLogger`'s debug log is local-only and
compiled out entirely in Release builds.

Six things reach beyond the local network, none of them silent:

- **`https://api.ipify.org`** — public-IP lookup, on a background timer.
  Reveals your public IP to a third party; see
  [ipify's terms](https://www.ipify.org/). `PublicIPService` holds the
  endpoint in a single constant.
- **`http://captive.apple.com/hotspot-detect.html`** — captive-portal
  detection, on the same 30s/5s cadence as every other connectivity
  check. The same endpoint macOS itself already uses. Plain HTTP is
  deliberate: a captive portal is detected by its interception of the
  response, which TLS would prevent.
- **A DNS query for a randomized `*.apple.com` subdomain**
  (`nms-check-<random>.apple.com`), also on that same cadence — see
  Network Health's own explanation above for why it's randomized. This
  is a DNS lookup through your configured resolver, not a connection to
  Apple; the name is never expected to resolve.
- **SaaS Status monitoring** (`SaaSStatusService`) — polls a fixed list
  of third-party status-page APIs (Slack, GitHub, Cloudflare, and about
  a dozen others; see the full list in `SaaSStatusService.swift`) every
  5 minutes. Never touches your LAN. **On by default**, the one
  exception to every other flag in "Experimental features" below being
  off-by-default — see `FeatureSaaSMonitoring` there for why, and how to
  turn it off.
- **Speed Test and Network Quality — user-triggered only, never
  automatic.** Cloudflare (`speed.cloudflare.com`, both directions) for
  **Run Speed Test**, and Apple's own `networkQuality` command-line tool
  for **Run Network Quality**. These move real data (up to ~50MB) and
  only ever run when you click the button.
- **ISP identification** (`ISPIdentityService`) — a single lookup
  against `rdap.org` (which redirects to whichever regional registry
  actually holds the record), user-triggered only, when you ask NMS to
  identify the ISP behind your current public IP.

Ordinary reachability pings (Router, Internet, ISP Edge Router, Public
IP) and the traceroute itself also reach real internet addresses
(`1.1.1.1`, your traced path's hops) — standard ICMP, a handful of bytes
each, no request body or metadata beyond what routing already requires.

SNMP community strings are stored with the app's other configuration,
not the Keychain — a deliberate call, since they're shared, read-only,
and usually the well-known default (`public`). If you use them as real
access control, they aren't protected at rest here.

**Every subprocess call in this app** (`ping`, `arp`, `traceroute`,
`snmpget`, `lpstat`, `ipconfig`) uses `Process`'s array-form `arguments`,
never a shell string — there's no shell in the loop to be tricked by a
crafted value ending up in an argument.

## Tests

Three suites, covering deliberately different ground, organized into two
named tiers so a build only pays for the coverage it actually needs:

```bash
script/test-quick.sh   # NMSTests only — a simple change, seconds
script/test-max.sh     # NMSTests + NMSUITests + script/scenarios.sh — a
                        # complex change, or before script/release.sh
                        # (which runs this tier itself as a preflight step)
```

**`NMSTests`** (209 tests, Swift Testing, runs in well under a second)
covers the logic that is *pure* — no network, no SwiftData container, no
`@MainActor` view model construction, so it runs anywhere including CI:
`SubnetCalculator`'s sweep-size guard and subnet math, `IPClassifier`'s
RFC 1918 / CGNAT / link-local boundaries, `OverallStatus`'s severity
tiers, `StoreSizeService`'s WAL-sidecar summing, `SaaSStatusService`'s
per-vendor JSON parsers (fixture-based — this is what caught the real
OpenAI/Notion shape-drift bug, `77912bf`, and is what would catch the
next one), `NMSApp.openStoreWithFallback`'s failure-detection guarantee,
and the two pieces of logic most consequential to get wrong —
`ConnectivityViewModel.isLikelyLocalPingFailure` (a false positive
silently swallows a real outage) and `SNMPViewModel.mergingSharedMACs`
(the VRRP shared-MAC merge).

Several of those were `private` and are now `nonisolated static`/`static`,
which is a genuine improvement rather than a testing concession: none
read any instance state, so keeping them unreachable from `NMSTests`
bought nothing except making a real regression untestable.

**`NMSUITests`** (3 tests, XCTest, about a minute) launches the real app
and checks real content renders (`testWindowOpensWithRealContent`), plus
a launch-performance benchmark and a launch screenshot
(`NMSUITestsLaunchTests`). That launch test used to sweep the host
Mac's own system appearance through both light and dark on every
run — removed on request (disruptive to a real dev machine's actual
appearance) — so it now just runs once in whatever appearance the Mac
is already in.

**`script/scenarios.sh`** covers what neither suite above can — the live
behaviour of a running app against a real network, driven through the
failure-injection keys.

The unit suite is verified to actually catch regressions, not just pass:
deliberately breaking `isLikelyLocalPingFailure` (dropping its DNS/HTTP
survival requirement, so it suppresses unconditionally) fails exactly
one test — `doesNotSuppressRealOutage`, the one guarding against a real
outage going unlogged.

## System requirements

Measured on the development Mac (Intel Core i5-8500, 6 cores, 32 GB,
macOS 15.7.7) against a real network with 5 SNMP devices and 8 ping
targets. Figures are from the app's own instrumentation, not estimates —
`ConnectivityCheck.systemLoad`, `SubprocessTracer` and `StoreSizeService`
already record most of this.

| | |
|---|---|
| **macOS** | 14.0 or later |
| **Architecture** | Intel and Apple Silicon (Release archives are universal) |
| **CPU, steady state** | **0.9% of one core** (0.15% of a 6-core machine) |
| **Memory** | **~74 MB** resident, 7 threads |
| **Disk** | ~3.6 MB early on; **~35 MB projected** at 7-day steady state |
| **Network** | a few KB per check round; see below |

**CPU is cadence-driven, so the steady-state figure is the floor, not the
ceiling.** Checks run every 30s while everything is healthy and **every
5s while anything is unhealthy** — a sustained outage is a 6x increase in
round frequency, and each round pings every target. A manual SNMP **Scan**
is the real peak: it sweeps the subnet with up to 32 concurrent `snmpget`
processes. Nothing else in the app approaches that, and it only ever runs
when asked.

**Disk needs the retention rules to make sense of.** Three telemetry
tables are pruned to a 7-day window (`ConnectivityCheckRecord`,
`WiFiSampleRecord`, `DiscoveredDeviceRecord`), which is what makes the
total converge instead of growing forever. `ConnectivityCheckRecord`
dominates: 10 checks per round, every 30s, is ~28,800 rows/day and about
201,600 rows at steady state. Measured at ~179 bytes/row (an upper bound
— that divides the whole store by just this table's rows), which projects
to roughly 35 MB.

Events, DHCP lease history and SNMP device state are **not** pruned, by
design — they're change logs, not telemetry, so they only grow when
something actually changes. On a stable network that is a handful of rows
a day; on a flapping one it is bounded by how often the network flaps
rather than by the clock. `StoreSizeService` can still compute the real
on-disk figure (base SQLite file plus WAL/shm sidecars), but nothing in
the current popover or web pages calls it — the popover's old footer
line that showed this live was dropped in the move away from
`ContentView` and hasn't been re-added, so this is currently only
verifiable by inspecting `~/Library/Application Support/NMS/` directly,
not observable in the running app.

**Network use is deliberately small**: per round, one ICMP echo per
target (8 here), one DNS query for a randomized subdomain, and one HTTP
fetch of Apple's captive-portal probe. SNMP polls add a few hundred bytes
per known device each minute, and the public IP is re-checked every few
minutes. That lands in the low single-digit KB per round — call it a few
MB a day. **Speed Test is the one exception** and is never automatic: it
moves up to ~50 MB per run and only when clicked.

**What it does not need**: no admin rights, no kernel extension, no
always-on internet (it degrades to reporting what's unreachable), and no
account or cloud service — everything stays on the machine.

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

A fourth check, `script/privacy-security-check.sh`, isn't wired into CI
— run it manually before tagging a release. It re-runs the greps behind
`docs/reviews/*-privacy-security-review.md`/`*-trust-assessment.md`
(network endpoints, telemetry SDKs, shell-out safety, sandbox/
entitlements, hardcoded secrets) and diffs the output against
`script/privacy-security-baseline.txt`, the snapshot from the last
review that actually read and signed off on the results. A clean diff
means nothing privacy/security-relevant changed since then; a diff is
the specific delta worth a fresh look, not a reason to redo the whole
review.

Note `NMS.xcodeproj/xcshareddata/xcschemes/NMS.xcscheme` is committed
deliberately: `xcodebuild test` requires a scheme (there's no `-target`
equivalent), and without a *shared* scheme a CI checkout — which has no
`xcuserdata` — can't resolve one.

## License

[MIT](LICENSE) © 2026 Paul Jorgensen.

No third-party code is bundled or linked — everything used is an Apple
system framework (SwiftUI, SwiftData, Network, CoreLocation) or a
command-line tool invoked at runtime as a subprocess: the standard
macOS tools (`ping`, `traceroute`, `arp`, `snmpget`), plus one optional
one you install yourself — [scamper](https://www.caida.org/catalog/software/scamper/)
(GPL-2.0), used only if present for a more rigorous check on whether
two addresses belong to the same router. Never bundled, never linked —
called as a subprocess exactly like the standard tools above, which is
what keeps its GPL-2.0 license from applying to this app's own MIT
license at all. No bundled third-party licenses to comply with.
