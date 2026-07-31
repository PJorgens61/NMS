# Bugs

Actual defects — something behaving incorrectly, as distinct from
`PUNCHLIST.md`'s feature ideas, testing tasks, and decisions. Each entry
carries status/severity/build so this can be scanned quickly; the
narrative detail underneath is the investigation, kept in full rather
than summarized away.

**Fields, per entry:**
- **Status** — Open / Investigating / Fixed.
- **Severity** — impact-based, not a formula. **High**: a core,
  advertised feature is silently broken, or broken on an entire
  platform/machine. **Medium**: real incorrect behavior or misleading
  data, but not crashing and not blocking the app's main purpose.
  **Low**: a real defect, but narrow, cosmetic, or ambiguous enough that
  the "correct" behavior itself needs a decision.
- **Found in build** — the git short-hash the bug was actually observed
  on, in the same `Build <hash>[+dirty]` format the app's own popover
  footer already uses (`BuildInfoService`/`ContentView`'s "Build …"
  line) — read it straight off the running app rather than guessing from
  `git log`. Lets a fix be checked against the exact code that was
  broken, not "whatever HEAD happens to be." Add **Fixed in build** once
  resolved, same format.
- **Screenshots** — optional, for anything visual. Save under
  `docs/images/bugs/` (sibling to `docs/images/`, which
  `docs/user-guide.md` already uses the same way) and embed with
  `![description](images/bugs/filename.png)`; omit the field entirely
  for bugs with nothing to show.

## Open

### Known Networks silently never adds an unfamiliar network

- **Status**: Open, root-caused, fix proposed
- **Severity**: High — the entire per-network history feature depends on
  recognition succeeding; a network that fails to recognize gets no
  Known Networks entry and no scoped history, permanently, for that
  network.
- **Found in build**: not recorded — reported before this field existed
- **First reported**: off-site testing at Martha's

`NetworkIdentityViewModel.recognize(routerAddress:subnetMask:from:)`
requires the router's MAC to already be present in that *one* LAN scan's
ARP results (`devices.first(where: { $0.ipAddress == routerAddress
})?.macAddress`) — if it's missing, the guard just `return`s. No retry,
no log line, nothing else re-triggers recognition for the rest of the
session unless another topology change happens to fire a fresh scan.

That guard failing on an unfamiliar network is plausible: joining fires
the scan almost immediately, and if macOS's own ARP cache hasn't resolved
the gateway yet — a real race this codebase has hit before
(`SNMPViewModel.refreshARPIfMergeDataIsStale`'s doc comment describes
exactly this after a Wi-Fi reconnect) — the guard fails silently and
permanently.

**Proposed fix**: two independent changes worth doing together — retry
`recognize()` a few seconds after a first failure, and log the failure so
it's diagnosable instead of the network landing in silent limbo.
`refreshARPIfMergeDataIsStale` is scoped only to already-known SNMP
devices, so it doesn't cover first-time recognition — this needs its own
path.

### First traceroute after joining a network reports inflated latency

- **Status**: Open, root-caused, two fix options proposed
- **Severity**: Medium — misleading data shown right after every new
  network join, not a crash or data loss.
- **Found in build**: not recorded — reported before this field existed
- **First reported**: off-site testing at Martha's

`traceroute -n -q 1 -w 1 -m 4` sends exactly one probe per hop with no
retry, and runs immediately on topology change — before a fresh Wi-Fi
association has settled. Same class of bug this app has hit before (DNS
answers served from a stale cache, HTTP likewise): the *first*
measurement after a network event isn't representative, and nothing
currently distrusts it.

