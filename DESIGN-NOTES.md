# Design notes

Ideas discussed and worked through but not yet implemented. Each section is a
sketch, not a spec — enough to pick back up from later without re-deriving
the reasoning, not a promise of the exact eventual shape.

## DNS testing: is `dig` an alternative to `getaddrinfo`?

`DNSResolutionService` currently uses `getaddrinfo`, probing a freshly
randomized subdomain of `apple.com` on every check specifically to defeat
the resolver's own negative caching (a fixed hostname would get cached and
then silently mask a real outage — confirmed directly: disabling an
upstream switch didn't fail the check, because `apple.com` had already
resolved and cached before the outage started).

`dig` is available on macOS (`/usr/bin/dig`, BIND-derived) and was
considered as an alternative. Tested directly: `dig`'s two lookups of the
same random hostname took 8ms then 4ms — ordinary network jitter for two
independent round trips, nothing like `getaddrinfo`'s ~20x cache-hit
speedup (20ms → 1ms) on the identical query. That's because `dig`
implements its own minimal stub resolver and talks straight to whatever
nameserver is configured (here, the LAN router acting as a forwarder) — it
never goes through macOS's system resolver daemon (mDNSResponder) at all,
in either direction.

**What `dig` would gain:** the random-subdomain trick becomes unnecessary
(nothing to defeat), and it can target an explicit upstream server
(`dig @1.1.1.1 host`) — something `getaddrinfo` can't do, letting you
distinguish "my router's resolver is broken" from "the wider DNS chain is
broken."

**What `dig` would lose:** `getaddrinfo` is what every other app on the Mac
actually uses to resolve names, so it reflects VPN split-DNS, search
domains, and resolver ordering the way a browser would see them. Because
`dig` bypasses mDNSResponder entirely, it can't catch the specific failure
mode where mDNSResponder itself is broken (hung, misconfigured, corrupted)
while raw UDP queries to the router still succeed fine.

There's also an availability question: `dig` is an external BIND-derived
binary Apple has been trimming from macOS over past releases (the same
concern already flagged for `snmpget` in `SNMPService`), whereas
`getaddrinfo` is a POSIX syscall that isn't going anywhere.

**Conclusion:** not a replacement. A `dig`-based probe against a specific
known-good server would be a legitimate *additional* check if we ever want
to distinguish "your resolver is down" from "DNS is down," at the cost of
one more shelled-out dependency in the ping/traceroute/arp/snmpget pattern
this app already uses. Left undone for now — no clear need yet.

## DHCP lease tracking

Most networks depend on DHCP, and the app currently has zero visibility
into it. Explored two questions: how to test/observe DHCP non-disruptively,
and how that would fit the app's existing persistence/event patterns.

### Non-disruptive observation

Forcing a fresh negotiation (`ipconfig set en0 DHCP`) is disruptive — it
tears down and rebuilds the live interface config, can drop active
connections, and isn't guaranteed to return the same IP. Ruled out for a
background health check.

**`ipconfig getpacket <interface>`** reads the *last* successful lease
locally — zero network I/O, since it's `configd` handing back the cached
ACK it already has. Verified against a real interface:

```
dhcp_message_type: ACK
server_identifier: 10.0.0.1
lease_time: 86400s (24h)
renewal_t1_time_value: 43200s (12h — RFC 2131's default 50% mark)
rebinding_t2_time_value: 75600s (21h — the default 87.5% mark)
router: 10.0.0.1
domain_name_server: 10.0.0.1
```

Honest caveat: this reflects the last successful negotiation, not "is the
server alive right now." A server that died five minutes after granting
this lease would still show a healthy-looking ACK from earlier.

**Self-assigned/link-local fallback (`169.254.0.0/16`, RFC 3927 APIPA)** —
if DHCP genuinely fails, macOS falls back to a self-assigned address. This
is checkable with zero network calls at all, just inspecting the IP the app
already has on hand. Confirmed nothing in `IPClassifier`,
`NetworkInterfaceInfo`, or `SystemConfigurationService` currently does this
check.

**DHCPINFORM** (RFC 2131 §3.4) — the protocol-correct way for a host that
already has an IP to ask a DHCP server for config without requesting or
renewing a lease. Genuinely non-disruptive at the protocol level, but there's
no bundled macOS CLI for it (unlike ping/arp/traceroute/snmpget) — it would
mean hand-rolling raw DHCP packet construction and UDP broadcast handling,
likely needing elevated privileges to bind port 68 or capture the reply.
Set aside: a materially bigger lift than the two options above for a signal
they largely already cover.

### Proposed design

Mirrors the existing `PublicIPRecord` / `PublicIPViewModel` pattern closely
rather than introducing a new one:

- **`DHCPLeaseInfo`** (value type, mirrors `PublicIPInfo`) — parsed from
  `ipconfig getpacket`: `serverIdentifier`, `assignedAddress`, `router`,
  `dnsServers`, `leaseSeconds`, `t1Seconds`, `t2Seconds`, `transactionID`
  (the `xid` field), `checkedAt`.
- **`DHCPLeaseService`** (mirrors `PublicIPService`) — shells out to
  `/usr/sbin/ipconfig getpacket <interface>` and parses the `key = value`
  output. No network I/O.
