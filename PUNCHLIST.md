# Punchlist

Open items, tracked here so they survive between sessions. Not a spec —
see `DESIGN-NOTES.md` for the reasoning behind anything non-obvious.
Check items off or delete them as they land; add new ones as they come up.

## Open

**From off-site testing at Martha's** (8 items, investigated but not
fixed — grounded in the actual code below, not just the symptom):

- [ ] **1. Martha's Wi-Fi never showed up in Known Networks.** Likely
  root cause: `NetworkIdentityViewModel.recognize(routerAddress:subnetMask:from:)`
  requires the router's MAC to already be present in that *one* LAN
  scan's ARP results (`devices.first(where: { $0.ipAddress ==
  routerAddress })?.macAddress`) — if it's missing, the guard just
  `return`s. No retry, no log line, nothing else re-triggers recognition
  for the rest of the session unless another topology change happens to
  fire a fresh scan.

  That guard failing on an unfamiliar network is plausible: joining
  fires the scan almost immediately, and if macOS's own ARP cache hasn't
  resolved the gateway yet — a real race this codebase has hit before
  (`SNMPViewModel.refreshARPIfMergeDataIsStale`'s doc comment describes
  exactly this after a Wi-Fi reconnect) — the guard fails silently and
  permanently.

  Two independent fixes worth doing together: retry `recognize()` a few
  seconds after a first failure, and log the failure so it's diagnosable
  instead of the network landing in silent limbo. `refreshARPIfMergeDataIsStale`
  is scoped only to already-known SNMP devices, so it doesn't cover
  first-time recognition — this needs its own path.

- [ ] **2. Network Health and Events use different names for the same
  check.** Confirmed, not guessed — grepped both sides. Event messages
  are built from `OverallStatus`'s label constants
  (`"\(check.label) became unreachable"`), while `ContentView` hardcodes
  a separate display string per row. Four of six already match by
  coincidence (DNS, HTTP, ISP Edge Router, Public IP); two don't:

  | Network Health row | Event log text |
  |---|---|
  | "Local Router" | "**Router** became unreachable" |
  | "Internet Ping by address" | "**Internet** became unreachable" |

  Fix is mechanical: have those two `ConnectionLayer.label`s reference
  `OverallStatus.routerLabel`/`.internetLabel` directly instead of a
  separately-hardcoded string, the same way the event-matching code
  already does — so they can't drift apart again.

- [ ] **3. Initial traceroute showed huge latency.** `traceroute -n -q 1
  -w 1 -m 4` sends exactly one probe per hop with no retry, and runs
  immediately on topology change — before a fresh Wi-Fi association has
  settled. This is the same class of bug this app has hit before (DNS
  answers served from a stale cache, HTTP likewise): the *first*
  measurement after a network event isn't representative, and nothing
  currently distrusts it.

  Two options, not mutually exclusive: automatically re-run the trace a
  few seconds after the first one on a *new* network (mirrors the
  "re-derive when a dependency resolves" pattern already used elsewhere
  in `NMSApp`'s wiring); or don't display/store the very first trace's
  latency as trustworthy. A blanket `-q 2`+ would also help but costs
  time on every trace, not just the first.

- [ ] **4. Move BSSID from Info to the Wi-Fi tile.** Concrete and small.
  Currently a conditional row in Info (`ContentView.swift:402-403`,
  `if info.isWiFi, let bssid = wifiSSID.currentBSSID { row("BSSID",
  bssid) }`). Move it into `wifiSection` alongside Signal/Channel/PHY
  Rate/Security, where it's topically at home.

  **One real tradeoff to flag, not do silently**: Info is visible in the
  plain popover; `wifiSection` is window-only (gated behind the
  comparison-window flag, same as the rest of that tile). Moving BSSID
  there makes it strictly less discoverable by default — fine if that's
  intended (it already fits the "niche per-device detail" bucket SNMP
  Devices is in), but worth deciding rather than assuming.

- [ ] **5. Slow recovery from a Wi-Fi down/up transition; only DNS and
  interface events fired red, not the others — should they match?**
  Couldn't diagnose this one — `~/Library/Logs/NMS/ui-state.log`
  truncates on every launch, and there have been several relaunches
  since Martha's. No data survives from the actual incident.

  What's worth knowing before assuming it's a bug: `runChecks()`'s
  "no interface at all" branch marks Internet/DNS/HTTP/PeRouter/PublicIP
  failed *together*, in one `apply()` call — so if only DNS logged red,
  the interface most likely never actually dropped to `nil`; the normal
  per-target ping path ran instead, where each target has a different
  timeout (Router 1s vs. DNS/HTTP/Internet 2s). A brief real blip
  plausibly trips a 1s check and not a 2s one — which would make the
  asymmetry a real report of differing network behavior, not
  inconsistent monitoring. Equally plausible it's a genuine gap in
  `wireReachabilityTransitions`'s recheck edges. Can't tell without a
  log from the actual event — **capture
  `~/Library/Logs/NMS/ui-state.log` immediately next time this happens**,
  before it's overwritten by a relaunch, and revisit with real data.

- [ ] **6. The old→new Wi-Fi transition event ends up filed under the
  *new* network — is that a network-separation leak?** Traced the exact
  mechanism, and it's real: in `wireTopologyChangeFanOut`,
  `networkIdentity.reset()` (clears `currentNetworkFingerprint` to
  `nil`) runs *before* `wifiSSID.refresh(...)` in the same closure.
  `WiFiSSIDViewModel.sample()` → `logNetworkChangeIfNeeded` logs the
  `"X → Y"` event synchronously right there — while the fingerprint is
  still `nil`, since `lanDiscovery.scan()` (and therefore
  `recognize()`) is async and hasn't resolved the new network yet.
  `adoptUntaggedRecords` then sweeps that `nil`-tagged event into
  whichever network resolves next: the new one.

  So today: leaving "Thistle" for "Guest" logs an event that names
  Thistle but lives under Guest's Events tab.

  **Not obviously a leak in the harmful sense** — it's one event, it
  names both networks by design, and nothing about Thistle's own history
  is exposed to Guest. But it is genuinely ambiguous which network such
  an event belongs to, and "lives under the destination, names the
  origin" wasn't a deliberate choice — it's what the reset-before-log
  ordering happens to produce. Worth a real decision: leave it (simplest,
  arguably correct — you read it *while on* the new network), log it
  under the *old* fingerprint by capturing it before `reset()` runs
  (arguably more correct — the transition is what just ended), or log it
  under both. No strong pull either way; flagging for a decision rather
  than picking one.

- [ ] **7. Detect CGNAT and report it as an event** — changes what
  "Public IP" means (shared across other customers, not identifying just
  this connection). Found a genuinely simple path: `IPClassifier`
  already does exactly this shape of check for RFC 1918 and link-local
  ranges. Add `isCGNAT(_:)` for the reserved carrier-NAT range,
  **100.64.0.0/10** (RFC 6598), and check it against
  `traceroute.monitoredHopAddress` once that hop is confirmed — an
  address in that range appearing as an actual routed hop is by itself
  unambiguous evidence of CGNAT (the range isn't publicly routable for
  anything else), no cross-referencing against the ipify-sourced public
  IP needed.

  One real limitation: `monitoredHopAddress` is only populated once the
  ISP edge hop has been manually confirmed ("Not confirmed" until then,
  per the README) — so this wouldn't be an automatic day-one signal for
  everyone, only for someone who's already set up Path to Internet.
  Worth a new neutral `AppEventKind` (informational, like
  `publicIPChanged`, not a failure) whose message explains *why* it
  matters — "your public IP is now shared with other customers" reads
  better than a bare technical label.

- [ ] **8. Cross-check the router's own interfaces/routes via SNMP
  against the current method (SCDynamicStore), and report a
  disagreement.** Real idea, genuinely untested — same limitation as the
  printer investigation earlier: this shell can't reach LAN devices at
  all, so nothing here could be verified live. Needs the router to
  expose standard IP-MIB tables (`ipRouteTable`/`ipCidrRouteTable`,
  `ifTable`) over SNMP, which is not guaranteed — today's session already
  found the *printer* on this same network had weak standard-MIB support
  (`prtAlertTable` returning only sentinel values), so don't assume the
  router will be any better without checking.

  **Concrete next step, before any code**: `snmpwalk` the router
  directly with the community strings already configured, same as was
  done for the printer:

  ```bash
  snmpwalk -v2c -c public -t 2 -r 1 <router-ip> 1.3.6.1.2.1.4.21   # ipRouteTable
  snmpwalk -v2c -c public -t 2 -r 1 <router-ip> 1.3.6.1.2.1.4.20   # ipAddrTable
  ```

  If those come back empty or unpopulated, this is a dead end on this
  hardware — same as the printer's was — and worth writing up as such
  rather than half-building it.

- [ ] **Test per-network scoping and Network Review on a second network.**
  Connect to a different network (guest VLAN, another site, a tether) and
  verify:
  - the new network is recognized as distinct and gets its own row in
    Known Networks;
  - Events / SNMP Devices / DHCP History / Wi-Fi are scoped to it — none
    of the home network's data leaks in;
  - the home network's label and history are still intact and reachable
    through the Review sheet *while connected elsewhere*;
  - the Review sheet itself renders correctly (header shows the label,
    all four sections populate, no Scan/Refresh buttons).

  This also closes out the Network Review UI, which so far has only ever
  been build-verified — never actually seen rendered.

  While over there, check that duplicate SNMP rows don't come back. A
  topology change is exactly the window where a poll can land before the
  network is re-recognized, which is the race behind the crash fixed in
  `1a66a13`:

  ```bash
  sqlite3 ~/Library/Application\ Support/NMS/default.store "SELECT ZIPADDRESS, ZNETWORKFINGERPRINT, COUNT(*) n FROM ZSNMPDEVICERECORD GROUP BY 1,2 HAVING n>1;"
  ```

  Empty output means clean.

- [ ] **No window comes to the front on the MacBook** — Open in Window,
  Preferences and Known Networks all fail there, while all three work on
  the iMac from the same build. That it's *all three* is the important
  part: this isn't a per-window bug, the whole `openWindowInFront`
  mechanism is inert on that machine, so look for a machine-level cause
  before touching per-window logic.

  **Leading suspect: macOS tightened focus-stealing.**
  `NSApp.activate(ignoringOtherApps: true)` has been deprecated since
  macOS 14, and later versions increasingly decline to let a background
  app pull itself forward. The iMac runs 15.7.7; if the MacBook is on a
  newer major version, that alone would explain a clean split between two
  machines running identical code. **Get the MacBook's `sw_vers` first —
  that single fact probably settles it.** If confirmed, the fix is the
  modern activation path (`NSApp.activate()` with no arguments, or
  `NSRunningApplication.current.activate(options:)`) rather than more
  window ordering.

  Background: foregrounding was fixed twice already. `0f8f80e` added
  `NSApp.activate`; `1ca9dc8` deferred a run loop turn and then ordered
  the specific window front by identifier, which fixed both windows on
  the iMac (verified from the state log, not by eye).

  **Start with the log rather than the code** — `openWindowInFront`
  already records what it matched:

  ```bash
  grep openWindowInFront ~/Library/Logs/NMS/ui-state.log
  ```

  - `nms-window → nms-window` means the window was found and
    `makeKeyOrderFront` ran, so the failure is *after* that — something
    is re-ordering above it, or the app never became active. Suspect
    Stage Manager, multiple displays, or a different Space, none of
    which the iMac has in the same configuration.
  - `NO WINDOW MATCHED` means SwiftUI hadn't created the window yet when
    the deferred block ran — one run loop turn is enough on the iMac but
    not on the slower/busier machine. That would make the current fix
    timing-dependent, and it should instead retry or hook window
    creation rather than assume a single turn is enough.

  Worth noting the two machines differ in more than speed: the MacBook
  is Apple Silicon and the iMac is Intel, so this may also be a macOS
  version difference rather than a race.

- [ ] **Estimate and document NMS's system requirements.** Needed now
  that other people are installing it — "will this bog down my Mac?" is a
  fair question and there's currently no answer beyond a shrug.

  Measure rather than guess; most of the instrumentation already exists:
  - **CPU** — idle vs. during a check round vs. during an SNMP sweep
    (the sweep is the peak: up to 32 concurrent `snmpget`s). Note the
    round cadence doubles as load: every 30s normally, every 5s while
    anything is unhealthy. `ConnectivityCheck.systemLoad` already records
    system load per check, so there's history to read.
  - **RAM** — resident size at launch and after a long run, watching for
    growth. The retention story is uneven: `ConnectivityCheckRecord`,
    `WiFiSampleRecord` and one other table are pruned, but Events, DHCP
    and SNMP history accumulate indefinitely (see "No retention policy
    anywhere (measured)" in DESIGN-NOTES.md).
  - **Disk** — store growth per day. `StoreSizeService` already reports
    live size in the footer, so this is a matter of sampling it over
    time rather than new code.
  - **Network** — near-zero by design, but worth stating: a handful of
    pings, one DNS probe and one HTTP fetch per round, plus SNMP polls;
    Speed Test is the only heavy user and only ever runs when asked.
  - **macOS version and hardware floor** — deployment target is macOS
    14.0. Both Intel and Apple Silicon are supported (Release archives
    are universal).

  End result should be a short "System requirements" section in
  `README.md`, with the measured numbers rather than adjectives.

- [ ] **"Generate Report" button on Network Review.** Reuse
  `ScreenshotService`'s `ImageRenderer` against the Review content rather
  than the live popover — it captures exactly what a technician is
  already looking at, with no separate auto-capture pipeline. The natural
  follow-on now that Review exists; see DESIGN-NOTES.md's "Network
  Review" section.

- [ ] **DHCP tile → Events as a multi-line message.** Idea: fold DHCP
  History detail into a multi-line Events entry instead of a separate
  section. Real tension, unresolved: Events assumes single-line,
  fixed-row-height entries, which the whole popover height calibration
  (17pt/row) depends on. Needs a design decision before any code.

- [ ] **File the two `swift-frontend` compiler crashes with Apple
  Feedback Assistant.** Both were "failed to produce diagnostic for
  expression", triggered by conditional `Window` scenes inside
  `@SceneBuilder`. Raised as a to-do three times now and never actually
  filed. Workaround is documented (push the conditional down to the
  *View* level, where the builder is far more robust) — see
  DESIGN-NOTES.md's "Feature flags" section.

- [ ] **Ethernet link speed telemetry.** Discussed alongside the Wi-Fi
  telemetry work; deliberately out of scope then, no plan yet. Revisit if
  it becomes relevant.

- [ ] **Decide whether to keep the printer alerts feature.** It's built,
  correct, and will report "OK" forever on the current Brother printer,
  which exposes nothing useful through either CUPS/IPP or the standard
  SNMP Printer MIB while idle (both verified against the real device with
  a drawer physically open — see DESIGN-NOTES.md's "Printer fault
  detection" section). Keep it for hardware that does populate those
  fields, or pull it and stop running `lpstat` every check round for no
  signal.

- [ ] **Run `/code-review ultra` on the branch.** User-triggered and
  billed, so it can't be launched from a session. Worth it: a manual pass
  over just the concurrency and event handling found a shipped crash and
  a main-thread stall, so a multi-agent pass over the whole branch would
  likely surface more.

## Deliberately not doing

These were considered and rejected with reasons; they're here so they
don't get re-raised as new ideas.

- **A message bus / pub-sub for cross-view-model events.** Would trade
  away the one property that has caught three real bugs — a missing
  wiring edge being visible by reading `wireDependencies`. See
  DESIGN-NOTES.md.
- **GPS / Core Location integration for Wi-Fi monitoring.** Accuracy is
  too coarse to add anything the network fingerprint doesn't already
  give.
- **`deinit { timer?.invalidate() }` on the `@MainActor` view models.**
  Technically unsound (`deinit` is nonisolated), but these objects never
  deinit, and every alternative adds risk for no benefit. Left as-is
  deliberately, not overlooked.
- **Classical dual-router VRRP identity** (two related `SNMPDeviceRecord`
  entries rather than collapsing to one). Real, but a bigger modelling
  change than the current merge; see DESIGN-NOTES.md.
