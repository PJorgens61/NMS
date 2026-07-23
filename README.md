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
│   │   └── PublicIPRecord.swift           # SwiftData model, persisted public-IP change history
│   ├── Services/
│   │   ├── SystemConfigurationService.swift  # Reads/observes network state
│   │   ├── SnapshotStore.swift            # Reads/writes all persisted history
│   │   ├── LANDiscoveryService.swift      # Enumerates LAN devices via `arp -a`
│   │   ├── ConnectivityService.swift      # Pings a target via `/sbin/ping`
│   │   ├── CorrelationService.swift       # Time-proximity failure/change matching
│   │   ├── PublicIPService.swift          # Looks up WAN IP via api.ipify.org
│   │   ├── LocationAuthorizationService.swift  # Requests Core Location auth (for SSID)
│   │   └── WiFiSSIDService.swift          # Reads current Wi-Fi SSID via CoreWLAN
│   ├── ViewModels/
│   │   ├── NetworkMonitorViewModel.swift  # Bridges SystemConfigurationService -> SwiftUI
│   │   ├── LANDiscoveryViewModel.swift    # Bridges LANDiscoveryService -> SwiftUI
│   │   ├── ConnectivityViewModel.swift    # Bridges ConnectivityService -> SwiftUI
│   │   ├── NetworkIdentityViewModel.swift # Recognizes/labels the current network
│   │   ├── PublicIPViewModel.swift        # Bridges PublicIPService -> SwiftUI
│   │   └── WiFiSSIDViewModel.swift        # Bridges WiFiSSIDService -> SwiftUI
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

**Two non-default project settings, both load-bearing — don't "fix" them
back to template defaults:**
- `ENABLE_APP_SANDBOX = NO` (target build settings). The template defaults
  to sandboxed. This app shells out to `/sbin/ping` and `/usr/sbin/arp`
  (see "Notes on sandboxing"), which App Sandbox blocks outright — leaving
  sandboxing on breaks LAN discovery, connectivity testing, and network
  recognition (which depends on LAN discovery's ARP data) all at once,
  with no error message, just silent failure.
- `INFOPLIST_KEY_NSLocationUsageDescription` /
  `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` (target build
  settings, no physical Info.plist file needed). Required for the Wi-Fi
  SSID feature's Core Location authorization request to do anything at
  all — without it, `requestWhenInUseAuthorization()` fails completely
  silently: no prompt, no error, no SSID.

The first time you're on Wi-Fi, macOS will show a system permission
prompt asking to grant NMS access to Location Services — required to read
the Wi-Fi network name (SSID), no other purpose in this app. If you
decline, the popover falls back to the generic interface name instead.
Because local Xcode debug builds are ad-hoc signed (no stable Developer
ID), macOS may treat each rebuild as a "new" app and re-prompt — expected
during development, not a bug.

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
  the latest snapshot), and one runs once at launch too.
- **Connectivity testing**: `ConnectivityService` pings a target once via
  `/sbin/ping -c 1 -t 2` and parses real ICMP round-trip time (see "Notes
  on sandboxing" below for the tradeoff this implies).
  `ConnectivityViewModel` runs a round of checks every 30s — against the
  current router, up to 2 currently-known LAN devices, and `1.1.1.1` as an
  internet target — plus once at launch and on demand via the popover's
  "Check Now" button. Pinging blocks for up to ~2s per target, so the
  actual `ping` calls run on a background queue; only the published
  results and the `ConnectivityCheckRecord` write happen back on the main
  actor. Checks aren't tied to a `NetworkSnapshot` by relationship —
  correlation (below) matches them up by comparing timestamps instead.
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

## Notes on network identity

Recognition depends on resolving the router's MAC via ARP, which needs a
moment to populate right after connecting — if a topology-change scan
fires before the OS has ARP-resolved the gateway, that round is silently
skipped (recognition state just doesn't update yet) rather than guessing.
In practice the manual "Scan" button or the next automatic scan picks it
up. This can't misfire (there's no incorrect data), it can only be
momentarily stale.

## Suggested next steps (in order)

1. **Active/richer LAN discovery** — the current `arp -a` approach only
   sees hosts the Mac has already talked to. Consider adding `NWBrowser`
   (Bonjour) to pick up devices that advertise services but haven't
   otherwise exchanged traffic, or a ping sweep of the subnet to populate
   the ARP cache first.
2. **A history view** — everything so far only surfaces the *current*
   state in the popover. All the persisted tables (`NetworkSnapshot`,
   `DiscoveredDeviceRecord`, `ConnectivityCheckRecord`, `KnownNetwork`,
   `PublicIPRecord`) are sitting there unused for anything but live display
   and correlation math; a simple timeline/list view (including a
   browsable, labelable list of all known networks, not just the current
   one) would make the persistence layer actually useful day-to-day.
3. **Smarter correlation** — the current heuristic is pure time-proximity
   with a fixed 90s window. Consider tightening it (e.g. only correlate a
   failure with the *nearest* snapshot, not "any within window") or
   widening it adaptively based on how often changes happen.

## Notes on sandboxing

`ConnectivityService` shells out to `/sbin/ping` for real ICMP round-trip
latency, chosen over `Network`-framework TCP probes for accurate numbers
and consistency with `LANDiscoveryService`'s `arp -a` approach. Combined
with `arp -a` itself, this means the app **cannot be sandboxed as-is** —
raw ICMP / process-spawning aren't available under the App Sandbox, which
is why `ENABLE_APP_SANDBOX` is explicitly set to `NO` in the target's
build settings (Xcode's App template defaults new projects to sandboxed).
If Mac App Store distribution becomes a goal, swap `ConnectivityService`'s
implementation for `NWConnection`-based TCP reachability (connect-time
instead of true ping latency, but sandbox-safe), and `LANDiscoveryService`
for `NWBrowser`-based Bonjour discovery, rather than trying to sandbox the
`arp`/`ping` shell-outs directly.
