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

### Events list briefly shows ghosted/blended text during an active rubber-band scroll

- **Status**: Open — not reliably reproducible on demand, so not yet
  investigated past the description below.
- **Severity**: Low — purely cosmetic, self-corrects the instant
  scrolling stops, no effect on the underlying data (the event log
  itself, and every value in it, was confirmed correct throughout).
- **Found in build**: 3f478dc+

Reported directly: the top row of the Events list (the window's
independently-scrolling history box, see `ContentView.scrollBox`/
`SectionLayout.events`) briefly shows what looks like two frames of
text blended together — described as visually doubled/smeared, not
simple top-or-bottom clipping — specifically while actively rubber-
banding/momentum-scrolling the list, confirmed reproducible at least
twice by the same description independent of which event happened to
be at the top.

**Not yet pinned to an exact frame.** Several attempts to catch it in a
single screenshot or a paused video frame (screen recording, then
scrubbing in QuickTime) all landed on clean, crisp renders instead —
consistent with something that only exists for a very short window
during the scroll gesture itself and fully resolves before a still
capture (or a paused frame chosen after the fact) can land inside it.

**Plausible, unconfirmed connection**: this is the same category of bug
as two other `NoBounceScrollView`/`NSHostingView` interop issues already
found and fixed this project (SNMP Devices' first-row vertical clipping,
and the `Grid`-inside-`NoBounceScrollView` horizontal clipping bug) —
both were real rendering defects with root causes "never fully pinned
down (SwiftUI/AppKit interop internals, not this app's own logic)" per
`NoBounceScrollView`'s own doc comment, and both only manifested under
specific interaction/content conditions. This one hasn't been connected
to either of those specifically, and `NoBounceScrollView` sets
`verticalScrollElasticity = .none` on the inner box (which should
disable elastic bounce outright), so it's not yet understood whether
"rubber-banding" here means genuine elastic overscroll or a momentum-
scroll overshoot-and-settle that behaves similarly without going
through that elasticity setting at all.

**Next step, if it resurfaces**: try to catch it with `screencapture`'s
own timed/interval capture rather than a single manual shot or a
post-hoc paused recording, timed to fire *during* the scroll gesture
rather than after; or instrument `NoBounceScrollCoordinator` to log
scroll-view content-offset changes alongside `UIStateLogger`, which
might correlate the visual glitch to a specific offset/velocity
condition without needing to catch it visually at all.

### SwiftData in-memory fetch crashes the test host — confirmed to spread to a second model, not a fixed, known-bad list

- **Status**: Open — root cause is inside `SwiftData.framework` itself,
  not this app's code, so there's nothing here to fix directly. Worked
  around the same way the first occurrence was: the affected test suite
  is `.disabled` with a doc comment explaining why, rather than left
  crashing the host on every run.
- **Severity**: Low for the shipped app (both known occurrences are
  specific to a *fresh, in-memory* `ModelContainer` in the test harness;
  the real, on-disk store has shown no equivalent crash) — but real, and
  worth tracking: it means new SwiftData-backed unit tests can't be
  trusted to just work on this machine/OS build without checking first,
  and the set of affected models is apparently not fixed.
- **Found in build**: `c2c77f5`
- **Confirmed via**: `script/test-quick.sh`, macOS 26.5.2 (Build 25F84),
  MacBook Air — crash report pulled from the `.xcresult` bundle
  (`xcrun xcresulttool export attachments`), not just the console log.

**First occurrence** (pre-existing, not newly found today): `NMSTests.swift:2440-2457`
documents `SnapshotStore.recordPathDiscoveryRun`'s whole test suite as
`.disabled`, having traced a crash to `latestProviderEdge()` fetching
`ProviderEdgeRecord` from a fresh in-memory container — confirmed there
not to be about query shape, since a fully bare
`FetchDescriptor<ProviderEdgeRecord>()` with no predicate/sort/limit
crashed identically. That same comment states, as of when it was
written, that `latestDHCPLease()` — the *exact* same predicate/sort
shape, just a different model — did **not** crash, and used that as
evidence the bug was specific to `ProviderEdgeRecord`.

**Second occurrence, found today, contradicts that.** Confirming the
DHCP dual-homed fix (`9c71948`, "Fix DHCP status dot false-flagging on a
dual-homed Mac's routine renewal") by running its new dedicated tests
(`DHCPLeaseInterfaceScopingTests`, added in the same commit) crashed the
test host the same way: `EXC_BREAKPOINT`/`SIGTRAP` inside
`SnapshotStore.latestDHCPLease(forInterface:)`, called from
`recordDHCPLeaseIfChanged(_:)`, fetching `DHCPLeaseRecord` from a fresh
in-memory `ModelContainer` — same predicate/sort/fetch-limit shape as
the already-known-safe `latestDHCPLease()`, same in-memory-only
container pattern as the `ProviderEdgeRecord` crash. So "which models
are affected" isn't a fixed, enumerable list from one investigation —
it can apparently grow to a previously-fine model/shape combination on
a given OS build (this one: macOS 26.5.2 / Build 25F84), which is worth
knowing before trusting any *other* passing SwiftData-backed test on
this machine as durable evidence it'll keep passing after an OS update.

**Workaround applied**: `DHCPLeaseInterfaceScopingTests` is now
`.disabled` (`NMSTests.swift:1679`), matching the `ProviderEdgeRecord`
precedent exactly — a doc comment states the crash and cross-references
the earlier occurrence, rather than silently skipping or deleting the
tests. The interface-scoping logic itself
(`latestDHCPLease(forInterface:)`/`recordDHCPLeaseIfChanged`'s own doc
comments in `SnapshotStore.swift`) is unverified by an automated test
right now — covered only by manual review — same caveat as the
`ProviderEdgeRecord`-dependent logic already carries.

**Not yet done**: reproducing the actual real-world scenario the DHCP
fix addresses (a Mac with two simultaneously active interfaces) against
the real, on-disk store, to confirm the fix works outside the crashing
in-memory test harness. Not possible on this machine at the time this
was written — only Wi-Fi was active, no second interface to make it
genuinely dual-homed.

## Fixed

### `NMSUITests` launches the real app against the real, on-disk production store

- **Status**: Fixed
- **Severity**: Low — a test-isolation gap, not a live-usage bug, but a
  real one: every `script/test-max.sh` run was writing real launch-time
  rows (DHCP checks, etc.) into the user's actual history rather than a
  scratch copy.
- **Found in build**: 17564f9+dirty
- **Fixed in build**: not yet released — see git log

`NMSUITests.swift`'s `XCUIApplication().launch()` calls (both
`testWindowOpensWithRealContent` and `testLaunchPerformance`, the
latter launching the app repeatedly to measure it) carried no launch
arguments overriding the store path, so they ran against the real
`~/Library/Application Support/NMS/default.store` — confirmed by the
store's own file-modification time matching exactly when
`script/test-max.sh` last ran. `script/scenarios.sh`'s live scenarios
already avoided this (seeding a scratch copy of the real store rather
than touching it directly); the UI test target had no equivalent. This
is what turned the launch-time DHCP race (see "DHCP History gets a
duplicate row" below) from a rare, easy-to-miss edge case into five
duplicate rows in about ninety seconds.

**Fix**: new `NMSUITests/IsolatedAppLaunch.swift`, an
`XCUIApplication.configureIsolatedStore()` extension that points
`-NMSStorePath` (`NMSApp.storeURL()`'s existing `#if DEBUG` override,
already used by `script/scenarios.sh` via `defaults write`) at a fresh
`NSTemporaryDirectory()` path via `launchArguments` instead — Foundation
registers `-Key value` launch arguments into `UserDefaults.standard`'s
argument domain for just that one process, so it needs no
`defaults write`/`defaults delete` cleanup and can't race a real
running instance's own preferences. All three UI tests
(`NMSUITests.swift`'s two, plus `NMSUITestsLaunchTests.testLaunch`) now
call it before `launch()`, and remove the scratch `.store`/`-shm`/`-wal`
files in `tearDown`.

Verified directly, not just by inspection: recorded the real store's
`.store` file modification time before running `script/test-max.sh`,
ran the full suite (all 3 UI tests + 109 unit tests + all 11 live
scenarios passing), and confirmed the `.store` file's mtime was
unchanged afterward and no new rows landed in `ZDHCPLEASERECORD`. The
`-wal`/`-shm` files do still get touched at the very end, but that's
`scenarios.sh`'s own final `launch_app` step (the real app's normal
relaunch after its cleanup), not the UI tests.

### DHCP History gets a duplicate row, unchanged lease and all, every time the app relaunches before network recognition finishes

- **Status**: Fixed
- **Severity**: Low — cosmetic/noise in a history list, not incorrect
  data (every duplicate row's fields were genuinely accurate, just
  repeated) and no event was ever logged for it (`recordDHCPLeaseIfChanged`
  only fires a `.dhcpLeaseChanged` event when fields actually differ,
  which they didn't here).
- **Found in build**: 17564f9+dirty
- **Fixed in build**: not yet released — see git log

Reported directly as "DHCP history updated every minute" with a
screenshot showing five back-to-back rows, all with identical content
(`10.0.0.1 · 10.0.0.159/24`, same lease/T1/T2, same transaction ID
`0xa517dc76`) but distinct timestamps a few seconds to just over a
minute apart. Not linked to DDNS — `DDNSViewModel` never touches
`SnapshotStore`'s DHCP-recording path at all, ruled out by reading
`DDNSViewModel.swift` directly rather than assuming.

**Confirmed against the real store, not just the code.** Queried the
live `ZDHCPLEASERECORD` table directly:

```
Z_PK  ZOBSERVEDAT        ZTRANSACTIONID  ZNETWORKFINGERPRINT
755   807434742.89       0xa517dc76      bc:b9:23:81:a6:d4|10.0.0.0/24
754   807434670.56       0xa517dc76      bc:b9:23:81:a6:d4|10.0.0.0/24
753   807434659.82       0xa517dc76      bc:b9:23:81:a6:d4|10.0.0.0/24
752   807434648.26       0xa517dc76      bc:b9:23:81:a6:d4|10.0.0.0/24
751   807434638.00       0xa517dc76      bc:b9:23:81:a6:d4|10.0.0.0/24
```

Every "duplicate" carried the exact same transaction ID and, after the
fact, the exact same network fingerprint — which is exactly what should
have made the old guard (`SnapshotStore.swift`'s
`recordDHCPLeaseIfChanged`: `guard previous?.transactionID !=
info.transactionID else { return (false, false) }`) refuse to insert.
The gap between rows (6–13s in the dense cluster above) was far tighter
than `DHCPLeaseViewModel`'s own 300s poll timer, which ruled out the
timer as the trigger — it only lined up with something relaunching the
app itself repeatedly in a short window (a `script/test-max.sh` UI-test
run — see the still-open "`NMSUITests` launches the real app against
the real, on-disk production store" entry above, which is what turned
an otherwise-rare race into five duplicates in ninety seconds).

**Root cause: `currentNetworkFingerprint` starts `nil` on every fresh
launch, and `DHCPLeaseViewModel.init()` calls `check()` unconditionally
before the first LAN scan can recognize which network this is** — a
race `SnapshotStore.swift`'s own doc comment already named directly for
SNMP/DHCP writes in general ("SNMP discovery and DHCP checks both run
before the first LAN scan can resolve which network this is, so their
writes land with `nil`"), with a retroactive-backfill method
(`NetworkIdentityViewModel.recognize`'s `adoptUntaggedRecords`) that
re-tags those `nil` rows once recognition completes. That backfill is
exactly why the *stored* fingerprint on every duplicate row above ended
up correct — it masked the bug in the data after the fact. But the
backfill didn't help `recordDHCPLeaseIfChanged`'s own lookup, which ran
*before* the backfill, scoped to `currentNetworkFingerprint` as it
stood at that moment: `nil`. `latestDHCPLease()`'s fetch predicate
(`networkFingerprint == nil`) found nothing — every prior row on this
network was already correctly fingerprinted by the previous session's
own backfill, so no `nil`-tagged row existed to match against — so
`previous` came back `nil`, the guard's `nil != "0xa517dc76"` was
trivially true, and a new row got inserted even though the lease was
byte-for-byte the one already on file.

**Fix**: `recordDHCPLeaseIfChanged` (`SnapshotStore.swift`) is now a
deliberate no-op while `currentNetworkFingerprint` is still `nil`,
instead of writing under an unscoped fingerprint. Considered and
rejected: making `latestDHCPLease()` fall back to the most recent lease
*regardless* of fingerprint when `nil` — that would have fixed the
launch case but reopened exactly the cross-network leak class this
codebase has already hit and fixed before (see "ISP info leaking across
networks," "SNMP device webURL/hostname cache leaking across
networks"): on a genuine topology change mid-session, the fingerprint
is also briefly `nil` between `NetworkIdentityViewModel.reset()` and
recognition completing, and falling back there would compare the *new*
network's lease against the *departing* network's stale one, likely
logging a nonsensical cross-network "DHCP lease changed" event. Skipping
entirely is safe either way: `NMSApp.wireDependencies`'s
`onNetworkRecognized` closure now also calls `dhcpLease.check()`
directly (previously it only called `reloadHistory()`, a plain re-read),
so the deferred check re-runs correctly-scoped the moment the network
is actually known, rather than silently waiting out the full 300s timer
or duplicating a row that hadn't changed. `SNMPViewModel`'s equivalent
dedupe wasn't audited for the same gap — worth a follow-up look, per the
doc comment's framing of this as a shared, general race rather than a
DHCP-specific one.

Verified: `script/test-quick.sh`, 109/109 tests passing after the
change.

### A brief interface-down blip during a network transition falsely logs "Back to a single NAT layer"

- **Status**: Fixed
- **Severity**: Low — a genuinely wrong entry in the durable Events
  log, but self-correcting within seconds and not blocking anything;
  the risk is a misleading permanent record, not a live-state problem.
- **Found in build**: `ec9b878+dirty`, read from the app's own recent
  `bugReportCaptured` events.
- **Fixed in build**: not yet released — see git log
- **First reported**: field-tested live at a coffee shop,
  while moving off the off-site network's Wi-Fi — asked directly why the Events log
  showed both "Multiple NAT layers detected" and "Back to a single NAT
  layer" back to back, then diagnosed from `ui-state.log`, not guessed.

**Reconstructed precisely from `TracerouteViewModel.hops`'s own logged
values across the transition, not inferred**:

```
18:37:16.885  Full trace: 192.168.68.1 (private), 10.1.10.1 (private),
              203.0.113.30 (public), 203.0.113.40 (public)
              → 2 leading private hops → isExtraNATed=true
              → "Multiple NAT layers detected" already logged

18:37:23.362  TracerouteViewModel.hops = []   ← completely empty,
              during a brief Wi-Fi interface flap mid-transition
18:37:25.484  → leadingNonInternetHopCount([]) = 0 → isExtraNATed=false
              → logs "Back to a single NAT layer to the internet."

18:37:26.493  Interface back up; fresh trace completes with the same
              2 leading private hops as before
              → isExtraNATed=true again → "Multiple NAT layers
              detected" logs again
```

**Both Events entries are real, but the "single layer" one is false —
nothing about the actual topology changed.**
`leadingNonInternetHopCount(_:)` (`TracerouteViewModel.swift:215-222`)
loops over the hops array and simply never enters the loop when it's
empty, silently returning `0` — indistinguishable from what a
genuinely single-NAT network would produce. The function has no way to
tell "this network really is single-NAT" apart from "the trace
couldn't even attempt hop 1 because the interface was momentarily
down."

**The code's own doc comment already named a narrower version of this
exact risk, and underestimated it.** `TracerouteViewModel.swift:210-214`:
"a hop-1 timeout on an otherwise-stable double-NAT'd network could
misclassify a single trace as single-NAT... this is rare... the next
trace self-corrects since only a genuine change logs anything." True as
far as it goes, but the self-correction only happens *after* a real,
wrong entry is already written to the permanent Events log — a
misleading durable record, not just an invisible internal state blip
that quietly resolves itself. A fully empty `hops` array (not just a
missing hop 1 on an otherwise-live trace) is a stronger, more clear-cut
version of the same gap: the trace didn't run at all, rather than
running and getting an ambiguous answer.

**Fixed**: `logAddressingChangeIfNeeded` now returns immediately on an
empty `hops` array, before touching `lastKnownExtraNATState` at all —
"no data, skip evaluation," not "count = 0, genuinely single-NAT." The
next real trace still compares against whatever the last *real* trace
left behind, so a genuine change is still caught; only the blip itself
no longer writes anything. Same "no interface means a certain
consequence, not genuine uncertainty" special-casing
`ContentView.swift`'s `peRouterLayer`/`publicIPLayer` already apply for
an analogous reason. Verified: 115/115 unit tests, `test-max.sh`'s UI
tests and live scenarios, all pass.

### Footer buttons truncate ("Expert Mod…", "Networks…") in the popover

- **Status**: Fixed
- **Severity**: Low — cosmetic; every button still works, VoiceOver is
  unaffected (`accessibilityLabel` carries the full name regardless of
  what's visibly truncated).
- **Found in build**: `ec9b878+` — read from the popover's own footer
  line, confirmed live.
- **Fixed in build**: not yet released — see git log
- **First reported**: field-tested live at an off-site location
  ("the labels for the expert and networks buttons get truncated.
  Enlarge or reduce text?").

The popover's footer (`ContentView.swift:390`, `footerBar`'s `HStack`)
packs 7 buttons — Refresh, Screenshot, Bug Report, Expert Mode…,
Networks…, Preferences…, Quit — into the popover's fixed `.frame(width:
560)` (`ContentView.swift:172`/`190`) with the `HStack`'s default
spacing. "Expert Mode…" is long enough that it doesn't fit, and SwiftUI
truncates the `Text` to "Expert Mod…" — its own trailing "…" (part of
the label text itself) compounding with the system's added truncation
ellipsis.

Confirmed this isn't a documented, tuned constraint the way the
popover's *height* budget is (`SectionLayout`'s 17pt/row calibration,
explained at length elsewhere in this codebase) — `grep`ing
`DESIGN-NOTES.md` for `560` turns up nothing. The width appears to be
an unremarked constant, not a deliberately chosen one.

**Fixed**: tightened the footer `HStack`'s spacing to 4pt (was the
default 8) — the least invasive of the three ranked options, tried
first, and sufficient on its own; confirmed live via a real popover
screenshot, no truncation anywhere in the row. Font size and the fixed
560pt frame were never touched. Separately, shortened the visible
label "Expert Mode…" to "Expert…" (kept the ellipsis, for consistency
with "Networks…"/"Preferences…" in the same row) — not required for
the fix, but buys back margin against the next footer addition.
`accessibilityLabel("Expert Mode")` is unchanged, same "visible text
and VoiceOver label can differ" precedent `footer.networks`
("Networks…" / "Known Networks") already established. Verified:
115/115 unit tests, `test-max.sh`'s UI tests and live scenarios, all
pass.

### Speed Test times out on a real degraded connection, with no telemetry to say why

- **Status**: Fixed
- **Severity**: Low — the test correctly fails visibly ("The request
  timed out.") rather than silently, but there's no way to diagnose
  *why* after the fact, and no user-facing recourse beyond retrying.
- **Found in build**: `ec9b878+` — read from the Expert Mode window's
  own footer line, confirmed live.
- **Fixed in build**: not yet released — see git log
- **First reported**: field-tested live at an off-site location
  ("the speedtest timed out. slow network?").

**Not what it first looked like**: the Wi-Fi signal reading captured
directly alongside the failure is genuinely good — `-58 dBm`,
`SNR 43 dB`, `86 Mbps` PHY rate — not the weak-signal case "bad wifi"
suggests. Whatever caused the timeout is more likely upstream
instability (this network is confirmed double-NAT'd, "Multiple layers
(2 hops)," per Path to Internet's own live trace this session) than a
poor local radio link to the AP.

**`NetworkQualityService.swift`'s design already does what a first
instinct here would suggest** — raised directly this session before
checking: "starting with a small download might be good." It already
does exactly that: a 2MB probe first, escalating to the full 25MB only
if the probe finishes under 2 seconds
(`NetworkQualityService.measureDownload`/`measureUpload`). That the
timeout still happened despite this means either the 2MB probe itself
couldn't complete (a very poor link), or — more interesting — the
probe finished under the 2s threshold on a brief good moment, escalated
to the full 25MB, and *that* transfer hit real trouble a probe-based
heuristic can't see coming. Both are real possibilities; nothing
available distinguishes them.

**Checked and confirmed a real diagnostic gap**: `grep`ing
`~/Library/Logs/NMS/ui-state.log` for `NetworkQualityViewModel` across
this entire session returns nothing at all — unlike
`TracerouteViewModel`/`ConnectivityViewModel`, this view model was
never wired into the UI state logger (`UIStateLogger`). So there's no
way to tell, after the fact, which stage (probe or full transfer) was
in flight when the 45s timeout fired, or how far it got.

**Fixed**, both parts named in the original writeup:
1. **Instrumentation**: `isRunning`/`lastError`/`recentRuns` all gained
   `didSet { UIStateLogger.log(...) }`, the same pattern every other
   instrumented view model already uses — a future timeout is now
   visible in `ui-state.log`/state dumps/bug reports.
2. **Separate, shorter probe timeout**: `NetworkQualityService`'s probe
   stage (2MB) now uses its own 10s per-request timeout
   (`URLRequest.timeoutInterval`, overriding the session's default)
   instead of sharing the full transfer's 45s — a genuinely dead link
   now fails during the small probe in 10s rather than waiting out the
   full 45s meant for a large payload over a slow-but-alive connection.
   The full-transfer stage keeps its 45s, now set explicitly
   (`fullTransferTimeout`) rather than only implicitly via the session
   default. The session's own `timeoutIntervalForResource` (the
   wall-clock cap, as opposed to the idle-gap one `timeoutInterval`
   overrides) is unchanged at 45s underneath either way.

Verified: 115/115 unit tests, `test-max.sh`'s UI tests and live
scenarios, all pass. Not verified against a real degraded connection
matching the original report — that needs a genuinely bad link to
reproduce, same limitation the original report had.

### ISP identification gets wiped by a flaky Wi-Fi reconnect and never recovers

- **Status**: Fixed
- **Severity**: Medium — real, misleading behavior (a working feature goes
  silently and indefinitely blank), but not crashing and not blocking the
  app's main network-health purpose.
- **Found in build**: `ec9b878+dirty` — read directly from the app's own
  `bugReportCaptured` events logged this session ("Build ec9b878+dirty"),
  not guessed from `git log`.
- **Fixed in build**: not yet released — see git log
- **First reported**: field-tested live at an off-site location
  ("not seeing the isp info. did a path to internet scan."), diagnosed
  from `~/Library/Logs/NMS/ui-state.log` and confirmed independently via
  a direct `curl` RDAP lookup against the live public IP, not assumed.

The ISP row (`ContentView.swift:770`, `if let name =
ispIdentity.organizationName`) is deliberately omitted entirely rather
than shown as "—" while unresolved — correct for "hasn't finished
looking yet," but it means a *stuck* nil looks identical to "still
loading" or "genuinely nothing found," with nothing to tell them apart.

**The RDAP lookup itself was never the problem — confirmed working
twice, independently:**
- The app's own `ui-state.log` shows `ISPIdentityViewModel.organizationName`
  correctly resolving to `"Comcast Cable Communications, LLC"` at
  `17:39:23.915Z`, seconds after joining the off-site network's Wi-Fi.
- A direct `curl -L https://rdap.org/ip/203.0.113.10` (the same public IP
  logged by the app) returns the identical result right now, independent
  of the app entirely.

**What actually happened, reconstructed from `ui-state.log`'s precise
timestamps**: the Mac's Wi-Fi flapped three separate times in about 10
seconds while joining the off-site network (matches direct field
observation: "bad wifi quality while sitting outside"):

```
17:39:20.211  organizationName → nil       (reset: joining OffSiteWiFi)
17:39:20.307  Event: wifiNetworkChanged Thistle → OffSiteWiFi
17:39:21.447  Event: publicIPChanged to 203.0.113.10
17:39:23.915  organizationName → "Comcast Cable Communications, LLC"  ✓ succeeded
17:39:24.641  NetworkMonitorViewModel.lastChangeAt updates again (2nd flap)
17:39:24.646  organizationName → nil       (reset: wiped 731ms after succeeding)
17:39:24.730  Event: interfaceDown
17:39:30.561  interface back up again (3rd flap, same OffSiteWiFi/192.168.1.56)
17:39:30.565  organizationName → nil       (still nil — no further attempt)
```

No further `ISPIdentityViewModel.organizationName` log line appears for
the rest of the session (checked through `17:46`, ~7 minutes later) —
it never recovers on its own.

**Root cause: an unconditional reset paired with a conditionally-gated
re-fetch, confirmed by reading both sides.** Every network-change event
calls `ispIdentity.reset()` unconditionally
(`NMSApp.swift:368-372`) — correct, this is what stops stale ISP info
from one network showing up on another. But the *only* thing that
re-populates it, `ispIdentity.identify(ip:)`, is normally called from
`PublicIPViewModel.onCurrentIPChanged` (`NMSApp.swift:492-494`), which
`PublicIPViewModel.apply(_:)` only fires `if previousIP != currentIP`
(`PublicIPViewModel.swift:84-85`) — i.e., only on an actual IP *value*
change, not on every check. When the second/third flap's `publicIP.check()`
resolved back to the same `203.0.113.10` already recorded from the first
flap, the "changed" guard correctly stayed silent — but `reset()` had
already unconditionally cleared the display moments earlier, and nothing
else was left to call `identify(ip:)` again.

**The developers already recognized this exact class of gap once, but
only patched it for the launch case, not this one** —
`NMSApp.swift:233-238`'s own doc comment: "`publicIP.currentIP` may
already be a cached value from last launch, in which case
`onCurrentIPChanged` below would never fire this session since nothing
actually *changed*," which is why launch calls `ispIdentity.identify(ip:
publicIP.currentIP)` directly rather than relying solely on the
callback. The post-reset case after a network change has no equivalent
direct call, and the flaky-Wi-Fi scenario above is exactly the case
that doc comment's own reasoning already describes, just triggered by a
mid-session reconnect instead of app launch.

**Fixed**: `NMSApp.swift`'s topology-change handler now calls
`ispIdentity.identify(ip: publicIP.currentIP)` directly right after
`ispIdentity.reset()`, the same direct-call pattern `NMSApp.init()`
already used for the equivalent launch-time race — rather than
depending solely on `onCurrentIPChanged`'s value-change guard to
eventually re-trigger it. `identify(ip:)`'s own `nil`-ip guard makes
this a no-op if nothing's known yet. Verified: 115/115 unit tests,
`test-max.sh`'s UI tests and live scenarios, all pass.

### Confirmed ISP Edge Router hop isn't scoped per network — a stale confirmation from one network silently carries over to the next

- **Status**: Fixed
- **Severity**: Medium — misleading, not crashing: the ISP Edge Router
  row can show green/"confirmed" on a network where nothing was ever
  actually confirmed, with no way to tell from the UI alone.
- **Found in build**: `ec9b878+dirty`, read from the app's own recent
  `bugReportCaptured` events.
- **Fixed in build**: not yet released — see git log
- **First reported**: field-tested live, moving from an off-site
  location to a coffee shop — asked directly whether Path
  to Internet had auto-selected the right hop there, then confirmed
  directly that it hadn't, in the sense that mattered.

**`TracerouteViewModel.monitoredHopNumber` is a single, global
`UserDefaults` value** (`NMS.monitoredHopNumber`, `TracerouteViewModel
.swift:74,78`) — unlike every other piece of comparable state in this
app (SNMP devices, DHCP history, Events, provider-edge history), which
is all scoped per network via `networkFingerprint`. Confirmed directly
via `defaults read Thistle.NMS NMS.monitoredHopNumber` → `3`, and via
`ui-state.log`:

```
17:09:07  monitoredHopNumber = 2     (home network — single-NAT, hop 2 is the real edge)
17:54:07  monitoredHopNumber = nil  (cleared while transitioning to the off-site network)
17:54:11  monitoredHopNumber = 3    (manually re-confirmed at the off-site network — double-NAT, hop 3 is the real edge there)
```

That `3` is still what's stored now, on a third, unrelated network
(the coffee shop) — nothing cleared or re-asked when the network
changed again. **It happens to still read correctly here only by
coincidence**: this coffee shop's trace independently turns out to have
the same shape as the off-site network's (two private hops, first
public address at hop 3) — confirmed by comparing both real traces
directly, not
assumed. Had this network's topology been shaped differently (say, a
simple single-NAT setup where hop 2 is the real edge, or a longer
corporate-style chain), hop 3 would have silently been monitored and
shown as "confirmed" regardless of whether it was actually the ISP
edge on *this* network at all.

**Root cause, by inspection**: `monitorHop(_:)` writes directly to a
fixed `UserDefaults` key with no `networkFingerprint` tagging, and
`init` reads that same fixed key back on every launch
(`TracerouteViewModel.swift:76-78`) — there's no per-network table the
way `SNMPDeviceRecord`/`AppEventRecord` already use, just one persisted
integer, global across every network this Mac ever joins.

**Fixed**: added `KnownNetwork.confirmedEdgeHopNumber` — a per-network
column, the same per-network singleton shape `KnownNetwork.label`
already uses, rather than a second global `UserDefaults` key or a new
timeline table (this needs "the one current value for this network,"
not a change history the way `ProviderEdgeRecord` is). `SnapshotStore
.confirmedEdgeHopNumber()`/`.setConfirmedEdgeHopNumber(_:)` read and
write it scoped to `currentNetworkFingerprint`, mirroring
`latestProviderEdge()`'s own pattern exactly. `TracerouteViewModel
.monitorHop(_:)` now writes through this instead of `UserDefaults`, and
a new `reloadMonitoredHop()` re-reads it — wired into `NMSApp`'s
topology-change handler right after `networkIdentity.reset()` (clearing
a stale confirmation immediately, before it can be silently
re-persisted against the new network by `persistMonitoredHopIfNeeded`)
and again from `networkIdentity.onNetworkRecognized` (populating the
*new* network's own confirmation once it's known) — the same two-beat
reset/re-populate shape as the ISP identification fix directly above.
Verified: 115/115 unit tests, `test-max.sh`'s UI tests and live
scenarios, all pass.

### SNMP device `sysDescr` truncated to one line live, despite no `lineLimit`

- **Status**: Fixed
- **Severity**: Low — cosmetic, readable via the device's admin page link,
  and only affects devices whose `sysDescr` is long enough to wrap.
- **Found in build**: `a59755c`
- **Fixed in build**: not yet released — see git log
- **First reported**: field-tested and filed through the app's own Bug
  Report button ("snmp needs more space for text",
  `NMS-2026-08-01-165919.png`), then diagnosed live at the user's direct
  prompt ("in snmp devices the switch needs more space for text. a
  third line?").
- **Screenshot**: ![SNMP Devices, Switch's sysDescr split cleanly across two full lines, router's row unclipped above it](images/bugs/NMS-2026-08-01-snmp-sysdescr-fixed.png)

`infrastructureRows`' `sysDescr` `Text` (`ContentView+Window.swift`) had
no `lineLimit`, deliberately — SNMP-provided strings have no length
guarantee, so it was meant to wrap to as many lines as it needs rather
than truncate. It did exactly that in a plain `VStack`, but the live
app boxes this section in `NoBounceScrollView` (an `NSHostingView`
inside an `NSScrollView`, see that type's own doc comment for why
that's a bespoke replacement for `ScrollView` at all) — and *there* it
truncated to one line with a "…" for any `sysDescr` long enough to
wrap, exactly the case this network's own "Switch" device hits
(`GC108P 8-Port Gigabit Ethernet PoE+ Insight Managed Smart Cloud
Switch with 8 PoE+ Ports (64W), Software Version 1.0.8.9, Boot Version
1.0.0.3`).

**The bug report's own attached screenshot didn't show any of this**,
which is what made it non-obvious at first: `captureBugReport`/`capture`
render with `isCapturingScreenshot = true`, which makes `scrollBox`
skip `NoBounceScrollView` entirely and render the section as a plain,
unclipped `VStack` instead — the workaround already in place for
`ImageRenderer` not rendering `NSViewRepresentable`/`ScrollView`
content off-screen at all (see that function's doc comment). That
workaround means the capture path never actually exercises the layout
the live window uses, so it couldn't reproduce this bug even though it
was the thing being reported. Confirmed only by scrolling the real
running app directly (dragging `NoBounceScrollView`'s `NSScroller`,
screenshotted live) and comparing against the attached report
screenshot by hand — see the punchlist item on the capture mechanism
itself.

**Three auto-wrap fix attempts tried live, each reverted** before
landing on the real fix — every one that made the `Text` itself wrap
correctly introduced a *worse*, unrelated regression in the same box:
the list's first row (`router`) rendering permanently clipped a few
points from its own top, confirmed and un-reproduced live by
adding/removing the fix alone, repeatably:
1. `.fixedSize(horizontal: false, vertical: true)` on the `sysDescr`
   `Text` — the same fix already in place on `PreferencesView
   .caption(_:)` for an analogous problem (a `Text` rendering within
   whatever height its parent *proposes* rather than what its wrapped
   content needs). Fixed the wrap; clipped `router`.
2. The same `fixedSize`, moved to the whole per-device row instead of
   just the `Text` — same result.
3. `NSHostingView.sizingOptions = [.standardBounds,
   .intrinsicContentSize]` (macOS 13+, Apple's own documented switch for
   `NSHostingView` tracking its SwiftUI content's true intrinsic size)
   in `NoBounceScrollView.makeNSView`, plus explicit
   `invalidateIntrinsicContentSize()`/`layoutSubtreeIfNeeded()` calls in
   `updateNSView` on every content update. `sizingOptions` *alone*
   (no `fixedSize` anywhere) left `router` unclipped but didn't fix the
   wrap either. Adding `fixedSize` back on top reintroduced the
   `router` clip again. The explicit invalidate/layout pair fixed
   neither problem and was dropped outright on its own merits: forcing
   a synchronous relayout on every SwiftUI diff is a real, needless
   performance cost on the Events box specifically, which can hold
   hundreds of rows. `sizingOptions` itself was kept in
   `NoBounceScrollView.makeNSView` regardless — a real, low-risk,
   Apple-documented improvement independent of this bug.

Root cause of the `fixedSize`/clipping interaction was never pinned
down — genuinely looks like a SwiftUI/AppKit interop issue inside
`NSHostingView`'s intrinsic-size negotiation with its enclosing
`NSScrollView`, not this app's own logic.

**Actually fixed** by sidestepping the whole class of problem instead
of continuing to fight it: `sysDescr` no longer relies on one
auto-wrapping `Text` at all. `infrastructureRows` now splits it into at
most two separate `Text`s (`Self.sysDescrLines(_:)`), each with its own
`lineLimit(1)` — the same deterministic, single-line sizing
`addressLine` right above it already uses safely in this exact box.
Splitting happens once per render, breaking at the space nearest the
string's midpoint so neither line is wildly longer than the other;
short `sysDescr` strings (the common case) come back unsplit. No
dynamic multi-line `Text`, no intrinsic-height renegotiation with
`NSHostingView` — nothing left for that interop issue to affect. Worst
case (a single word too long for one line, or a description that
genuinely needs a third line) still degrades to a plain "…" on the
affected line, never worse than the original bug, and the common case
(this exact "Switch" device) now reads cleanly across two full lines.

The SNMP Devices box's fixed height (`SectionLayout.boxHeight`, 300pt
on `.window`, bumped from 250pt on request for unrelated breathing
room) was unaffected by any of this — confirmed independently at both
values.

### Two overlapping-round races found by code review, not live reproduction

- **Status**: Fixed
- **Severity**: Medium for the SaaS one (corrupts durable event-log
  history, not just a live UI glitch), Low for the printer one (a
  delayed `runChecks()` trigger, self-correcting on the next round).
  Both conditionally reachable rather than everyday — see below.
- **Found in build**: not observed live — found by a systematic code
  review of all 28 `Task {}` launch sites across the ViewModels layer,
  checking each against the pattern that caused the Wi-Fi/Ethernet flap
  race (`42a5079`): a deferred completion applying results with no
  check that its trigger is still current. Reasoned through, not
  reproduced against a real incident, unlike almost everything else in
  this file — flagged here rather than left unrecorded because the
  reasoning is concrete enough to act on, not a vague suspicion.
- **Fixed in build**: `137937e`

**`SaaSMonitoringViewModel.checkAll()` had no overlap guard, unlike
every sibling periodic-check view model in this codebase**
(`ConnectivityViewModel.runChecks`, `SNMPViewModel.scan`/`poll`,
`LANDiscoveryViewModel.scan`, `NetworkQualityViewModel.run`,
`PublicIPViewModel.check`, `DHCPLeaseViewModel.check` all guard
re-entrance with an `isRunning`/`isChecking`/`isScanning` flag).
`checkAll()` is timer-driven on `checkInterval` (300s), accelerated by
`NMSPollSpeedup` like everything else — once that interval shrinks
below the time three concurrent WAN status-page fetches actually take,
a second round can start while the first is still in flight, with no
ordering guarantee between the two rounds' real network fetches. The
older round's `apply(_:)` landing *after* the newer one's would
overwrite fresher `previousIndicators` state with stale data —
spuriously re-logging a transition that already happened, or silently
swallowing a real one. **Fixed**: added `isChecking`, same idiom every
sibling already uses; a dropped round is harmless since the next timer
tick re-checks regardless.

**`ConnectivityViewModel.refreshConfiguredPrinters()` had no overlap
guard, unlike its two siblings in the same file** (`runChecks`'s
`isChecking`, `refreshPrinterAlerts`'s `isRefreshingPrinterAlerts`).
Called from `init()` and from `NMSApp`'s topology-change handler — and
rapid topology changes are the exact real-world trigger class that
caused the Wi-Fi/Ethernet flap race in the first place. Two changes
close together could start two overlapping `configuredNetworkPrinters()`
reads; whichever completion landed second would win regardless of
which read was actually fresher, leaving `configuredPrinters`
reflecting a stale read and computing `changed` against it incorrectly.
**Fixed**: added `isRefreshingConfiguredPrinters`, same idiom.

**Verified**: 79/79 tests, clean build. Not verified against a live
repro for either — by construction, neither race has actually been
observed to happen; both are prevented on the same reasoning basis
they were found on, matching how deterministic timing issues in async
Swift code are normally caught before they manifest, not after.

### A network-transition event can be filed under the wrong network's Events tab

- **Status**: Fixed
- **Severity**: Low — one event, names both networks by design, nothing
  about the origin network's other history is exposed. Real, but narrow.
- **Found in build**: not recorded — reported before this field existed
- **Fixed in build**: not recorded — see git log (`NetworkIdentityViewModel
  .reset()` returning the departing fingerprint)
- **First reported**: off-site testing

In `wireTopologyChangeFanOut`, `networkIdentity.reset()` (clears
`currentNetworkFingerprint` to `nil`) ran *before* `wifiSSID.refresh(...)`
in the same closure. `WiFiSSIDViewModel.sample()` →
`logNetworkChangeIfNeeded` logged the `"X → Y"` event while the
fingerprint was already `nil`, since `lanDiscovery.scan()` (and therefore
`recognize()`) is async and hadn't resolved the new network yet.
`adoptUntaggedRecords` then swept that `nil`-tagged event into whichever
network resolved next: the new one.

So previously: leaving "Thistle" for "Guest" logged an event that named
Thistle but lived under Guest's Events tab.

**Fixed by taking the "log under the old fingerprint" option** — the one
argued as "arguably more correct" (the transition is what just ended),
and the only one of the three original options that didn't require a
bigger change: "leave it" doesn't fix anything, and "log under both"
would need `AppEventRecord` to carry more than one fingerprint, which
its schema doesn't support. `NetworkIdentityViewModel.reset()` now
returns the fingerprint it just cleared; `NMSApp`'s topology-change
wiring captures that and threads it through
`wifiSSID.refresh(departingNetworkFingerprint:)` →
`logNetworkChangeIfNeeded` → a new optional override parameter on
`SnapshotStore.logEvent`, so this one event is tagged with the network
it's actually about instead of falling back to
`currentNetworkFingerprint`'s live (by then already-moved-on) value.
Every other `logEvent` call site is unaffected — the override defaults
to `nil`, meaning "use whatever's live," today's behavior everywhere
else.

### First traceroute after joining a network reports inflated latency

- **Status**: Fixed
- **Severity**: Medium — misleading data shown right after every new
  network join, not a crash or data loss.
- **Found in build**: not recorded — reported before this field existed
- **Fixed in build**: not recorded — see git log (ping-based hop RTT
  enrichment)
- **First reported**: off-site testing

`traceroute -n -q 1 -w 1 -m 4` sends exactly one probe per hop with no
retry, and runs immediately on topology change — before a fresh Wi-Fi
association has settled. Same class of bug this app has hit before (DNS
answers served from a stale cache, HTTP likewise): the *first*
measurement after a network event isn't representative, and nothing
previously distrusted it.

**Fixed differently from either originally-proposed option.** Both
proposals (re-run the trace a few seconds later; don't trust the first
trace's latency) treated the symptom as specific to the moment right
after a topology change. The actual root cause is broader: a single,
unretried probe (`-q 1 -w 1`) is inherently noisy timing, not just
unreliable right after a network event. Traceroute now stays
discovery-only (finding the path and the hop addresses); each
responsive hop gets pinged directly right after the trace
(`TracerouteViewModel.enrichRoundTrips`, via `ConnectivityService`, the
same mechanism already trusted for the confirmed ISP edge router's
ongoing latency), and that real ping RTT replaces traceroute's own
number in place. `TracerouteHop.roundTripMs` is `var`, not `let`, for
exactly this — the same "patch in after the fact" shape `hostname`
already used for reverse-DNS enrichment. Verified live: hop RTTs update
across successive pings (0.5ms router, 1.8ms ISP edge, 4.9–10.2ms third
hop — all real, small numbers for genuinely nearby destinations),
confirming the ping-based values are live and replacing the trace's own
timing rather than sitting static.

### No window comes to the front on the MacBook

- **Status**: Fixed, confirmed on the MacBook — see below for a second,
  related gap found and fixed during confirmation.
- **Severity**: High — three separate entry points (Open in Window,
  Preferences, Known Networks) completely broken on this machine, while
  all three work on the iMac from the same build.
- **Found in build**: not recorded
- **Fixed in build**: `f92b584` (`ContentView.openWindowInFront`);
  auto-open gap below fixed same session, MacBook-local at time of
  writing
- **First reported**: off-site testing
- **Confirmed via**: [GitHub issue #6](https://github.com/PJorgens61/NMS/issues/6),
  the MacBook reproducing it live and posting `sw_vers` + the
  `openWindowInFront` log line

That it's *all three* windows is the important part: this isn't a
per-window bug, the whole `openWindowInFront` mechanism is inert on this
machine, so the cause is machine-level, not per-window logic.

**Confirmed: macOS tightened focus-stealing.** The MacBook is on
**macOS 26.5.2** (Build 25F84) against the iMac's 15.7.7 — a real,
large version gap. Reproducing the bug there and clicking Known
Networks logged:

```
ContentView.openWindowInFront | known-networks → known-networks
```

A clean match — `makeKeyOrderFront` ran — but the window still never
came to front; another app (Notes) ended up frontmost instead. That
rules out the timing hypothesis outright (a timing miss would have
logged `NO WINDOW MATCHED`) and confirms the other branch: the specific
window *is* found and made key within this app's own window list, but
the *application itself* never becomes frontmost, so another app's
windows keep rendering on top of it regardless of what NMS did to its
own window.

`NSApp.activate(ignoringOtherApps: true)` has been deprecated since
macOS 14, and later versions increasingly decline to let a background
app pull itself forward this way — exactly this. **Fixed**: swapped to
the modern, no-parameter `NSApp.activate()` in
`ContentView.openWindowInFront` — the window-matching half already
worked correctly and needed no changes. Deployment target is already
macOS 14+, so no availability guard needed.

Built, tested (64/64), relaunched on the iMac without issue — but
that's not a real test of the fix itself, since 15.7.7 never exhibited
the bug in the first place. This needs the MacBook to actually confirm
it.

Background: foregrounding was fixed twice already for the iMac.
`0f8f80e` added `NSApp.activate`; `1ca9dc8` deferred a run loop turn and
then ordered the specific window front by identifier. Neither touches
application-level activation the modern way, which is what this
machine-specific gap needs.

**Confirmed on the MacBook**: pulled `f92b584`, rebuilt, retested all
three entry points. Known Networks and Preferences both now come
correctly to the front — verified visually (screenshots, not just the
log) for both, not just a clean log match this time.

**A second, related gap found during that confirmation, on the same
machine**: `MenuBarLabel.autoOpenWindow` (this session's DEBUG-only
launch-time auto-open, added for headless/scripted verification — see
`PUNCHLIST.md`) calls plain `openWindow(id:)` directly, with none of
`openWindowInFront`'s activation/ordering logic. It's a separate code
path the iMac's fix never touched, and it turned out to have the exact
same failure mode: the window existed but sat behind other apps after
auto-opening at launch. Fixed the same way — added the identical
`NSApp.activate()` + `makeKeyAndOrderFront` sequence, deferred one run
loop turn, to `MenuBarLabel`'s `.task`. Verified visually after
rebuilding: the window is now genuinely frontmost immediately at
launch, confirmed against a live screenshot, not just the resulting log
line (`MenuBarLabel.autoOpenWindow | nms-window → nms-window`).

### "Stamp build info" wrote nothing on the MacBook — footer showed "Build unknown"

- **Status**: Fixed, confirmed on the MacBook against a from-scratch
  DerivedData rebuild plus the full test suite
- **Severity**: Medium — the build-hash label `4104b24` exists
  specifically to make trustworthy was silently absent on every build on
  this machine; not a crash or data loss, but it defeated the exact
  stale-binary detection that caught the persistent store bug above.
- **Found in build**: `unknown` (that's the bug)
- **Fixed in build**: `8da2a9a`+ (see commit)
- **First reported**: filed live via Bug Report, 2026-07-31 13:53 —
  "build id is missing from footer" / "build # is missing from footer"
- **Confirmed via**: reproduced the missing stamp from a completely
  unsandboxed Terminal.app build (ruling out a coding-agent tool sandbox
  as the cause, which was suspected for a while — see the dead end
  below), then fixed and reconfirmed the same way

**Root cause**: the "Stamp build info" script phase (`4104b24`)
declared no inputs and no outputs at all. Xcode's build system had no
way to know the phase needed to run *after* `ProcessInfoPlistFile` —
the built-in phase that generates `Info.plist` from scratch on every
build — so on this machine the two ran in the wrong order: the stamp
script wrote `NMSGitHash`/`NMSGitSubject`/`NMSGitDirty` successfully
(confirmed by having the script read its own write back immediately
after writing it, matching every field written), and then
`ProcessInfoPlistFile` ran afterward and regenerated the whole file
from the template, silently erasing the stamp. That's exactly why it
looked so strange: no error anywhere, a write that succeeded and read
back correctly within the script's own process, yet gone from the same
file (same inode, checked directly) moments later.

**Fix**: declared the built `Info.plist` as an **input** to the "Stamp
build info" phase (`$(BUILT_PRODUCTS_DIR)/$(INFOPLIST_PATH)`), forcing
the build system to run the stamp script after the file that must
already exist for it to modify. Tried declaring it as an *output*
first — the more conventional fix for "my script phase writes this
file" — but that fails outright: `ProcessInfoPlistFile` already
produces that path, so two declared producers of the same file is a
build-graph conflict Xcode refuses to build (`process command with
output ... Info.plist ... depends on ... script phase`). Declaring it
as an input instead establishes the same ordering without claiming to
be a producer.

Verified three ways: incremental rebuild, a full DerivedData wipe (so
the fix doesn't depend on any stale incremental-build state), and the
full test suite (79/79 passing). All three from a plain Terminal.app
build, not through any tool-mediated shell.

**A real dead end along the way, worth recording**: for a while this
looked like it might be an artifact of the coding-agent tool's own
sandboxed shell rather than a genuine project bug — every build up to
that point had gone through it, and Full Disk Access experiments
(needed to check the unified log for a sandbox denial) went down a
separate rabbit hole (the FDA grant needed to go to the actual nested
`com.anthropic.claude-code` bundle, not the outer desktop app, and
neither ultimately explained the symptom). Reproducing the missing
stamp from a completely unsandboxed Terminal.app build ruled that out
directly and pointed back at the real, machine-independent ordering bug
above.

### The persistent store fails to open, and every launch silently starts empty

- **Status**: Fixed
- **Fixed in build**: `7d6db05`+ (see commit below)
- **Severity**: High — the Events log, DHCP History and every other
  persisted history are the app's core record, and all of them read as
  empty on a store that demonstrably holds 230 events. Nothing on screen
  says anything is wrong: an empty Events list renders the friendly
  "No events yet — everything's healthy" copy, which is exactly the
  reading a user would trust.
- **Found in build**: `d20af0a+dirty` (also present on `dead27c+dirty`,
  so it predates today's UI work)
- **First reported**: found incidentally on 2026-07-31 while running the
  test suite for an unrelated UI change — *not* reported by a user, which
  is itself the concerning part

CoreData refuses to migrate the store and `NMSApp.makeModelContainer()`
catches it and falls back to `isStoredInMemoryOnly: true`:

```
Cannot migrate store in-place: Validation error missing attribute values
on mandatory destination attribute
entity=KnownNetwork, attribute=routerMAC
```

`KnownNetwork.routerMAC` and `.subnet` are non-optional `String`s added
in `e2f9ba2`. SwiftData's lightweight migration can't add a mandatory
attribute to a table that already has rows, and there's no
`SchemaMigrationPlan` in the project to do it the heavy way.

**What's verified.** On disk, `ZKNOWNNETWORK` has no `ZROUTERMAC` or
`ZSUBNET`, and `ZAPPEVENTRECORD` has no `ZNETWORKFINGERPRINT` — all three
added in `e2f9ba2`. The live app logs `EventLogViewModel.events | []`
exactly once at startup and never again, against 230 rows in the file.
The 11:26 bug-report screenshot from earlier the same day already showed
"No events yet," so this is not new today. Data is **stranded, not
destroyed** — the file is intact and every row is still readable via
`sqlite3`.

**The contradiction that looked impossible, resolved.** The newest event
*in the file* was 11:26:16 that same day, written into the old 6-column
table — which no build after `e2f9ba2` could have done. The answer was
that **the running app was a stale binary**: `e2f9ba2` landed
2026-07-30 11:00, and the `.app` actually running had been built
2026-07-29 12:26, before it. That binary's model matched the on-disk
schema exactly, so it opened the store and wrote to it happily. Only a
freshly-built binary hits the migration failure.

Two things hid this, and both are worth remembering:

1. **`BuildInfoService` reads the git hash at *runtime*, from a hardcoded
   checkout path** — so the footer showed `dead27c+dirty`, the repo's
   current state, on a two-day-old binary. The one indicator that should
   have caught "you're not running what you think you are" is
   structurally incapable of it. (Already documented as a limitation in
   that file, but the consequence hadn't been connected to this.)
2. **Two `DerivedData` directories exist** for this project, so a
   glob-based `open` could launch either one.

**Why it stayed invisible.** The fallback's only signal was a `print()`
to stdout, which nothing captures — not `UIStateLogger`, so not
`ui-state.log`, not the state dumps, not a bug report. Combined with an
empty Events list rendering as "everything's healthy," a database that
wouldn't open looked exactly like a quiet, well-behaved network.

**Blast radius.** Anyone whose store predates `e2f9ba2` and who builds
fresh — which is everyone, on their next build — loses all visible
history and persists nothing, with no indication.

**The fix**, three parts:

1. **`KnownNetwork.routerMAC`/`.subnet` are now derived from
   `fingerprint` rather than stored beside it.** `fingerprint` is defined
   as `routerMAC|subnet`, so the same values were being written twice and
   the copies could in principle disagree; storing them is what created
   two mandatory attributes lightweight migration can't add. *Dropping*
   attributes is something it handles fine, so removing them is what let
   the store open. Nothing queries or sorts on either — both are
   display-only — so no predicate needed them to be real columns.
2. **The fallback is loud now**: logged via `UIStateLogger` (so it lands
   in `ui-state.log`, state dumps and bug reports) and surfaced as a red
   popover banner — "Database unavailable — history is hidden and nothing
   is being saved" — with the underlying error as its tooltip.
3. **A latent second bug, exposed by fixing the first.** Once the store
   opened, Events *still* showed empty. `EventLogViewModel.refresh()` and
   `DHCPLeaseViewModel`'s history fetch both run in `init`, before the
   first LAN scan has identified the network, so both query with no
   fingerprint and come back empty — and nothing re-ran them. Events only
   re-read when a *new* event is logged, and events are logged on change,
   so a healthy network could sit showing "No events yet" over a full
   history indefinitely; DHCP history only re-read when a lease changed,
   typically a day out. Added
   `NetworkIdentityViewModel.onNetworkRecognized`, wired to re-read both.
   Latent all along, but unobservable while every record was untagged —
   the launch-time fetch matched them anyway.

**Verified against the real store**: migrates in place, 230/230 events
preserved, `PRAGMA integrity_check` ok, all 4 `KnownNetwork` rows intact
— including one legacy MAC-only fingerprint from before the subnet joined
the key, which now reports an empty subnet rather than failing.
`timesSeen` incremented 43 → 44 on the first run, confirming writes
persist again. The log shows `EventLogViewModel.events | []` at init
followed by the full history ~0.8s later, once recognition completes.
77 tests in 15 suites pass, including 4 new ones pinning the fingerprint
derivation and that legacy row.


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
- **First reported**: off-site testing

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
