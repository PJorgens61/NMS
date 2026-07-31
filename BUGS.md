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

### Known Networks silently never adds an unfamiliar network

- **Status**: Fixed
- **Severity**: High — the entire per-network history feature depends on
  recognition succeeding; a network that fails to recognize gets no
  Known Networks entry and no scoped history, permanently, for that
  network.
- **Found in build**: not recorded — reported before this field existed
- **Fixed in build**: `d5661da`
- **First reported**: off-site testing at Martha's

`NetworkIdentityViewModel.recognize(routerAddress:subnetMask:from:)`
required the router's MAC to already be present in that *one* LAN scan's
ARP results (`devices.first(where: { $0.ipAddress == routerAddress
})?.macAddress`) — if it was missing, the guard just `return`ed. No
retry, no log line, nothing else re-triggered recognition for the rest of
the session unless another topology change happened to fire a fresh
scan.

That guard failing on an unfamiliar network was plausible: joining fires
the scan almost immediately, and if macOS's own ARP cache hasn't resolved
the gateway yet — a real race this codebase has hit before
(`SNMPViewModel.refreshARPIfMergeDataIsStale`'s doc comment describes
exactly this after a Wi-Fi reconnect) — the guard failed silently and
permanently.

**Fix**: split the combined guard so this one retriable case (router
address and subnet known, MAC missing) is distinguished from the
legitimate "no interface yet" case. On that specific failure, logs it
and fires a new `onRecognitionPending` hook exactly once per topology
change (`NetworkIdentityViewModel.hasRequestedRetry`, reset alongside
the rest of `reset()`'s state); `NMSApp` wires that to a single
3-second-delayed re-scan — long enough for the OS to catch up, without
meaningfully delaying a legitimately new network's first recognition.

Verified: clean build, relaunched, existing recognition on the stable
home network unaffected (no regression — the MAC lookup still succeeds
on the first try there, so the new retry path isn't even exercised in
that case, as expected). The retry path itself needs an actual slow-ARP
race to exercise, which isn't reproducible from this session — same
limitation as the original report, only ever seen off-site.

### Bug Report produced no visible UI in the app window

- **Status**: Fixed
- **Severity**: High — the feature was completely non-functional in the
  window (silently did nothing), while working correctly in the
  popover, with no error or indication anything was wrong.
- **Found in build**: e1d5c0d
- **Fixed in build**: e1d5c0d (same build — found and fixed within one
  session)
- **First reported**: field-tested and filed through the app's own Bug
  Report button, in the window, immediately after the button shipped —
  "bug reporting in the app window doesn't work. no orange box."

Root cause: the window scene composed `ContentView.scrollableContent`
and `.footerBar` as two separate children of a `VStack` declared in
`NMSApp`, rather than embedding `ContentView` itself. `ContentView` was
therefore never placed in the tree as one identified node — only
fragments of its computed output were — so SwiftUI had no stable
identity to persist `@State` against. `contentView(isInWindow:)`
constructs a fresh `ContentView` (fresh default `@State`) on every
re-render; a tap on Bug Report did set `isReportingBug = true` and did
schedule a re-render, which then rebuilt the view from scratch and
reset it straight back to `false` — indistinguishable from the button
doing nothing at all.

Fixed by moving the pinned-footer composition inside `ContentView.body`
itself (an `isInWindow` branch using the same `NoBounceScrollView`
pattern), so `ContentView` is always embedded as a single,
stably-identified view regardless of which scene hosts it.
`NMSApp.comparisonWindowContent` went back to a single direct
`contentView(isInWindow: true)` call, same shape as the popover's own.

Verified end-to-end: built, relaunched, clicked Bug Report in the
window via Accessibility scripting, waited 2+ seconds (spanning at
least one connectivity re-render) before screenshotting to confirm the
box persists rather than just surviving one frame — then watched a real
report get typed and submitted through it live.

### Window captures were missing content, and the comment field rendered as a glitch

- **Status**: Fixed
- **Severity**: High — every window-mode Screenshot/Bug Report capture
  silently lost most of its content, and the one control unique to Bug
  Report rendered as an unreadable graphical glitch instead of text.
- **Found in build**: e1d5c0d (introduced by the state-identity fix
  above, same build)
- **Fixed in build**: e1d5c0d
- **First reported**: field-tested and filed through the app's own Bug
  Report button, in the window, immediately after the state-identity
  fix above shipped — comment was itself a question ("i did some wifi
  network switching. thoughts?"), but the attached screenshot showed
  the real defect: everything above the Bug Report box was missing, and
  the comment field was a solid yellow bar with a red "prohibited"
  glyph instead of any visible text.

Two distinct causes, both `ImageRenderer` limitations, both introduced
by the same fix:

1. **Missing content**: fixing the state-identity bug above meant
   moving `NoBounceScrollView` inside `ContentView.body`'s `isInWindow`
   branch. `ImageRenderer` can't render `NoBounceScrollView`'s
   `NSViewRepresentable` content off-screen any better than it renders
   a plain `ScrollView` (see `ScreenshotService`'s own doc comment,
   quirk 1) — every window capture was silently missing
   `scrollableContent` entirely. Confirmed by the resulting PNGs
   shrinking from 300-700KB to ~42KB. Fixed the same way as that
   already-documented quirk: skip the scroll wrapper and render
   `scrollableContent` plain/unclipped when `isCapturingScreenshot`.
2. **Glitched text field**: `TextField` with `.roundedBorder` styling
   is `NSTextField`-backed the same way a bordered `Button` is
   `NSButton`-backed (the reason `.buttonStyle(.plain)` exists), so it
   hits a related but worse rendering gap off-screen. Adding
   `.textFieldStyle(.plain)` to the capture chain (same place
   `.buttonStyle(.plain)` already lives, in `ScreenshotViewModel`) was
   **not sufficient on its own** — confirmed by a second real capture
   still showing the identical glitch. Actually fixed in
   `ContentView.bugReportRow`: swap the `TextField` for a plain `Text`
   showing the same content when `isCapturingScreenshot`, rather than
   asking `ImageRenderer` to draw the control at all — the same
   principle as fix 1, applied one level more locally since this
   control (unlike a `ScrollView`) has no existing capture-mode
   fallback to reuse.

Verified against two real, independently-submitted field reports (not
just forced tests): the first showed both defects together, confirming
the diagnosis; after both fixes shipped, a second real submission
("lookd good") showed full content and clean, readable comment text.