- **`DHCPLeaseRecord`** (SwiftData model, mirrors `PublicIPRecord`) — same
  fields as `DHCPLeaseInfo`, plus `firstObservedAt` (see Signal 2 below —
  this is the one field that doesn't mirror the existing pattern).
- **`SnapshotStore.recordDHCPLeaseIfChanged(_:)`** (mirrors
  `recordPublicIPIfChanged`) — persists a new row only when the server,
  address, or lease timing actually differs from the last record.
- **`DHCPLeaseViewModel`** (mirrors `PublicIPViewModel`) — timer-driven
  poll (candidate interval: 5–10 minutes; cheap since it's local-only, but
  needs to be frequent enough to catch a stalled renewal before full
  expiry), holding a `weak var networkMonitor` the way `ConnectivityViewModel`
  does, since Signal 1 needs the current interface IP.
- New `AppEventKind` cases, following the existing bracket convention
  (`interfaceDown`/`interfaceUp`): `.dhcpLeaseChanged` (neutral, like
  `.publicIPChanged`), and a failed/recovered pair — see open questions.

Edge case both signals need to guard: `ipconfig getpacket` returns no
`dhcp_message_type` at all for a statically-configured or down interface.
That has to short-circuit to "not applicable," not "failed."

### Signal 1: self-assigned fallback

Fully passive. Needs one addition: `IPClassifier.isLinkLocal(_:)`, written
exactly like the existing `isRFC1918(_:)` (octet check for `169.254.x.x`).
On each poll, compare the interface's current IP against this classifier:
flips *into* link-local → `.dhcpLeaseFailed` ("interface fell back to a
self-assigned address"); flips *out of* it → `.dhcpLeaseRecovered`. This is
the reliable, zero-cost signal — immediate and unambiguous when it fires.

### Signal 2: renewal stalled past T2

The harder one — `ipconfig getpacket` gives lease *durations*, not an
absolute grant timestamp, so the app has to establish its own clock. The
clean anchor is the `xid` (transaction ID): a genuinely new DHCP
transaction — initial grant, renewal, or rebind — always gets a fresh one.

1. The first time a given `xid` is observed, persist
   `DHCPLeaseRecord.firstObservedAt = now`. This has to be persisted, not
   just held in the view model — an in-memory-only clock resets on every
   app relaunch, silently losing track of how far into the lease the app
   actually is.
2. On every subsequent poll with an unchanged `xid`, compute
   `expectedT2At = firstObservedAt + t2Seconds`. If `now > expectedT2At`
   and `xid` still hasn't changed, the client should have started
   rebinding by now and hasn't — log `.dhcpLeaseFailed` ("renewal
   overdue").
3. When `xid` finally changes after that point, log `.dhcpLeaseRecovered`.
4. If `xid` changes *before* crossing T2 — the normal case, a renewal that
   succeeded on schedule — nothing failure-related is logged, only the
   ordinary `.dhcpLeaseChanged` if the lease's actual content changed. No
   false alarms for healthy renewals.

### UI surfacing

No new popover section needed. Fold the current lease's server/expiry into
the existing **Info** section (e.g. "DHCP Server: 10.0.0.1 · renews in
11h"), and let the existing **Events** list carry the change/fail/recover
entries — it already renders arbitrary `AppEventRecord`s by kind and
polarity color, so this is new `switch` cases, not new UI.

### Open questions before implementing

- One `AppEventKind` pair (`.dhcpLeaseFailed`/`.dhcpLeaseRecovered`) shared
  by both signals, or two distinct pairs so the event log can say *which*
  kind of failure it was? Leaning toward distinct — they're genuinely
  different failure modes and the message text alone might not be enough
  at a glance.
- Poll interval — 5 minutes trades faster failure detection for more
  frequent (though still free) subprocess calls; 15 minutes is cheaper but
  lets Signal 2 lag by up to that long.

## UI tooltips

The popover carries a fair amount of unexplained terminology by now — the
Network Health layer chain, status colors, the ISP Edge Router concept,
SNMP fields — and someone in the app's actual target audience ("small
networks and home labs," per the README) won't necessarily know all of it
on sight.

**Mechanism:** SwiftUI's `.help(_:)` modifier attaches a native macOS hover
tooltip to any view, essentially for free — a one-line addition per view,
no new component to build. Its key property for *this* app specifically:
zero layout cost. That matters a lot given the popover's whole history is a
fight for vertical space — LAN Devices and Bonjour Devices were removed
from the UI outright (not just collapsed) because the popover was still
too tall for a 13" screen even after every other space-saving pass. Unlike
an inline caption or legend, a tooltip adds explanatory depth without
consuming any of that scarce room.

**One thing to verify before writing two dozen tooltips' worth of copy:**
`.help()`'s behavior inside `MenuBarExtra(.window)`-hosted content is
untested here, and this project has repeatedly hit quirks specific to that
popover style (the menu bar icon needed a manual `NSImage` rasterization
workaround because a plain SwiftUI `Image` silently ignored
`.foregroundStyle`'s color; see `NMSApp.statusIcon`). `.help()` should work
the same as in any window, but "should" isn't confirmed for this specific
non-standard host. Worth a five-minute spike — one tooltip on one view,
confirmed to render — before investing in wording the rest.

**Content source:** mostly distillation, not fresh authoring. The README
and code comments already explain most of this well — e.g. the exact
"Interface → Network (SSID/Ethernet) → Local Router → ISP Edge Router →
DNS → HTTP" chain, `OverallStatus`'s critical/marginal/normal rules, why
the ISP edge router is defined as "the first non-RFC1918 traceroute hop."
Tooltip copy needs to be much shorter than any of that — a sentence, not a
paragraph — so the job is compressing existing explanations down, not
inventing new ones.

**Candidate elements** (roughly in order of how non-obvious they are, i.e.
where to start if doing this incrementally rather than all at once):

- The Network Health layer labels (Interface, Network, Local Router, ISP
  Edge Router, DNS, HTTP) — what each one actually checks
- The status colors themselves — what critical/marginal/normal mean, since
  the rule (interface down or router/internet/DNS/HTTP unreachable is
  critical; a monitored LAN device down alone is only marginal) isn't
  obvious just from looking at a colored dot
- Public IP — what it is and why it might change on its own
- Path to Internet / ISP Edge Router row — what a traceroute hop
  represents and why this one specifically is singled out
- Infrastructure (SNMP) fields — sysDescr/sysName/uptime, and what a
  "community string" is for anyone who's never touched SNMP before
- Wi-Fi SSID / recognized network — what "recognized" means here

Event log entries are lower priority for this treatment — they're already
short, plain-English prose messages (`"Public IP changed to X"`), not bare
labels, so they're closer to self-explanatory already.

### Open questions before implementing

- Confirm `.help()` actually renders correctly in this popover before
  committing to writing copy for everything.
- Do all candidate elements at once, or start with just the least
  self-explanatory ones (layer labels, status colors) and expand later?
- Tone/length convention for the tooltip text itself — one terse sentence,
  and don't just restate the visible label back at the user.

## Network Quality (speed / responsiveness) testing, on demand

Apple ships `/usr/bin/networkQuality` (confirmed present on this machine)
— the same test behind Settings → Network Quality Test. It measures
throughput (Mbps up/down) and, more interestingly, **responsiveness under
load**: RPM (round-trips-per-minute while the link is saturated), which is
essentially a bufferbloat measurement. This is a genuinely different kind
of signal from anything else in the app — every existing check tests
reachability and idle latency of small packets; this tests capacity and
behavior under stress.

### Why this doesn't fit the existing change-log pattern

`PublicIPRecord` and the proposed `DHCPLeaseRecord` are both change-logs —
a row only gets written when something is actually different from last
time. This doesn't fit that shape: every on-demand run is an intentional,
standalone data point the user wants to compare against past runs ("was it
worse last Tuesday during the call?"). It needs a genuine time series —
every run gets a row, no dedup logic — which makes it architecturally
distinct from every other persisted table in the app so far.

### Proposed design

- **`NetworkQualityService`** — shells out to
  `/usr/bin/networkQuality -c -s -M 45 -I <interface>`:
  - `-c` for JSON output. Confirmed via the man page: clean, documented
    schema — `dl_throughput`, `ul_throughput`, `dl_responsiveness`,
    `ul_responsiveness`, `base_rtt`, `interface_name`, plus handshake
    timing breakdowns.
  - `-M 45` as a safety cap, so a bad link doesn't leave the UI spinning
    indefinitely.
  - `-I <interface>` bound to whatever `NetworkMonitorViewModel
    .currentInterface` currently is, so on a multi-homed Mac the test
    measures the interface NMS is actually tracking, not whatever the OS's
    default route happens to pick.
  - `-s` (sequential rather than parallel up/down) is a real, worth-
    flagging tradeoff: the man page states `dl_responsiveness` /
    `ul_responsiveness` are **only emitted in sequential mode**. Parallel
    is faster but throughput-only; sequential is slower but captures the
    RPM/bufferbloat metric — the genuinely novel signal here. Leaning
    toward `-s` by default, since a user pressing "Run Speed Test" is
    already choosing to wait.
  - Availability guard mirroring `SNMPService.isAvailable` — this is an
    Apple-bundled tool, not a guaranteed-forever syscall.
- **`NetworkQualityResult`** (value type) — `downloadMbps`, `uploadMbps`,
  `downloadResponsivenessRPM: Int?`, `uploadResponsivenessRPM: Int?`,
  `baseRTTMs`, `interfaceName`, `testedAt`. RPM fields optional in case a
  run ever falls back to parallel mode.
- **`NetworkQualityRecord`** (SwiftData model) — same fields, persisted
  unconditionally per run via
  `SnapshotStore.recordNetworkQualityResult(_:)` — deliberately not
  "IfChanged" like the other record types, since every run is wanted.
- **`NetworkQualityViewModel`** — no timer, on purpose. Unlike every other
  view model in this app, this one has zero automatic trigger. `func run()`
  is the only entry point, called from a button press, dispatched to a
  background queue the same way `ConnectivityService`/`SNMPService`'s
  callers already do. This must never be added to `NMSApp.init()`'s
  launch-time kicks — the whole point is that it costs real bandwidth, so
  it must never run without the user asking. Worth a `cancel()` too,
  backed by `Process.terminate()` on the running subprocess: a 45-second
  worst case is long enough that "I didn't mean to start that" is a real
  scenario, unlike every other check in this app, which finishes in under
  a couple seconds.

### The dependency worth knowing about

"Record for historical comparison" runs straight into something already
flagged as unbuilt: the README's own "Suggested next steps" #1 is a
history view, and right now there's no timeline UI for *any* persisted
table — not `PublicIPRecord`, not `NetworkSnapshot`, nothing. Persisting
`NetworkQualityRecord` is easy; showing "how does today compare to last
week" is not, without that view existing.

Two ways to handle it:
- **Minimal MVP now** — a small inline "recent runs" list in the popover
  (last 5–10, mirroring `Path to Internet`'s already-established short-
  scrollable-list pattern), giving *some* historical comparison without
  waiting on the bigger feature.
- **Defer full comparison** to whenever the general history view gets
  built, and this becomes just one more table it reads from.

Leaning toward the minimal inline list — cheap, fits existing popover
idioms, doesn't block on unrelated work — but this is a real scope
decision, not something to assume.

### UI placement

A new row, probably near "Path to Internet" — current result (down/up
Mbps, RPM if present) plus a "Run" button, mirroring the SNMP/LAN "Scan"
button precedent already in the popover. One more thing competing for
vertical space, same constraint as the tooltips section above.

### Data usage

`networkQuality`'s own man page states plainly: *"This tool will connect
to the Internet to perform its tests. This will use data on your Internet
service plan."* Every existing check in NMS is deliberately near-zero-cost
so it can run continuously in the background (a ping, a single DNS query,
a small HTTP fetch); this one does a real upload+download saturation test.
That's exactly why it's on-demand-only rather than timer-driven — but
whether the button itself needs a first-run confirmation/warning, or
whether the "Run Speed Test" label is self-explanatory enough on its own,
is an open UX question.

### Open questions before implementing

- `-s` (sequential, gets RPM, slower) vs. default parallel (throughput
  only, faster) — decide the default, possibly exposed as a toggle.
- Minimal inline recent-runs list now, or defer historical comparison
  entirely to the future general history view?
- Does running the test need any user-facing warning about data usage, or
  is the button label enough?
- Is a cancel affordance worth building given the up-to-45s worst case, or
  is letting it run to completion (or the `-M` cap) acceptable?

## Latency history sparklines

Unlike DHCP and Network Quality, this one starts from good news: **the
data already exists.** `ConnectivityCheckRecord` isn't a change-log like
`PublicIPRecord` — it already persists every check's `latencyMs` on every
cycle (~30s, faster when unhealthy), for exactly the five layers that
produce a real ping/probe: `OverallStatus.routerLabel`, `.internetLabel`,
`.dnsLabel`, `.httpLabel`, `.peRouterLabel`. Interface and Network (the
other two Network Health rows) don't have a latency concept — they're
connectivity/identity state, not a ping target — so this covers 5 of the 7
rows, not all of them. This means the feature is purely a new query plus
new UI: no new `Process` shell-out, no new SwiftData model, no new
`AppEventKind` cases — it's a read-side visualization of a signal the app
is already collecting and already logging events for.

### Where it fits

Confirmed by reading `ContentView`: each Network Health row is already
backed by a `ConnectionLayer` (`id`, `label`, `detail`, `status`), and
`detail` currently holds a plain string (the SSID name, "Not confirmed,"
etc.). A sparkline slots in right next to that existing text — the same
layer's latency trend, rendered exactly where its status already lives.
No new section competes for space, which matters given how tight this
popover already runs.

**Mechanism:** Swift Charts (`import Charts`) isn't used anywhere in this
codebase yet, but it's first-party, available since macOS 13 (well within
the app's 14.0 minimum), and a compact axis-less `LineMark` sparkline —
`.chartXAxis(.hidden)`, `.chartYAxis(.hidden)`, sized to roughly one line
of text tall — is a few lines, not a new dependency to weigh.

### Data shape and the failure-representation problem

The single detail most worth getting right: a failed check has
`latencyMs == nil`. Silently treating that as zero, or letting the line
interpolate straight across a gap, would make an outage visually
indistinguishable from — or worse, look faster than — a normal fast
response. Proposed handling: draw the line through successful points only,
and overlay a small marker (a red dot, consistent with this app's existing
red-for-failure convention) at each failed check's timestamp, positioned
at the bottom of the sparkline's range. A viewer should be able to see "the
router had a bad patch here" at a glance, not have it silently smoothed
away.

Each layer needs its **own independent Y-scale** — DNS probe latency
(single-digit ms) and internet ping latency (tens of ms) are different
enough that a single shared axis across layers would flatten the faster
ones into an apparently static line. Swift Charts auto-scales per chart
instance by default, so this falls out naturally as long as each layer
renders its own separate `Chart`, not one combined multi-series chart
sharing an axis.

### Fetching — the naive approach is a real trap here

Given the unbounded-growth finding from the Network Quality section above
applies directly to this table too: **do not** fetch every
`ConnectivityCheckRecord` for a label and slice the last N in Swift — that
cost grows with the table's entire lifetime, not with what's actually
displayed. The fetch needs a `FetchDescriptor` with the label predicate,
`sortBy: [SortDescriptor(\.checkedAt, order: .reverse)]`, and an explicit
`fetchLimit` — keeping the query cost bounded to roughly the requested
point count regardless of how many months of history the table is
carrying.

### Persisted history vs. in-memory buffer

Two real options, worth deciding rather than assuming:

- **Query `SnapshotStore` for the last N records per layer.** Genuine
  history that survives an app relaunch — matches "tracking... over time"
  more literally. Needs the bounded-fetch discipline above.
- **In-memory rolling buffer in `ConnectivityViewModel`** — append the
  latency it already has in hand right after each `runChecks()` cycle to a
  small capped array per layer. Zero new queries, zero interaction with
  the large table at all. Trade-off: resets to empty on every relaunch, so
  it's "history since the app started this session," not real persisted
  history.

Leaning toward the persisted version given how the feature was framed, but
the in-memory version is a legitimate, much simpler fallback if
across-restart history isn't actually the point.

**Refresh timing:** the popover is closed most of the time, so refreshing
sparkline data on every 30s background cycle regardless of visibility
would be wasted work. Fetching on-demand — via `.task` when the relevant
row actually appears — fits this app's "closed by default, glanced at
occasionally" usage better than maintaining a continuously-updated chart
buffer nobody's looking at.

### A recurring theme, not a new problem

This is the third design in this document to run into the same underlying
gap: `SnapshotStore` has no retention or pruning logic anywhere, for any
table. Network Quality's history depends on it, this feature's fetch
performance depends on it staying reasonably bounded, and neither one
*causes* the growth — they're read-only consumers of a pre-existing
condition. Worth fixing on its own terms at some point rather than
per-feature, but not something this particular feature is blocked on: a
`fetchLimit`-bounded query stays cheap regardless of total table size, it
just means the table itself keeps growing on disk in the background
either way.

### Open questions before implementing

- Persisted (survives relaunch, needs the bounded-fetch discipline) vs.
  in-memory rolling buffer (simpler, resets on relaunch) — which matches
  the actual intent here?
- Point count / time window — untested default guess: ~20–30 points
  (roughly 10–15 minutes at the normal cadence), not exposed as a setting
  for v1.
- Does the recurring "no retention policy anywhere" theme deserve its own
  entry in this document, independent of any one feature that happens to
  depend on it?

## UI state debug log (for AI-assisted verification)

Different in kind from the other entries here — not a networking
capability, but a development aid. Claude has no way to screenshot or
otherwise visually inspect a live macOS app window (unlike, say, an iOS
Simulator). What Claude does have is full file-system read access. A
structured, append-only log of every value pushed into the UI would let
"did this fix work" be answered by reading a file instead of needing eyes
on the actual window — for anything that's really a *data* question. It
would **not** catch pure rendering bugs (truncated text, wrong colors, a
view that doesn't re-render even though its backing data changed
correctly) — worth being upfront that this substitutes for visual
inspection only partially, not entirely.

### Deliberately not the existing event log

`AppEventRecord` stays exactly as narrow as its own doc comment already
insists: "something worth noticing happened," not a catch-all debug log.
What's being proposed here is the opposite in spirit — every `@Published`
property update across every view model, not a curated subset worth
showing a user. These need to stay two separate mechanisms; routing this
through the existing event log would turn a deliberately narrow,
user-facing timeline into debug noise.

### Mechanism

Swift allows a property wrapper and a `didSet` observer on the same
declaration — `@Published var x: T { didSet { ... } }` is valid. That's
the hook: add `didSet` to each instrumented property, calling into a new
`UIStateLogger` service (naming mirrors the codebase's existing plain,
descriptive service names).

**Gating lives in one place, not scattered across call sites.** Rather
than wrapping every `didSet` in `#if DEBUG` throughout ~10 view models
(real visual noise for real code, for a debug-only feature), put the
`#if DEBUG` conditional *inside* `UIStateLogger.log(...)` itself — a
no-op stub in Release. Call sites stay clean
(`didSet { UIStateLogger.log(...) }`) and only one place needs the
compile-time gate. Release builds carry a negligible, inlinable no-op
call, not a real feature.

**Don't reintroduce a main-thread-blocking pattern doing this** — worth
naming explicitly given how much of this document's earlier debugging
(the "not responding" launch hang) turned out to hinge on exactly this
class of mistake. `@Published` properties in this codebase are set from
`@MainActor`-isolated code (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`),
so a `didSet` firing synchronous disk I/O would block the main thread on
every single UI update. The write itself needs to be dispatched to a
background queue, fire-and-forget, not executed inline in the observer.

### Format and location

Recommending the simpler of two real options: plain delimited lines
(`timestamp | ViewModel.property | new value`, using each type's default
`String(describing:)` output) rather than full JSON Lines. JSON would be
more structured and more parseable, but requires `Encodable` conformance
across every logged type (`ConnectivityCheck`, `SNMPDevice`, arrays of
either, etc.) — real invasiveness for a first cut. Plain lines are still
entirely grep/diff-friendly, which is the actual requirement, and can be
upgraded to JSON later if the simple version proves insufficient in
practice.

**Location:** `~/Library/Logs/NMS/ui-state.log` — the conventional macOS
location for a per-app log, and a single stable, predictable path rather
than a new timestamped file per launch, so there's never a "which one is
current" question. **Truncated at each app launch**, not appended forever
— this is session-scoped debug tooling, not permanent history, so it
sidesteps the unbounded-growth question this document keeps running into
elsewhere by simply not persisting across restarts at all.

### Staged rollout, not everything at once

Mirrors the same "start narrow" approach already used for tooltips.
Highest-value starting set — the properties most likely to actually be
the subject of "did my fix change what's displayed":

- `ConnectivityViewModel.checks`
- `NetworkMonitorViewModel.currentInterface`
- `WiFiSSIDViewModel.currentSSID`
- `EventLogViewModel`'s event list
- `SNMPViewModel.devices`

Lower priority: purely internal state like `isChecking`/`isScanning`
booleans — useful for confirming an operation started or finished, but
less central to "what's on screen."

### How this would actually get used

After a code change: rebuild, launch, wait for the relevant cycle, then
read `~/Library/Logs/NMS/ui-state.log` directly (`cat`, or `tail -f` while
the app runs) and grep for the property in question — the same shape of
workflow already used throughout this project's debugging so far (reading
`ipconfig getpacket`, `lsappinfo`, sampling a hung process's stack trace).
Not a new category of tool, just the same file-reading approach applied to
a signal that doesn't currently exist anywhere to read.

### Open questions before implementing

- Instrument every `@Published` property across every view model at once,
  or roll out the staged candidate list above first and expand only if it
  proves useful?
- Plain delimited lines (lower engineering cost, less structured) vs. full
  JSON Lines (`Encodable` conformance required across more types, more
  invasive) — confirm the simple version is actually sufficient before
  building the more structured one.
- `~/Library/Logs/NMS/` vs. some other location — any reason to prefer
  somewhere else?

## IP broadcast for LAN discovery — why it doesn't work, and what does

Prompted by a straightforward question: does IP broadcast still exist, and
could it detect every device on the LAN? Answer, backed by a live test on
a real network rather than assumed: broadcast still exists, still works
mechanically, and is still actively used today (DHCP's `DHCPDISCOVER`
goes to `255.255.255.255` — the same mechanism underlying the DHCPINFORM
idea in this document's DHCP section). IPv6, though, removed broadcast
entirely in favor of multicast, so "does it still exist" already has a
different answer depending on IP version.

For general host discovery specifically, no — confirmed directly. This
Mac has `net.inet.icmp.bmcastecho` set to `1` (broadcast ICMP echo replies
enabled, more permissive than a lot of modern OS defaults), yet a live
ping to this network's broadcast address (`10.0.0.255`) got exactly one
replier: the Mac's own IP. Zero replies from anything else actually
present on the LAN — the router included.

**Why:** the well-documented reason is the Smurf attack — a 1990s DDoS
technique that spoofs a victim's source IP and pings a network's broadcast
address, so every host on that network floods the spoofed victim with a
simultaneous reply, turning one small packet into a massive amplified
attack. RFC 2644 (1999) formally recommended routers stop forwarding
directed broadcasts because of this, and most operating systems —
Windows and Linux especially — ship with broadcast ICMP echo replies
disabled by default as standard hardening. The devices worth discovering
are exactly the ones most likely to have it off, regardless of what this
particular Mac happens to default to.

### The actual answer is already sitting in this project

This isn't a new problem — it's the README's own "Suggested next steps"
#3, arrived at from the opposite direction: *"A ping sweep before ARP
discovery — `LANDiscoveryService` still only sees hosts already in the
ARP cache; actively pinging the subnet first would populate it with
devices that haven't been talked to recently."* The reliable modern
substitute for one broadcast isn't a broadcast at all — it's a **unicast
sweep**, one ping (or ARP request) per address. A host can ignore a
broadcast as a matter of policy; it cannot ignore a directly-addressed ARP
request without failing to function on the network at all.

### What this would actually take — mostly reuse, not new code

Checked directly: the pieces this needs mostly already exist.

- **`SubnetCalculator.hostAddresses(ipAddress:subnetMask:)`** already
  enumerates every usable host address in a subnet (excluding network,
  broadcast, and self), already has a sane size guard (512 hosts max,
  refuses to enumerate anything larger), and is already used today —
  `SNMPViewModel.candidateAddresses()` calls it to build the SNMP sweep's
  candidate list. A ping sweep would reuse this exact utility unchanged,
  not write a new one.
- **The bounded-concurrency sweep pattern already exists too** —
  `SNMPService.sweep` already runs candidate probes with a
  `DispatchSemaphore`-bounded concurrency limit (32 at a time) for exactly
  the reason a ping sweep would need it: sweeping 254 hosts one at a time
  against `ConnectivityService`'s existing 2s-per-host timeout would take
  up to ~8.5 minutes worst case. The same shape — enumerate candidates,
  probe with bounded concurrency, collect responders — applies directly.
- **A nice side effect worth designing around rather than against:**
  pinging a host causes the OS to ARP-resolve it as a normal part of
  delivering the ICMP packet. A ping sweep's simplest implementation
  might not need to discover MAC addresses itself at all — ping every
  candidate, then re-read `arp -a` afterward (now populated with every
  host that just responded) and reuse `LANDiscoveryService`'s existing
  ARP-parsing code entirely unchanged, rather than building a second,
  parallel way to learn MAC addresses.

### Open questions before implementing

- Run automatically on a schedule/topology change (matching how
  `LANDiscoveryService.scan()` already behaves), or make it a manual
  "Sweep" action given it's a heavier operation than a passive `arp -a`
  read — similar in spirit to Network Quality's on-demand-only design
  above?
- Reuse `ConnectivityService.check(_:)` as-is for the per-host ping, or is
  a lighter-weight variant worth writing given a sweep only needs
  success/failure, not the latency parsing `ConnectivityService` also
  does?
- Confirm the "ping first, then re-read `arp -a`" ordering is reliable in
  practice — is the kernel's ARP table populated immediately after the
  ICMP exchange completes, or is there a race worth guarding against?

## mDNS/Bonjour: TXT records and dynamic service-type discovery

Prompted by a tangent off the LLDP investigation (see below): once raw
packet capture and LLDP-over-SNMP both turned out to be dead ends for this
network, the question became whether the Bonjour discovery this app
already has is itself under-using the data it receives. Answer, checked
against this actual network rather than assumed: yes, in two independent
ways.

### TXT records: real capability/version data already arriving, unread

`BonjourDiscoveryService` browses and resolves services today but only
extracts the instance name, service type, and resolved IP —
`dns-sd -L` against two real devices on this network shows there's much
more sitting in the same response, unparsed:

Brother HL-5450DN series (`_ipp._tcp`):

```
pdl=image/urf,application/octet-stream product=(Brother HL-5450DN series)
usb_MFG=Brother usb_MDL=HL-5450DN series usb_CMD=PJL,PCL,PCLXL,URF
Color=F Duplex=T Scan=F adminurl=http://BrotherLaserPrinter.local./net/net/airprint.html
UUID=e3248000-80ce-11db-8000-30055c3441ae TLS=1.0
```

Roku Ultra (`_airplay._tcp`) — notable because this device has **no SNMP
support at all**, so this is the only structured "what is this and what's
it running" data obtainable for it by any means already in this app:

```
model=4670X manufacturer=Roku fv=p20.15.34.832 srcvers=377.40.00
serialNumber=f36b48ec-18e5-5ef6-9348-ceba6833c91d deviceid=8F:76:B4:1A:38:89
```

That's manufacturer, model, and firmware version (`fv`) for a device
SNMP can never reach — the same category of identifying information
`SNMPService` provides via `sysDescr`, but for the entire class of
consumer/media devices that don't speak SNMP. The printer's TXT record
separately gives structured capability flags (`Color`/`Duplex`/`Scan`) and
a live admin URL, which `sysDescr`-style free text doesn't provide at all.

**Mechanism:** `NWBrowser.Result` (the type `BonjourDiscoveryService`
already receives from its existing browse) carries a `metadata` case,
`.bonjour(TXTRecord)`, giving structured TXT access without a second
resolve step — this should be a matter of reading more of what's already
arriving, not a new network operation. Not yet spiked to confirm the exact
API shape compiles and behaves as expected in this codebase's Network
framework usage — worth a five-minute check on one real device before
committing to broader TXT parsing, the same caution already applied to
`.help()` tooltips above.

### Dynamic service-type discovery: the hardcoded list is already missing real devices

`BonjourDiscoveryService.serviceTypes` hardcodes 9 curated types. DNS-SD
defines a standard meta-query for enumerating *all* types actually being
advertised, no prior knowledge needed (RFC 6763 §9): browsing
`_services._dns-sd._udp.local.` returns PTR records naming every service
type present. Run directly against this network:

```
_airplay._tcp   _raop._tcp   _companion-link._tcp   _spotify-connect._tcp
_pdl-datastream._tcp   _printer._tcp   _ipp._tcp   _ipps._tcp
_ipp-tls._tcp   _http._tcp   _ropieee._tcp
```

Three of these (`_companion-link`, `_spotify-connect`, `_ropieee` — the
last being the RoPieee Roon-streaming device already visible elsewhere in
this app as a Bonjour AirPlay target) aren't in the current hardcoded
list at all. The list isn't just incomplete in theory — it's already
missing real, currently-present devices on this exact network.

**Mechanism:** the meta-query is just another PTR-record browse
(`_services._dns-sd._udp` as the "service type" itself), so it fits the
same `NWBrowser` shape already used for every other type — this doesn't
need a different API, only a different (well-known, fixed) browse target.
Presumably run once at scan start to build the type list, then browse
each discovered type as today. Not yet spiked to confirm `NWBrowser`
accepts this meta-type the same way `dns-sd`'s CLI does.

### Open question, deliberately unresolved here

Bonjour Devices currently has no popover section at all — both the UI
list and its automatic launch-time scan were removed (see the
LAN-Devices/Bonjour-Devices hiding work elsewhere in this project's
history) because the popover was too tall for a 13" screen even after
every other space-saving pass. Richer per-device data doesn't change that
constraint on its own. Three shapes this could take, raised but
explicitly not decided:

- **Events only, no list** — mirror `SNMPViewModel`'s restart/
  software-change detection: persist each device's last-seen `fv`/model,
  diff on each poll, log a neutral event on change (e.g. "Roku Ultra
  firmware changed"). Zero added popover height.
- **A compact list section returns** — name plus model/version per
  device, costing vertical space again, the exact thing just trimmed.
- **Service-layer only, no consumer yet** — implement TXT parsing and
  dynamic type discovery in `BonjourDiscoveryService` so the data exists
  and is inspectable, without committing to how (or whether) it's
  surfaced.

### Open questions before implementing

- Spike `NWBrowser.Result.metadata`'s `.bonjour(TXTRecord)` case against a
  real device to confirm the API shape before writing the full parser.
- Spike browsing `_services._dns-sd._udp.local.` via `NWBrowser` to
  confirm it behaves as a normal type-enumeration browse the same way the
  `dns-sd` CLI's meta-query does.
- Which of the three "what does this feed" shapes above, if any —
  genuinely open, not leaning toward one yet.
- If events are the chosen consumer: new `SNMPDeviceRecord`-style
  per-device persisted state (keyed by something stable — TXT records
  often carry a UUID/serial number, unlike an IP address, which can
  change), or fold into the existing `BonjourDeviceRecord`?

## RRDtool for historical storage

Prompted directly: would [rrdtool](https://github.com/oetiker/rrdtool-1.x)
be a good fit for this app's persistence needs? It's squarely aimed at the
gap this document keeps running into from different angles — the Network
Quality and Latency History Sparklines sections above both note that
`SnapshotStore` has no retention or pruning logic anywhere, for any
table. RRDtool's entire reason to exist is solving exactly that: a
fixed-size file that never grows, via round-robin archives that
automatically consolidate (average/min/max) aging data into progressively
coarser resolution — full detail for the last day, hourly for the last
month, daily for the last year, all in one bounded file.

### Not currently installed — checked, unlike `lldpd`

The LLDP investigation above found `lldpd` already running on this Mac via
Homebrew, which materially changed that analysis (an existing daemon to
integrate with, not a new dependency to introduce). RRDtool isn't in the
same position — confirmed directly: `which rrdtool` and `brew list
rrdtool` both come back empty. Adopting it means asking users to install
a genuinely new third-party dependency, not plugging into something many
of them already have.

### Integration would be a CLI shell-out, not a library link

RRDtool has no Swift-native binding. The two options are linking `librrd`
directly (real build complexity: it pulls in cairo, pango, freetype,
fontconfig, libpng — a dependency chain with nothing else in common with
this project, and exactly the kind of universal-binary/notarization
friction already spent real effort on this session) or shelling out to
the `rrdtool` CLI's subcommands (`create`, `update`, `fetch`, `graph`) via
`Process`. The second option is the only one worth considering — it
matches this app's existing pattern exactly (`ping`, `arp`, `traceroute`,
`snmpget` are all `Process`-based shell-outs already), where linking a C
graphics library would be a new architectural category for this codebase.

### Scope: a narrow slice, not a replacement for SwiftData

RRDtool stores fixed-interval numeric time series only. That's a strong
fit for `ConnectivityCheckRecord.latencyMs` (ping/DNS/HTTP/SNMP response
times) — and nothing else currently in this app. It cannot hold
`AppEventRecord`'s text messages, `SNMPDeviceRecord`'s `sysDescr`/`sysName`
strings, or any of the other mostly-textual/structured data `SnapshotStore`
persists today. If adopted, it would sit *alongside* SwiftData for this
one numeric-metrics slice, never replace it — the event log, device
state, and everything else stays exactly where it is.

### Doesn't fit the feature already sketched for this data

The Latency History Sparklines section above scopes a compact,
axis-less sparkline per Network Health row — roughly 20–30 points,
10–15 minutes of history at the normal check cadence. A bounded
`FetchDescriptor` (with `fetchLimit`) against `ConnectivityCheckRecord` —
data already being persisted today — covers that completely, with zero
new dependencies. Introducing RRDtool for a 15-minute window would be
solving a problem that plan doesn't actually have.

### Where it would genuinely earn its keep

A materially different, bigger feature: real long-term trend graphs —
"how has router latency looked over the past three months" — held in
fixed disk space without hand-writing hourly/daily averaging logic.
That's RRDtool's actual specialty (the same role it plays in Cacti,
Smokeping, and MRTG), and something SwiftData has no equivalent for on
its own — a `fetchLimit`-bounded query stays cheap regardless of table
size, per the Sparklines section's own conclusion, but it doesn't give
you *consolidated* history the way an RRA does; old fine-grained rows
either accumulate forever or get deleted outright, with nothing in
between.

### Conclusion

Not worth adopting for anything currently planned — the sparkline feature
this data would obviously serve is already fully covered without it. A
legitimate answer only if the project later decides it wants genuine
long-term historical graphing as its own feature, distinct from the
sparkline idea, at which point a CLI shell-out (not a library link) would
be the way to integrate it. Worth deciding that scope question on its own
terms first, rather than adopting the dependency speculatively ahead of a
concrete need for it.

### Open questions before implementing

- Is long-term historical graphing (weeks/months, not the sparkline's
  10–15 minutes) an actual goal for this project, or a hypothetical one?
  Nothing below matters if the answer is no.
- If yes: which metrics get an RRA — just the five latency-producing
  Network Health layers (`ConnectivityCheckRecord`), or does
  `NetworkQualityResult`'s Mbps/RPM data (see the Network Quality section
  above) belong in one too?
- Graceful degradation story for users without `rrdtool` installed —
  mirroring `SNMPService.isAvailable`'s pattern, presumably: the feature
  disappears cleanly rather than erroring, and the app doesn't depend on
  it for anything else.
- Where would `.rrd` files live — alongside the SwiftData store in
  Application Support, presumably, but worth confirming rather than
  assuming.
