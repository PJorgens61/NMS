# NMS

macOS network management app — discovers the local LAN, tests connectivity
to local and internet targets, persists history, and correlates problems
with environment changes.

All four original build-plan steps have a first working version: interface
monitoring, persistence, LAN discovery, connectivity testing, and
correlation. See "What's implemented" for the specifics and current
limitations of each.

## Project layout

```
NMS/
├── Package.swift
└── Sources/NMS/
    ├── NMSApp.swift                       # App entry point, menu bar scene, model container
    ├── Models/
    │   ├── NetworkInterfaceInfo.swift     # Interface snapshot value type
    │   ├── NetworkSnapshot.swift          # SwiftData model, persisted interface history
    │   ├── DiscoveredDevice.swift         # LAN device value type
    │   ├── DiscoveredDeviceRecord.swift   # SwiftData model, persisted per-snapshot device list
    │   ├── ConnectivityCheck.swift        # Reachability check value type
    │   └── ConnectivityCheckRecord.swift  # SwiftData model, persisted check history
    ├── Services/
    │   ├── SystemConfigurationService.swift  # Reads/observes network state
    │   ├── SnapshotStore.swift            # Reads/writes all persisted history
    │   ├── LANDiscoveryService.swift      # Enumerates LAN devices via `arp -a`
    │   └── ConnectivityService.swift      # Pings a target via `/sbin/ping`
    ├── ViewModels/
    │   ├── NetworkMonitorViewModel.swift  # Bridges SystemConfigurationService -> SwiftUI
    │   ├── LANDiscoveryViewModel.swift    # Bridges LANDiscoveryService -> SwiftUI
    │   └── ConnectivityViewModel.swift    # Bridges ConnectivityService -> SwiftUI
    └── Views/
        └── ContentView.swift              # Menu bar popover UI
```

## Running it

1. Open `Package.swift` in Xcode (File > Open, select the file — Xcode
   will treat the whole package as a project).
2. Select the `NMS` scheme and Run (⌘R).
3. A network icon (📶 or 🔌) appears in the menu bar. Click it to see the
   current interface, IP, subnet, and router.

No Info.plist is needed for the "no Dock icon" behavior — that's handled
in code via `NSApp.setActivationPolicy(.accessory)` in `NMSApp.swift`.

Requires macOS 14+ (for `SwiftData`; `MenuBarExtra` itself only needs 13+)
and Xcode 15+.

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
  local interface) and multicast addresses are filtered out.
  `LANDiscoveryViewModel` runs a scan automatically every time
  `NetworkMonitorViewModel` persists an observed topology change, tying
  the resulting `DiscoveredDeviceRecord` rows to that `NetworkSnapshot`;
  the popover's "Scan" button triggers the same scan on demand (tied to
  the latest snapshot).
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

## Suggested next steps (in order)

1. **Active/richer LAN discovery** — the current `arp -a` approach only
   sees hosts the Mac has already talked to. Consider adding `NWBrowser`
   (Bonjour) to pick up devices that advertise services but haven't
   otherwise exchanged traffic, or a ping sweep of the subnet to populate
   the ARP cache first.
2. **A history view** — everything so far only surfaces the *current*
   state in the popover. All the persisted tables (`NetworkSnapshot`,
   `DiscoveredDeviceRecord`, `ConnectivityCheckRecord`) are sitting there
   unused for anything but live display and correlation math; a simple
   timeline/list view would make the persistence layer actually useful
   day-to-day.
3. **Smarter correlation** — the current heuristic is pure time-proximity
   with a fixed 90s window. Consider tightening it (e.g. only correlate a
   failure with the *nearest* snapshot, not "any within window") or
   widening it adaptively based on how often changes happen.

## Notes on sandboxing

`ConnectivityService` shells out to `/sbin/ping` for real ICMP round-trip
latency, chosen over `Network`-framework TCP probes for accurate numbers
and consistency with `LANDiscoveryService`'s `arp -a` approach. This means
the app **cannot be sandboxed as-is** — raw ICMP / process-spawning aren't
available under the App Sandbox. If Mac App Store distribution becomes a
goal, swap `ConnectivityService`'s implementation for `NWConnection`-based
TCP reachability (connect-time instead of true ping latency, but sandbox-
safe) rather than trying to sandbox the `arp`/`ping` shell-outs directly.