**Proposed fix**, two options, not mutually exclusive: automatically
re-run the trace a few seconds after the first one on a *new* network
(mirrors the "re-derive when a dependency resolves" pattern already used
elsewhere in `NMSApp`'s wiring); or don't display/store the very first
trace's latency as trustworthy. A blanket `-q 2`+ would also help but
costs time on every trace, not just the first.

### A network-transition event can be filed under the wrong network's Events tab

- **Status**: Open, mechanism traced, needs a decision (not just a fix)
- **Severity**: Low — one event, names both networks by design, nothing
  about the origin network's other history is exposed. Real, but narrow.
- **Found in build**: not recorded — reported before this field existed
- **First reported**: off-site testing at Martha's

In `wireTopologyChangeFanOut`, `networkIdentity.reset()` (clears
`currentNetworkFingerprint` to `nil`) runs *before* `wifiSSID.refresh(...)`
in the same closure. `WiFiSSIDViewModel.sample()` →
`logNetworkChangeIfNeeded` logs the `"X → Y"` event synchronously right
there — while the fingerprint is still `nil`, since `lanDiscovery.scan()`
(and therefore `recognize()`) is async and hasn't resolved the new
network yet. `adoptUntaggedRecords` then sweeps that `nil`-tagged event
into whichever network resolves next: the new one.

So today: leaving "Thistle" for "Guest" logs an event that names Thistle
but lives under Guest's Events tab.

**Not a clean fix** — it's genuinely ambiguous which network such an
event belongs to, and "lives under the destination, names the origin"
wasn't a deliberate choice, just what the reset-before-log ordering
happens to produce. Three real options, no strong pull toward any one:
leave it (simplest, arguably correct — read *while on* the new network),
log it under the *old* fingerprint by capturing it before `reset()` runs
(arguably more correct — the transition is what just ended), or log it
under both.

### No window comes to the front on the MacBook

- **Status**: Open, leading hypothesis identified, not yet confirmed
- **Severity**: High — three separate entry points (Open in Window,
  Preferences, Known Networks) completely broken on this machine, while
  all three work on the iMac from the same build.
- **Found in build**: not recorded — reported before this field existed;
  get this off the MacBook's popover footer next time this is touched
- **First reported**: off-site testing at Martha's

That it's *all three* windows is the important part: this isn't a
per-window bug, the whole `openWindowInFront` mechanism is inert on this
machine, so the cause is machine-level, not per-window logic.

**Leading suspect: macOS tightened focus-stealing.**
`NSApp.activate(ignoringOtherApps: true)` has been deprecated since macOS
14, and later versions increasingly decline to let a background app pull
itself forward. The iMac runs 15.7.7; if the MacBook is on a newer major
version, that alone would explain a clean split between two machines
running identical code. **Get the MacBook's `sw_vers` first** — that
single fact probably settles it. If confirmed, the fix is the modern
activation path (`NSApp.activate()` with no arguments, or
`NSRunningApplication.current.activate(options:)`) rather than more
window ordering.

Background: foregrounding was fixed twice already. `0f8f80e` added
`NSApp.activate`; `1ca9dc8` deferred a run loop turn and then ordered the
specific window front by identifier, which fixed both windows on the
iMac (verified from the state log, not by eye).

**Start with the log rather than the code** — `openWindowInFront`
already records what it matched:

```bash
grep openWindowInFront ~/Library/Logs/NMS/ui-state.log
```

- `nms-window → nms-window` means the window was found and
  `makeKeyOrderFront` ran, so the failure is *after* that — something is
  re-ordering above it, or the app never became active. Suspect Stage
  Manager, multiple displays, or a different Space, none of which the
  iMac has in the same configuration.
- `NO WINDOW MATCHED` means SwiftUI hadn't created the window yet when
  the deferred block ran — one run loop turn is enough on the iMac but
  not on the slower/busier machine. That would make the current fix
  timing-dependent, and it should instead retry or hook window creation
  rather than assume a single turn is enough.

Worth noting the two machines differ in more than speed: the MacBook is
Apple Silicon and the iMac is Intel, so this may also be a macOS version
difference rather than a race.

A screenshot of the stuck-behind-other-windows state, or of the log
output above, would help confirm which branch this falls into before
more time goes into it — see the Screenshots field description above
for where to save one.

## Fixed

(Move an item here with **Fixed in build**, a one-line resolution note,
and the commit hash, rather than deleting it, so there's a record of
what broke and how it got fixed.)
