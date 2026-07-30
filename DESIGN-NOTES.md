# Design notes

Ideas discussed and worked through but not yet implemented. Each section is a
sketch, not a spec — enough to pick back up from later without re-deriving
the reasoning, not a promise of the exact eventual shape.

## Contents

- [DNS testing: is `dig` an alternative to `getaddrinfo`?](#dns-testing-is-dig-an-alternative-to-getaddrinfo)
- [DHCP lease tracking](#dhcp-lease-tracking)
- [UI tooltips](#ui-tooltips)
- [Network Quality (speed / responsiveness) testing, on demand](#network-quality-speed--responsiveness-testing-on-demand)
- [Latency history sparklines](#latency-history-sparklines)
- [Active-overrides banner (closing a real gap in the debug tooling itself)](#active-overrides-banner-closing-a-real-gap-in-the-debug-tooling-itself)
- [The MacBook Air height constraint, recurring, and a real fix for tracking it](#the-macbook-air-height-constraint-recurring-and-a-real-fix-for-tracking-it)
- [Interface-down injection can now produce real events](#interface-down-injection-can-now-produce-real-events)
- [UI state debug log (for AI-assisted verification)](#ui-state-debug-log-for-ai-assisted-verification)
- [IP broadcast for LAN discovery — why it doesn't work, and what does](#ip-broadcast-for-lan-discovery--why-it-doesnt-work-and-what-does)
- [mDNS/Bonjour: TXT records and dynamic service-type discovery](#mdnsbonjour-txt-records-and-dynamic-service-type-discovery)
- [RRDtool for historical storage](#rrdtool-for-historical-storage)
- [Classical dual-router VRRP identity](#classical-dual-router-vrrp-identity)
- [Per-network device scoping, and fixing the network fingerprint](#per-network-device-scoping-and-fixing-the-network-fingerprint)
- [Deferred Wi-Fi/link telemetry](#deferred-wi-filink-telemetry)
- [Popover screenshot button](#popover-screenshot-button)
- [Store size in the footer](#store-size-in-the-footer)
- [No retention policy anywhere (measured)](#no-retention-policy-anywhere-measured)
- [The concurrency warnings — all four now fixed](#the-concurrency-warnings--all-four-now-fixed)
- [Historical health score (green / yellow / red)](#historical-health-score-green--yellow--red)
- [Business SaaS monitoring](#business-saas-monitoring)

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

**Mechanism — spiked, and the obvious approach does not work.** The
original plan here was SwiftUI's `.help(_:)`: one line per view, nothing
to build, and — the property that made it attractive for *this* app
specifically — zero layout cost, in a popover whose entire history is a
fight for vertical space (LAN Devices and Bonjour Devices were removed
outright rather than collapsed, and the Events list was later trimmed by
two rows, both to fit a 13" MacBook Air).

This section previously flagged that `.help()`'s behaviour inside
`MenuBarExtra(.window)` was unverified, and that the project had already
hit popover-specific quirks (the menu bar icon needed manual `NSImage`
rasterization because a plain SwiftUI `Image` silently ignored
`.foregroundStyle`). That caution was justified:

- **`.help()` renders nothing at all in this popover.** Spiked directly
  with two tooltips — one on a plain `row()` in the Info tile, one on
  every Network Health layer row with per-row dynamic text — confirmed
  present in the running binary, hovered, and no tooltip appeared in
  either case. Reverted rather than left in as dead code.
- **AppKit's `NSView.toolTip` *does* work here.** A transparent
  `NSView` carrying `toolTip`, overlaid via `NSViewRepresentable`
  (~20 lines), renders correctly on hover in the same popover, on the
  same row where `.help()` had failed.
- **The AppKit overlay does not break text selection.** Worth testing
  explicitly, because `row()` sets `.textSelection(.enabled)` on every
  value so an IP can be copied during troubleshooting, and an
  intercepting overlay would have silently killed that. Verified by
  dragging across the Router row's value with the spike active:
  selection still works, so no `hitTest` override proved necessary.

That makes this the third `MenuBarExtra(.window)`-specific SwiftUI gap
in this project, after the icon's ignored `foregroundStyle` and
`ImageRenderer` skipping `ScrollView` content entirely. The pattern is
consistent enough to be worth stating as a rule: **assume nothing about
SwiftUI behaviour in this popover until it's been seen working there.**

The practical consequence is that the feature is still *possible* but no
longer *free*. It now needs a small custom component rather than a
built-in modifier — which is cheap, but it removes the "one line, no new
code" argument that was most of the original appeal.

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

- The Network Health layer labels (Network, Local Router, ISP Edge
  Router, Internet Ping by address, DNS, HTTP) — what each one actually
  checks
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

**The list above is stale, and misses the strongest case.** It was
written before DHCP History, Speed Test, BSSID, the router MAC
fingerprint, and the per-device SNMP reachability dots existed. Ranked
against the *current* UI, the best candidates are:

- **The DHCP History secondary line** — now the densest jargon in the
  entire app, and the clearest justification for the whole feature:
  `bcast 10.0.0.255 · gw 10.0.0.1 · dns 10.0.0.1 · local · lease 24h ·
  T1 12h · T2 21h · 0xae382dbe`. `T1`/`T2` are raw RFC 2131 timer names
  (renewal and rebinding), and the trailing transaction ID is explained
  nowhere in the UI at all. Even the stated target audience — a network
  engineer — may not recall which of T1/T2 is which without looking it
  up.
- **The gray SNMP reachability dot** — green/red are obvious, but gray
  means "not checked this session yet," not "down." That distinction is
  invisible and actively misleading during an outage, which is exactly
  when it's read.
- The Network Health layer labels and status colours (as originally
  listed — still valid).
- **BSSID and the router's MAC in parentheses** — why a MAC is shown at
  all, and what changing one would mean (an AP roam, or a router swap).
- Speed Test's `~50MB per run` — already partly self-explaining, but the
  *why* (it must be large enough to outrun TCP slow-start) isn't.

### The unresolved objection: discoverability

A tooltip is invisible until hovered, with nothing advertising that it
exists. For a diagnostic tool consulted *during* an outage, help you
must already know to look for is weak help.

This app's one existing explanatory element went the other way: the
`correlatedWithChange` footnote is inline and always visible — "*
possibly related to a recent network change" — costing a line of
vertical space in exchange for being unmissable. Adding hover-only help
elsewhere would quietly contradict that precedent rather than extend it.

The alternative worth weighing: a single "?" toggle that reveals inline
explanations, which costs one button and no persistent vertical space,
and is discoverable by definition. More work than tooltips, and it
reopens the vertical-space fight when expanded — but it actually solves
the problem tooltips only appear to solve.

### Built: the DHCP detail line and the SNMP status dots

Implemented for exactly the two elements ranked highest above —
`ToolTip.swift`'s `appKitToolTip(_:enabled:)`, applied to the DHCP
History secondary line and each SNMP reachability dot. Copy for the
latter is status-dependent, since the `.unknown`/gray case ("no ping
result yet, which is not the same as down") is the whole reason that
one made the list.

**It broke the screenshot capture, and only the capture.** Adding an
`NSViewRepresentable` overlay to those two elements made `ImageRenderer`
substitute a yellow broken-image placeholder for each — wiping out the
DHCP detail text and every status dot in the PNG, while the live popover
stayed visually perfect. Both observations together are what identify it
as a render-path bug rather than a UI one: hovering worked, a manual
screen capture looked right, and only the detached render was wrong.

This is the same failure `.buttonStyle(.plain)` already works around for
native buttons (see `ScreenshotViewModel.capture`), and the fourth
distinct case of "SwiftUI in this app behaves differently in a detached
or `MenuBarExtra`-hosted context." Fixed by threading the existing
`isCapturingScreenshot` flag into the modifier, so the overlay is simply
absent during capture — losing hover text in a still image costs
nothing, since nobody hovers a PNG.

Worth stating plainly for whoever adds the next tooltip: **adding one to
anything that appears in a screenshot requires passing
`enabled: !isCapturingScreenshot`.** Forgetting it doesn't fail loudly;
it silently replaces that element with a yellow block in every future
capture, and the live UI gives no hint anything is wrong.

### Open questions, for extending this further

- ~~Confirm `.help()` actually renders correctly in this popover~~ —
  **answered: it does not.** `NSView.toolTip` via `NSViewRepresentable`
  does. See the mechanism section above.
- The discoverability objection below is **unresolved, not dismissed** —
  it was reasonable to ship two tooltips on the strength of the mechanism
  working, but hover-only help is still invisible help. If the answer to
  "does anyone ever find these?" turns out to be no, the "?" toggle is
  the fallback, and nothing built here blocks it.
- Who is the audience, precisely? The README says "small networks and
  home labs"; the user guide written for this app assumes "a skilled
  network engineer, but not a software developer." Those want opposite
  copy — the first needs "DNS turns names into addresses," the second
  would find that patronizing and would rather know "random subdomain
  probe, to defeat caching." Nothing else in this document has had to
  pin this down; tooltip copy can't avoid it.
- `.help()` also sets accessibility help on macOS, and `ContentView`
  already carries 8 `.accessibilityHint` calls on exactly the controls
  most likely to get tooltips. An AppKit overlay does *not* set
  accessibility help, so hint and tooltip would become two independent
  strings that can drift. Decide whether they share a source.
- Do all candidate elements at once, or start with just the least
  self-explanatory ones (the DHCP line, the gray dot) and expand later?
- Tone/length convention for the text itself — one terse sentence, and
  don't just restate the visible label back at the user.

## Network Quality (speed / responsiveness) testing, on demand

Two candidate implementations, covering different parts of the signal.
Apple ships `/usr/bin/networkQuality` (confirmed present on this machine)
— the same test behind Settings → Network Quality Test. It measures
throughput (Mbps up/down) and, more interestingly, **responsiveness under
load**: RPM (round-trips-per-minute while the link is saturated), which is
essentially a bufferbloat measurement. This is a genuinely different kind
of signal from anything else in the app — every existing check tests
reachability and idle latency of small packets; this tests capacity and
behavior under stress.

Separately, Cloudflare's own public speed-test backend — plain HTTPS,
verified working directly, no account or hosting needed — is the chosen
mechanism for the throughput half. See "Two implementation candidates"
below for why, and what each one can and can't measure.

### Why this doesn't fit the existing change-log pattern

`PublicIPRecord` and the proposed `DHCPLeaseRecord` are both change-logs —
a row only gets written when something is actually different from last
time. This doesn't fit that shape: every on-demand run is an intentional,
standalone data point the user wants to compare against past runs ("was it
worse last Tuesday during the call?"). It needs a genuine time series —
every run gets a row, no dedup logic — which makes it architecturally
distinct from every other persisted table in the app so far.

### Two implementation candidates: Apple's CLI vs. Cloudflare's public endpoint

**Cloudflare runs a free, public backend for exactly this** — the same one
behind speed.cloudflare.com, no account, no hosting, no marketing site
needed:

```
GET  https://speed.cloudflare.com/__down?bytes=N   — download, any size
POST https://speed.cloudflare.com/__up             — upload, any size body
```

Verified directly, both directions:

```
1 MB download:  76.7ms total (19.7ms of that just the TLS handshake) → ~13.0 MB/s measured
25 MB download: 275.8ms total                                        → ~90.6 MB/s measured
5 MB upload:    127.0ms total, HTTP 200                               → ~41.3 MB/s measured
```

**The 1MB vs. 25MB gap is the whole finding, and it rules out a small
payload.** Same endpoint, same network, same moment — a ~7x difference in
measured throughput purely from file size (~104 Mbps vs. ~725 Mbps). A
transfer that small finishes before TCP slow-start ramps up, so most of
what gets measured is TLS handshake overhead, not sustained capacity. This
was checked *because* a plain 1MB file hosted on a future marketing site
was the original idea — the numbers are why that was dropped in favor of
requesting a large-enough payload directly from Cloudflare's endpoint
instead, which also sidesteps depending on some other site's uptime and
caching behavior entirely.

**Advantages over shelling out to `networkQuality`:** plain `URLSession`
GET/POST, no subprocess, no macOS-version dependency, no bundled-binary
removal risk (the same category of risk already flagged for `snmpget` and
`dig`). Runs identically regardless of what Apple ships or deprecates.

**What it can't do: no RPM, no bufferbloat signal.** A raw file transfer
measures throughput only — it says nothing about round-trips-per-minute
under load, which is the genuinely novel part of what `networkQuality`
provides and the reason this section existed in the first place. The two
are complementary, not substitutes: Cloudflare's endpoint for throughput
(chosen, no CLI dependency), `networkQuality` still worth keeping around if
the RPM/responsiveness signal is wanted, accepting its availability risk.

### Proposed design

Throughput, via Cloudflare's endpoint (`NetworkQualityService.measureThroughput()`):

- Plain `URLSession` `GET .../__down?bytes=N` and `POST .../__up`, timed by
  wall clock around the request, `Mbps = bytes * 8 / elapsedSeconds / 1_000_000`.
- **`N` cannot default to something small** — per the measurement above, at
  least 25MB, possibly larger still on genuinely fast links (worth
  re-testing against whatever this network's real ceiling turns out to be
  before picking a final constant). A fixed size is simpler than adaptive
  sizing (probe small, then scale up based on the result, the way real
  speed-test tools do) — worth deciding once real usage shows whether a
  fixed size is good enough across slow and fast connections alike, or
  whether it under/over-shoots badly at one end.
- A safety cap on total wall-clock time, mirroring `networkQuality`'s `-M
  45` — a large payload over a genuinely slow link could otherwise run far
  longer than a user pressing "Run Speed Test" is willing to wait.
- **No equivalent to `-I <interface>`** — `URLSession` doesn't offer
  interface binding as directly as the CLI's flag does. On a multi-homed
  Mac this could measure the wrong interface's speed. Worth resolving
  before implementing (see open questions).
- Availability isn't a real concern here the way it is for `networkQuality`
  — this only needs internet reachability, already tracked elsewhere in the
  app, not a local binary that might not exist.

RPM/responsiveness, via `networkQuality`, if kept:

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
- **`NetworkQualityResult`** (value type, shared by both implementations)
  — `downloadMbps`, `uploadMbps`, `downloadResponsivenessRPM: Int?`,
  `uploadResponsivenessRPM: Int?`, `baseRTTMs: Double?`, `interfaceName`,
  `testedAt`, plus a `source` field (`.cloudflareEndpoint` /
  `.appleNetworkQuality`) so a persisted row records which method produced
  it. RPM/RTT fields are optional not just for `networkQuality`'s parallel-
  mode fallback but as the normal case for the Cloudflare-endpoint path,
  which never produces them at all.
- **`NetworkQualityRecord`** (SwiftData model) — same fields, persisted
  unconditionally per run via
  `SnapshotStore.recordNetworkQualityResult(_:)` — deliberately not
  "IfChanged" like the other record types, since every run is wanted.
- **`NetworkQualityViewModel`** — no timer, on purpose. Unlike every other
  view model in this app, this one has zero automatic trigger. `func run()`
  is the only entry point, called from a button press. This must never be
  added to `NMSApp.init()`'s launch-time kicks — the whole point is that it
  costs real bandwidth, so it must never run without the user asking.
  Cancellation is worth building given the worst-case wait either way, but
  the mechanism differs by implementation: `URLSessionTask.cancel()` for
  the Cloudflare path (dispatched the same way
  `ConnectivityService`/`SNMPService`'s callers already do), vs.
  `Process.terminate()` on the subprocess for `networkQuality`.

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
service plan."* The same is true of the Cloudflare-endpoint path, and more
directly so: `networkQuality` sizes its own test traffic internally, while
requesting from `.../__down?bytes=N` means NMS itself is choosing exactly
how many megabytes to pull down every run (25MB+ per the measurement
above, likely per direction if upload is also run). Every other check in
NMS is deliberately near-zero-cost so it can run continuously in the
background (a ping, a single DNS query, a small HTTP fetch); this one is
a real, sizable transfer regardless of which implementation runs it.
That's exactly why it's on-demand-only rather than timer-driven — but
whether the button itself needs a first-run confirmation/warning, or
whether the "Run Speed Test" label is self-explanatory enough on its own,
is an open UX question.

### Resolved — implemented

Every open question above was decided in favor of the narrower scope: the
Cloudflare throughput path only, nothing from `networkQuality`.

- **Byte count:** fixed 25MB, both directions, no adaptive sizing —
  simplest option that already cleared the "not just TLS handshake
  overhead" bar found above. Revisit only if real usage shows it
  under/over-shoots badly at one end.
- **Interface binding:** not solved — `URLSession` genuinely has no direct
  equivalent to `-I`, and building one (packet-level socket options,
  `Network.framework`) was judged a bigger lift than this feature
  warranted. Accepted limitation, called out in
  `NetworkQualityService`'s doc comment.
- **Both directions every run**, sequentially — never concurrently:
  running download and upload at once would have them contend for the
  same pipe and understate both numbers, which defeats the point of a
  speed test. Costs more wall-clock time per run than parallel would,
  traded for numbers that are actually trustworthy.
- **`networkQuality` dropped entirely** — this app now measures
  throughput only, no RPM/bufferbloat signal. Narrower than the original
  proposal, but matches what was actually asked for; `networkQuality`
  remains a candidate to add later if the RPM signal turns out to matter.
- **Minimal inline recent-runs list**, mirroring `DHCPLeaseViewModel`'s
  history pattern (which didn't exist yet when this section was
  originally written, and turned out to be the right precedent): a
  size-to-fit list when there are few runs, a fixed-height scroll once
  there are more than fit. Ended up living inside its own tile in the
  Network Health/Info/Path to Internet grid rather than a full-width
  section — it filled the grid's one empty cell, and one line per run
  ("↓ 765 Mbps  ↑ 173 Mbps" plus a time-only timestamp) turned out to
  fit that half-width fine once measured directly, no two-line wrap
  needed despite DHCP History needing exactly that fix at the same
  width class.
- **No warning dialog** — an always-visible "~50MB per run" label at the
  top of the tile, plus a data-usage line in the button's accessibility
  hint, instead of a confirmation step. Matches how "Scan" and "Trace
  Now" already work.
- **No cancel affordance** — a 45s request timeout (mirroring
  `networkQuality`'s own `-M 45`) is the only safety net. Real usage on a
  fast connection made this moot in practice: every verified run finished
  in well under a second per direction.

### `networkQuality` added after all — as a second source, not a replacement

The RPM signal dropped above turned out to matter. Rather than re-open the
throughput decision, `AppleNetworkQualityService` was added alongside
`NetworkQualityService`, and `NetworkQualityResult` grew the `source` field
this section's original "Proposed design" already anticipated
(`.cloudflareEndpoint` / `.appleNetworkQuality`) plus optional
`downloadResponsivenessRPM`/`uploadResponsivenessRPM`/`baseRTTMs` fields —
`nil` for a Cloudflare-sourced run, which has no equivalent measurement,
not missing data. `NetworkQualityRecord` picked up the same fields,
optional with a default, the same safe-migration shape proven earlier by
`ConnectivityCheckRecord.systemLoad` — verified directly: the real store's
17 existing rows survived the schema change untouched, each correctly
backfilled as `cloudflareEndpoint` with `nil` RPM/RTT.

**Units, checked against the man page rather than assumed**:
`dl_throughput`/`ul_throughput` are bits per second — an 8x overstatement
(treating them as bytes) was caught before it shipped, by reading the man
page rather than trusting a plausible-looking Mbps-sized raw number.

**Always sequential (`-s`), never the default parallel mode** — confirmed
directly against the real tool that `dl_responsiveness`/`ul_responsiveness`
are only emitted in sequential mode; parallel mode returns a single
combined `responsiveness` figure instead, which isn't parsed. This costs
real time (~25-40s observed, against the Cloudflare path's well-under-a-
second on this connection) but the RPM split by direction is the entire
reason this exists.

**One unified history, not a second tile.** Both sources feed the same
`recentRuns` list and share `isRunning`, so they can't run concurrently
(they'd contend for the same link, understating both — the same reasoning
`run()`'s own sequential download-then-upload already applies). The
trigger lives as a secondary, plain-styled button next to the "~50MB per
run" caption rather than a second first-class header action, since the
tile already has one (`Run Speed Test`) and a second prominent button
competing for the same slot would suggest a choice that has to be made
every time. Every pre-existing Cloudflare row still renders as a single
line, unchanged; an Apple-sourced row gets a second line ("Apple · RPM
818↓/1065↑ · base 11ms"), the same "two-line for genuinely dense data"
convention DHCP History established.

Verified end to end against the real store: the subprocess trace showed
`networkQuality -c -s -M 45 -I en0` running 38.4s and exiting cleanly, the
persisted row matched (933 Mbps down, 938 up, RPM 818↓/1065↑, base
11ms), and a real capture confirmed both triggers and the two-line row
render correctly. Scenario suite still 11/11 afterward.

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
gap: `SnapshotStore` had no retention or pruning logic anywhere, for any
table. Network Quality's history depends on it, this feature's fetch
performance depends on it staying reasonably bounded, and neither one
*causes* the growth — they're read-only consumers of a pre-existing
condition.

**Since resolved** — see "No retention policy anywhere (measured)" at
the end of this document. `SnapshotStore.pruneIfNeeded` now bounds the
three raw-telemetry tables at 7 days, `ConnectivityCheckRecord` among
them. That's the table this feature wants to read, so its retention
window and this feature's time range are now coupled in practice, not
just in principle.

### Built

Implemented as designed above, with one deliberate deviation and both
open questions resolved.

**Persisted, 30 points, fetched on demand.** `SnapshotStore
.fetchLatencyHistory(label:limit:)` uses the bounded `fetchLimit`
discipline this section warned about, and returns `LatencySample` value
types rather than `@Model` objects — pointedly, having just fixed a bug
where a SwiftData model crossed a thread boundary in
`LANDiscoveryViewModel`. Loaded from a `.task(id:)` keyed on
`lastCheckedAt`, so it refreshes while the popover is open and a new
round lands, but does nothing while it's shut.

**Deviation: hand-drawn `Canvas`, not Swift Charts.** This app has now
been caught out by `ImageRenderer` four separate times — `ScrollView`
content, native buttons, missing background, `NSViewRepresentable` — and
the screenshot tool depends on it. A charting framework is a far larger
unknown in that renderer than a `Path`, and a sparkline *is* a polyline:
Charts would have contributed auto-scaling, which is three lines of
min/max. Verified the choice was right by capturing the result — the
sparklines render correctly in a screenshot.

**Six layers, not five.** This section predicted five; Public IP is also
a real ping target (added since), so it gets one too. Network and
Interface still don't — no latency concept.

### Verified against a real outage, without one

The failure-representation problem this section flagged as "the single
detail most worth getting right" was tested using the injection tooling
rather than by waiting for real trouble: forcing Router and DNS to fail
at 30x speed filled their sparklines with failures within seconds.

Confirmed visually in a capture: failures render as discrete red marks
along the bottom, the line is **absent** across them rather than
interpolated, and healthy layers keep clean traces. The per-instance
Y-scale is also doing real work — Public IP's sub-millisecond wobble is
visible variation, which a shared axis with DNS (which showed a 64.5ms
spike against a 6-10ms baseline in the same window) would have flattened
into a dead line.

The whole test ran against a scratch store and left zero injected events
in real history.
- ~~Does the recurring "no retention policy anywhere" theme deserve its
  own entry in this document, independent of any one feature that happens
  to depend on it?~~ **Answered: yes.** See "No retention policy anywhere
  (measured)" at the end of this document, which quantifies it —
  `ConnectivityCheckRecord` is ~90% of all rows and grows ~3.5 MB/day.
  That entry and this one are coupled: sparklines want to read exactly
  the table that most needs pruning, so the retention window and the
  sparkline's time range have to be chosen together.

## Active-overrides banner (closing a real gap in the debug tooling itself)

Asked directly: after building the event log, screenshots, and failure
injection, what else would help debugging? The answer came from this
project's own history rather than a hypothetical — the exact mistake of
leaving a `defaults` key set after a test, discovered later only by
grepping the plist by hand, had already happened more than once in this
session.

`FailureInjector.activeOverridesSummary()` is a single method answering
"is anything debug-injected right now" across every override key —
forced failures, interface-down, both DHCP signals, both SNMP signals,
and the poll speedup. Deliberately excludes `NMSStorePath`: unlike every
other key, which is re-read every check round, the store path is read
once at launch to build the `ModelContainer`, so checking it live could
report something the running app isn't actually doing — `App.store`'s
own launch-time log line is the trustworthy source for that one setting.

Surfaced two ways, covering the two moments a leftover key is invisible:

- **At launch** (`NMSApp.init()`), since a key set before quitting and
  never cleared produces no *transition* for the other path below to
  catch.
- **On change** (`ConnectivityViewModel.apply`, logged only when the
  summary differs from last round) — catches a key toggled live while
  the app keeps running, the more common real mistake, and logs both
  directions ("did it turn on" and "did it actually clear").

Also shown directly in the popover footer — bold orange, last line, no
dedicated refresh timer needed since `body` already re-evaluates on every
published change from the connectivity round. This is the first
DEBUG-only UI element in this app; it needs no `#if DEBUG` guard at the
call site, since `activeOverridesSummary()` is already unconditionally
`nil` in a release build.

Verified directly: launching with `NMSInjectFailures` already set (the
"forgot to clear before quitting" scenario) showed the summary in the
log immediately, no relaunch needed to notice; clearing it live logged
the transition down to just the remaining override; a capture confirmed
the footer banner renders correctly; and a clean launch logged `none`
with the footer absent. Scenario suite still 11/11 throughout.

## The MacBook Air height constraint, recurring, and a real fix for tracking it

The popover outgrew the M1 MacBook Air's screen again — the same
constraint that forced Events from 170pt to 136pt once before (commit
`41e169c`), now tripped by today's additions (sparklines, Apple Network
Quality, the active-overrides banner). Asked directly what would help
prevent this recurring, the investigation itself found a real gap and a
real fix, not just a bigger trim.

### The screenshot tool can't verify this, by construction

First instinct was to compare two of the app's own screenshot captures
before/after a trim. The comparison showed height going *up*, not down —
`ContentView.isCapturingScreenshot` swaps every scrollable section for a
plain, unclipped list specifically so captures stay legible (see
"Popover screenshot button" above), which means a screenshot's height is
always the full-history size, never the fixed-height, clipped layout
that actually has to fit a screen. The tool built to make this app
debuggable turned out to have a blind spot for this exact bug class.

### Real desktop screenshots as ground truth, and a real access gap

The user pointed at their own manually-taken desktop screenshots (`Cmd
+Shift+4`/`+3`, saved to `~/Desktop`) as a reference instead — these
capture the *actual* live-clipped layout, since they're real screen
captures, not `ImageRenderer` renders. On the iMac specifically they
still can't answer "does it fit the MacBook Air" (a big enough screen
never clips anything), but two of them bracketing the `41e169c` commit
gave something better: an exact, confirmed row-height constant. One
screenshot (pre-trim) showed 10 event rows in a 170pt box; the other
(post-trim) showed 8 rows in a 136pt box. Both compute to exactly
**17pt/row** — not a fresh estimate, the real number behind a change
already known to have fixed the problem once.

Reading those two files surfaced a genuine tooling gap of its own: the
Bash tool cannot read `~/Desktop` at all (macOS's per-folder TCC
protection on Desktop/Documents/Downloads, applying to whatever process
the harness's shell runs as) — `cp`/`stat`/`sips` all failed with a
misleading `No such file or directory` despite `ls` on the parent
directory working fine. The `Read` tool succeeded on the same exact
path, evidently running through a different, more privileged access
path. Worth remembering: **`Read` a `~/Desktop` file directly rather than
trying to `cp`/process it via Bash first** — the latter will fail
confusingly even though the file demonstrably exists.

### The fix, corrected once already

First pass trimmed DHCP History's fixed-height `ScrollView` from 90pt to
64pt — a reasonable-sounding but ungrounded guess. Once the real 17pt/row
constant was in hand from the desktop screenshots above, corrected to
**56pt** (90 − 2×17), matching the *Events* precedent exactly rather than
approximating it. DHCP History was the section chosen to trim (over one
of today's actual additions) because it's already scrollable — shaving
its window drops nothing, everything stays reachable by scrolling.

### Built: real height tracking, not just a bigger trim

The actual "how do we prevent this" answer: `ScreenshotService
.measureHeight(_:)` renders a view through the same `ImageRenderer`
`capture` already uses, but returns only `.nsImage?.size.height` — no
file written. Called from the screenshot button's action, *before* the
existing capturing-copy mutation, so it measures `self` exactly as it's
rendered live (`isCapturingScreenshot` still `false`) rather than the
capture's deliberately-uncapped version. Logged as
`ContentView.liveHeight`. Piggybacks on an already-deliberate, recurring
action (screenshot clicks) rather than a new timer or a launch-time hook,
so every future click now silently adds one more real data point to this
popover's actual height history — for free.

First real reading, taken right after the DHCP trim above: **860pt**.
Cross-checked against the M1 MacBook Air's known logical screen size
(1280×800pt) — a menu-bar popover's usable ceiling is roughly 750-770pt
by rough estimate, which would mean 860pt is *still* over even after
today's fix, by more than "about 2 rows." That estimate is unconfirmed,
though — the MacBook Air wasn't available to test against directly this
session. The next `ContentView.liveHeight` log line captured while
actually running on the MacBook Air will give the real number, at which
point a hard-coded ceiling and a proper regression check (fail a test
if `measureHeight` ever exceeds it) becomes possible. Until then, this
is observability, not yet enforcement — the honest state of "tracking
this," short of the calibration data needed to also "prevent" it
automatically.

### The calibration data finally arrived, and a real ceiling with it

Testing on the MacBook Air put the popover "about one line too tall" at
846pt — which makes the usable ceiling roughly **829pt**, and shows the
earlier 750-770pt estimate was too conservative by a wide margin. That
estimate came from reasoning about the logical screen size; the measured
answer is about 60pt more generous. Worth preferring the measurement.

Two rows were then trimmed from Speed Test, and **only one row's worth
of height actually came off**: 846pt → 829pt for a 34pt cut. The reason
is the independent-column layout above. Total height is
`max(leftColumn, rightColumn)`, and Speed Test lives in the right one,
which was taller by about a row. The first ~17pt brought the columns
level; the remaining ~17pt just made the right column *shorter* than the
left, moving nothing. Trimming further there would have been pure
placebo.

The fix that worked was trimming a **full-width** section instead —
SNMP Devices, 140pt → 123pt — which came straight off the total: 829pt →
812pt, the full row. That's the rule worth remembering:

- A section inside the tile grid only shortens the popover while its
  column is the taller of the two.
- A full-width section below the grid (Events, SNMP Devices, DHCP
  History) shortens it unconditionally.

Net for the session: 846 → 812pt, roughly two rows under where the
overflow was reported. With a measured ~829pt ceiling now on record, a
hard regression check against `ContentView.liveHeight` is finally
possible — that was the one missing input, and it isn't missing anymore.

### The tile grid itself was the next thing flagged — and reclaimed real height

Reported directly: the four top tiles (Network Health/Info/Path to
Internet/Speed Test) looked misaligned, and fixing that might save
space. A live desktop screenshot confirmed it concretely — Path to
Internet's box ended well above its row-mate Speed Test's, with a
visible dead gap between them — and pointed at the actual cause: the
`LazyVGrid` synchronizes each *row's* height to its tallest cell, so a
short tile forced to share a row with a tall one leaves unused space
that the grid still reserves.

Replaced with two independent columns (`HStack` of two `VStack`s,
Network Health+Path to Internet on the left, Info+Speed Test on the
right) rather than a grid. This isn't a coincidental improvement:
row-grid total height is `max(NetworkHealth, Info) + max(Path, Speed)`,
while column-stack total is `max(NetworkHealth+Path, Info+Speed)` — and
the sum-of-maxes is mathematically always ≥ the max-of-sums for
non-negative sizes, so this change can only help or be a no-op, never
regress. `Self.tileColumns` (the `LazyVGrid`'s `GridItem` array) was
removed entirely — nothing else referenced it.

Verified both ways: `ContentView.liveHeight` dropped from 860pt to
**846pt** (a real, if more modest than initially estimated, 14pt
saving — the row imbalance a single earlier screenshot suggested was
larger than it actually was), and a fresh live desktop screenshot
confirmed both tile pairs now align cleanly on their shared edges. A
small gap still remains under the shorter (left) column overall, since
Speed Test's column is genuinely taller than Path to Internet's — an
expected, much less jarring residual than the previous cross-row
misalignment, not something this change was trying to eliminate
entirely. Scenario suite still 11/11.

### A resizable comparison window, born from this exact ceiling

Every fix above was still working within the popover's fundamental
constraint: `MenuBarExtra(.window)` forces a fixed-height, no-scroll
layout, so every screen-fit problem has to be solved by trimming
content rather than letting the container adapt. A second `Window`
scene was added alongside it — same live view models, opened via an
"Open in Window" button in the popover's footer — as a real, resizable,
scrollable alternative to compare against, not yet a replacement.
`ContentView.isInWindow` is the one thing that differs between the two:
each history box (Events, SNMP Devices, DHCP History, Speed Test,
traceroute hops) gets a taller, independently-scrolling box instead of
the popover's cramped mini-scrollers.

That surfaced a genuine, multi-round scroll-mechanics problem of its
own. Nesting SwiftUI `ScrollView`s of the same axis — one per tile,
inside an outer one wrapping the whole window — hit AppKit's default
nested-scroll-view chaining: once a tile's own box couldn't consume any
more scroll delta, `NSScrollView` forwarded the remainder to
`nextResponder`, which bounced the *entire window*, not just the tile,
whenever a tile's own limit was reached.

Four designs were tried before landing on the current one
(`NMS/Views/NoBounceScrollView.swift`):

1. **Remove the outer `ScrollView` entirely.** Fixed the bounce — with
   nothing to chain into, there was nothing to bounce. But it also
   floor-clamped the window to its full content height. Confirmed
   broken on the M1 MacBook Air specifically: the window came up taller
   than the screen, with no way to reach the lower half at all.
2. **A custom `NSScrollView` that severed `nextResponder` during
   `scrollWheel(with:)`.** Restored the ability to shrink the window and
   killed the bounce, but also killed the *pass-through*: scrolling past
   a tile's own limit did nothing instead of continuing into the
   window's scroll, so the window could only be scrolled from the
   narrow gaps between tiles.
3. **`verticalScrollElasticity = .none` on just the tile boxes**, with a
   plain SwiftUI `ScrollView` (`.scrollBounceBehavior(.basedOnSize)`)
   for the outer container. Chaining and per-tile bounce were both
   fixed — Events, in the middle of the document, scrolled seamlessly
   into the outer view with no visible bounce. But Speed Test and DHCP
   History sit near the very top and bottom of the whole document, so
   forwarded scroll from them reached the outer view's own *genuine*
   edge, where `.basedOnSize` still allows the native elastic bounce.
4. **Disabling elasticity on the outer container too**, using the same
   custom `NSScrollView` type for both. Fixed the remaining bounce
   everywhere — but scroll-wheel chaining out of an exhausted tile
   turned out to behave inconsistently across input devices: reliable
   on a trackpad, erratic and largely unusable with a Magic Mouse
   (confirmed directly on the iMac).

Design (1)'s MacBook Air finding and design (4)'s Magic Mouse finding
together ruled out relying on scroll-wheel chaining as the *only* way to
reach content below the fold — outer scrolling isn't optional (screens
smaller than the content demand it), but it can't depend on a mechanism
that doesn't work the same way on every input device. The fix that
shipped: `NoBounceScrollView(persistentScrollbar: true)` on the outer
container, using a `.legacy`, always-visible `NSScroller` whose thumb
can be grabbed and dragged directly — a `mouseDown`/`mouseDragged`
interaction, entirely unrelated to `scrollWheel(with:)`, so it works
identically regardless of input device. Wheel-scrolling over the gaps
between tiles, and chaining out of an exhausted tile, still work too;
the scrollbar is just the guaranteed path now, not the only one.
Verified directly on both machines: the iMac (Magic Mouse) and the M1
MacBook Air (trackpad, and the one with the real screen-height
constraint) both confirmed independent tile scrolling, no bounce, and
the scrollbar reaching the full document.

## Interface-down injection can now produce real events

Returning to the pre-existing punch list: `NMSInjectInterfaceDown` could
force `currentInterface` to `nil` but could never produce the
`interfaceDown`/`interfaceUp` events themselves, since those only ever
logged from `NetworkMonitorViewModel.handleObservedChange()` — reachable
exclusively from the real `SCDynamicStore` callback, which injection
doesn't fake. Documented as a known limit at the time this was built.

Fixed without faking the callback. `refresh()` (the popover's Refresh
button) previously just re-read `currentInterface` with no change
detection or event logging at all — `handleObservedChange()` had all of
that, but only the real observer could call it. Merged both into one
`updateInterface()`, called by both the Refresh button and the real
`observeChanges` callback, so a manual refresh now reacts exactly as a
real topology change would.

One thing required care: `init()` used to call `refresh()` directly,
which would now mean every launch runs through the merged change-
detecting path — and since `currentInterface` starts as `nil` before the
very first read, that would have logged a bogus "Interface back up"
event on *every single launch*, not just a real recovery. Fixed by
keeping `init()`'s first read as a bare assignment (no comparison, no
event), since there is no genuine "previous" state to compare against at
launch — only `refresh()` (called afterward, by an actual user action)
and the real observer path go through `updateInterface()`.

Verified all three parts directly: a clean launch logs no interface
event at all (confirmed against the real store, still exactly the 3
historical events from real changes over the past two days); forcing
the override and pressing Refresh logs a real `interfaceDown`; clearing
it and pressing Refresh again logs a real `interfaceUp`. Both directions
tested against a scratch store, real store untouched throughout,
scenario suite still 11/11 after.

**One limit remains, and it's structural, not a bug**: this only fires
from a Refresh *click* — nothing polls `NetworkMonitorViewModel` on a
timer, by design. That also means `script/scenarios.sh` can't exercise
this scenario the way it does the other six: the script drives
everything purely through `defaults write` and polling, deliberately
with no UI automation (matching `FailureInjector`'s own "no UI, script-
only" design), and there's no non-interactive way to trigger a Refresh
click. Verified manually instead, once each direction, rather than
adding UI automation to close this — that would cut against the
existing design rather than complete it.

## UI state debug log (for AI-assisted verification)

> **Status: implemented** for the staged five-property set — see the "UI
> state log" section of `README.md` for what it does and how to read it.
> This entry is kept because it records *why* the implementation looks the
> way it does (the rejected alternatives especially), and because the
> expansion questions at the end are still genuinely open. Everything below
> describing the design still holds; only "not yet built" no longer does.

Different in kind from the other entries here — not a networking
capability, but a development aid. A structured, append-only log of every
value pushed into the UI would let "did this fix work" be answered by
reading a file — for anything that's really a *data* question. It would
**not** catch pure rendering bugs (truncated text, wrong colors, a view
that doesn't re-render even though its backing data changed correctly) —
worth being upfront that this substitutes for visual inspection only
partially, not entirely.

**Corrected premise.** This section originally justified itself with
"Claude has no way to screenshot a live macOS app window." That turned
out to be wrong and has since been disproved directly: plain full-screen
`screencapture -x` works fine (window-ID targeting does *not*, because
`MenuBarExtra(.window)` never appears in `CGWindowListCopyWindowInfo`'s
on-screen list at all). The real obstacle is different, and is a better
argument for this feature than the original one: the popover dismisses on
*any* focus loss — including clicking into another app to type a message —
so screenshot verification is a timing race, not an impossibility. A log
is reliable where screenshots are flaky, and captures a *sequence over
time*, which a screenshot fundamentally cannot.

### Deliberately not the existing event log

`AppEventRecord` stays exactly as narrow as its own doc comment already
insists: "something worth noticing happened," not a catch-all debug log.
What's being proposed here is the opposite in spirit — every `@Published`
property update across every view model, not a curated subset worth
showing a user. These need to stay two separate mechanisms; routing this
through the existing event log would turn a deliberately narrow,
user-facing timeline into debug noise.

### Not `os_log` / unified logging either — ruled out empirically

The obvious "don't hand-roll a log file, use the platform's" objection
was tested rather than argued, and it fails decisively for *this*
purpose. A probe binary emitting `Logger(subsystem:category:)` lines
was written and run; reading them back gave:

```
$ log show --predicate 'subsystem == "Thistle.NMSProbe"' --last 2m
log: Could not open local log store: Operation not permitted
```

Not a predicate problem — bare `log show --last 30s` fails identically.
The unified log store is simply not readable from the sandboxed
environment Claude runs commands in, which makes it useless for the one
thing this feature exists to do. A plain file under `~/Library/Logs/`
was verified read/writable from that same environment in the same test.

So this isn't "hand-rolled vs. platform-standard" — `os_log` is a
non-option here, and the file is the only mechanism that works. (There
is a secondary reason that would have argued the same way regardless:
`Logger` redacts dynamic string interpolation as `<private>` unless every
site is annotated `%{public}`, which is exactly the network data this log
exists to capture.) `os_log` remains perfectly reasonable for ordinary
app diagnostics — it's specifically the AI-readable use case it can't
serve.

### Mechanism

Swift allows a property wrapper and a `didSet` observer on the same
declaration. That's the hook: add `didSet` to each instrumented property,
calling into a new `UIStateLogger` service (naming mirrors the codebase's
existing plain, descriptive service names).

**Verified against a real build**, not assumed — a probe class with
`@Published private(set) var x: [String] { didSet { ... } }` compiled and
ran, confirming three things that matter for the design:

- The combination is valid *including* with `private(set)`, which is how
  all 28 `@Published` properties in this codebase are declared. Since
  every write therefore originates inside its own view model, `didSet`
  catches all of them.
- **This is a write log, not a change log.** `didSet` fires on identical
  reassignment (`checks = x; checks = x` logs twice) and on in-place
  mutation (`append`). That's the correct behavior for the stated goal —
  it distinguishes "the code never ran" from "the code ran and produced
  the same value," which is usually the actual question. Just don't read
  the log expecting a diff: `ConnectivityViewModel.checks` is reassigned
  every round whether or not anything changed.
- **`didSet` fires *after* SwiftUI has already been notified** —
  `@Published` publishes from `willSet`, so a Combine sink observed the
  new value *before* the `didSet` ran. Immaterial to ordering among log
  lines, but it means a line records that a write happened marginally
  after the UI was told about it; don't treat the timestamp as the exact
  instant of UI update when chasing a race between two view models.

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
every single UI update. The write itself needs to be dispatched off the
main thread, fire-and-forget, not executed inline in the observer.

**The queue must be *serial*, and the timestamp must be taken at the call
site.** Both follow from the actual goal being a faithful *sequence*, and
both are easy to get wrong:

- A dedicated serial `DispatchQueue`, **not** `DispatchQueue.global()`.
  The global queues are concurrent, so two writes dispatched in order can
  complete out of order — which would corrupt the one property the whole
  feature exists to provide.
- Capture `Date()` **synchronously inside `didSet`** and pass it into the
  async write, rather than calling `Date()` on the background queue. A
  timestamp taken at drain time measures queue latency, not when the UI
  write happened.
- Alongside it, a monotonically incrementing sequence number per line.
  Timestamps alone can't order two writes landing in the same
  millisecond, and a gap in the counter makes a dropped line obvious
  rather than invisible.

### Format and location

Recommending the simpler of two real options: plain delimited lines
(`seq | timestamp | ViewModel.property | new value`, using each type's
default `String(describing:)` output) rather than full JSON Lines. JSON
would be more structured and more parseable, but requires `Encodable`
conformance across every logged type (`ConnectivityCheck`, `SNMPDevice`,
arrays of either, etc.) — real invasiveness for a first cut. Plain lines
are still entirely grep/diff-friendly, which is the actual requirement,
and can be upgraded to JSON later if the simple version proves
insufficient in practice.

**Strictly one line per write — embedded newlines must be escaped.** The
line-oriented format is the whole basis for grepping and for reading the
sequence, and a single stray newline in a logged value silently splits
one write into two apparent ones. Two real sources of this in this
codebase: SNMP `sysDescr` (multi-line descriptors are common on network
gear — though checked directly against the gateway actually reachable
here, an Alta Route10, which returns a single-line `Alta Route10 1.5b`;
the Aruba APs were unreachable at the time and remain unverified), and
`lastError`, which is assigned straight from `error.localizedDescription`
with no guarantee of being single-line. Cheap insurance either way:
replace `\n`/`\r` with a literal escape in `UIStateLogger` before writing,
rather than hoping every value behaves.

**Location:** `~/Library/Logs/NMS/ui-state.log` — the conventional macOS
location for a per-app log, and a single stable, predictable path rather
than a new timestamped file per launch, so there's never a "which one is
current" question. **Truncated at each app launch**, not appended forever
— this is session-scoped debug tooling, not permanent history, so it
sidesteps the unbounded-growth question this document keeps running into
elsewhere by simply not persisting across restarts at all.

### Always on in DEBUG — deliberately not a runtime feature flag

Decided question, recorded so it doesn't get relitigated: the log is
**on by default in DEBUG builds, with no flag to enable it**, and
compiled out entirely in Release.

- **Retrospective availability is the entire value.** A log you have to
  opt into before the fact is empty at exactly the moment it's wanted —
  the normal sequence is *notice a symptom, then go look*. An opt-in flag
  converts that into set-flag, relaunch, reproduce, and by then the state
  in question is gone.
- **Volume doesn't justify a flag.** This app is event-driven at a slow
  cadence (connectivity checks every 30s, traceroute every 10 min,
  topology changes rare), not a render loop. 28 `@Published` properties at
  those rates is a few dozen lines per busy 30s window, and truncation at
  launch caps total size regardless. The unbounded-growth problem this
  document repeatedly runs into elsewhere genuinely doesn't apply.
- **The gate that matters already exists.** `#if DEBUG` inside
  `UIStateLogger.log(...)` means Release ships nothing at all. A runtime
  flag would be a second gate stacked on a sufficient first one.
- **A flag adds a failure mode that costs more than it saves**: an empty
  log becomes ambiguous — feature broken, or flag not set? That's a
  debugging tax on a debugging tool.
- **Compile-time-only gating bounds the privacy question.** These lines
  will contain SSIDs, the public IP, MAC addresses and SNMP descriptors,
  written under `~/Library/Logs/` — which sysdiagnose collects. DEBUG-only
  makes "could this ever write network identifiers on a user's machine"
  structurally impossible; a runtime flag would reopen it.

If it ever does become intrusive, the fix is an opt-**out**
(`NMS_UI_LOG=0`) rather than an opt-in, which preserves the retrospective
property. Not worth building until there's a concrete reason.

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

Settled during implementation, recorded so they don't get relitigated:
default-on vs. feature flag (default-on in DEBUG); whether `os_log` would
do instead (it would not); plain lines vs. JSON Lines (plain lines shipped,
and they read fine in practice); `~/Library/Logs/NMS/` as the location
(kept — and confirmed to be the literal path, since the app is not
sandboxed, `ENABLE_APP_SANDBOX = NO`); and how to render `@Model` classes
(a `UIStateLoggable` protocol, conformed only by the types that need it,
rather than blanket `Encodable`).

Genuinely still open:

- **Expand past the staged five?** The remaining 23 `@Published` properties
  are mostly `isChecking`/`isScanning`/`lastError` — useful for confirming
  an operation started or finished, less central to "what's on screen."
  Worth adding only when something concrete wants them, rather than
  pre-emptively.
- **Does truncate-at-launch hold up?** Right for a single
  build-run-inspect cycle, but a crash-and-relaunch destroys the log
  covering the crash — the exact case you'd want it for. Retaining one
  previous copy (`ui-state.log.prev`) fixes it cheaply if it bites.
- **Do long array lines need a compact rendering?** A real
  `ConnectivityViewModel.checks` line is ~500 characters of full struct
  dump — greppable, but wide. `UIStateLoggable` is already the hook for
  fixing this per-type if it becomes annoying; deliberately not done
  pre-emptively, since the verbose version has the advantage of never
  omitting the field you turn out to need.
- **Nothing records *why* a write happened.** The log shows `checks` was
  written, not whether it came from the 30s timer, a topology change, or a
  manual button. Adding a caller tag (`#function`, or an explicit reason
  string) would disambiguate — worth it only if a real debugging session
  actually gets stuck on that ambiguity.

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
Quality and Latency History Sparklines sections above both noted that
`SnapshotStore` had no retention or pruning logic anywhere, for any
table, and "No retention policy anywhere (measured)" at the end of this
document quantifies it (~90% of rows are `ConnectivityCheckRecord`, ~3.5
MB/day).

**This weakens the case considerably now that the gap is closed.**
`SnapshotStore.pruneIfNeeded` bounds the telemetry tables at 7 days in
~40 lines, with no new dependency and no second storage format to keep
in sync with SwiftData. RRDtool's advantage was never just boundedness —
it's the *consolidation* (full detail recent, coarser with age) that
plain age-based deletion throws away. That remains genuinely better for
long-range history, so this stays worth reading if that's ever wanted;
it's just no longer the only way to stop the file growing forever.
RRDtool's entire reason to exist is solving exactly that: a
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

## Classical dual-router VRRP identity

> **Status: partially addressed.** Merging by shared MAC is implemented (see
> the README's SNMP section) and resolves the AP1 `.16`/`.17` duplicate on
> this network. It is not a general VRRP solution — it depends on the master
> answering the virtual address from its own hardware MAC, and says nothing
> about which address is virtual or which router currently holds mastership.
> The rest of this entry stands as the design for doing that properly.

SNMP device identity (`SnapshotStore.recordSNMPDevice`, `SNMPDeviceRecord`)
is keyed by `ipAddress`. That breaks down for a VRRP pair: two Aruba APs
running VRRP, where a shared virtual address (`.16`) and AP1's own
individual address (`.17`) both answer SNMP with the *same* `sysName`
whenever AP1 holds mastership. Under plain IP-keyed identity, this lists
"AP1" twice — once per address — even though it's one physical device
answering on two addresses.

### What was tried

A `sysName`-based identity: `recordSNMPDevice` looked up existing records
by `sysName` first (falling back to `ipAddress` only for devices that
don't report a name), and a `SNMPViewModel.deduplicated(_:)` step collapsed
same-`sysName` entries within a single sweep before they reached the UI or
persisted store, keeping the numerically lower address as a deterministic
tie-break. `SNMPDeviceRecord.ipAddress` had its `@Attribute(.unique)`
removed to allow this. Verified directly against the reported scenario:
correctly collapsed the two-address VRRP case to one entry.

### Why it was reverted

It doesn't actually model VRRP — it just hides the duplicate. Collapsing
by `sysName` conflates two genuinely different things: "this specific
physical router" and "whichever router currently holds the shared virtual
address." The tie-break (keep the numerically lower address) has no
relationship to which address is real vs. virtual, or which physical
device currently holds mastership — generic SNMP alone can't tell you
either of those. If VRRP failover ever moved mastership to AP2, the
persisted record would keep AP1's identity fields pointed at an address
AP2 now answers on, which is arguably more misleading than the original
two-entries problem it was trying to solve.

### Correction: both duplicate cases are one device, not two

An earlier draft of this entry claimed a `sysName` identity "collapses two
genuinely different things." Real data says otherwise, and it's worth
recording because it makes the reverted approach more defensible than this
note originally implied. Two duplicate pairs showed up in practice:

- `AP1` at `10.0.0.16` and `10.0.0.17` — identical `sysName` *and*
  `sysDescr` (`AOS-8 (MODEL: 535), Version 8.13.3.0`).
- `router` at `10.0.0.1` and `10.0.102.1` — also identical on both
  (`Alta Route10 1.5b`), the same Alta answering on the main LAN and on a
  guest VLAN.

Neither is two devices being conflated; both are one device at two
addresses, which `sysName` matching would have merged correctly. The
objection that survives is narrower than "it merges unrelated devices": a
merge still picks one address arbitrarily (lowest wins) and throws away the
fact that the device answers at both — and for a VRRP virtual address, the
kept one can silently become the wrong one after a failover.

The second case has since been handled a different way, and is no longer a
VRRP problem at all: `10.0.102.1` belonged to a network no longer attached,
so `SNMPViewModel.pruneStaleDevices` now drops off-subnet devices outright
(see the README). That leaves this entry scoped to what it was always
really about — one device, two addresses, *same* subnet.

### ARP already proves it, more cheaply than SNMP does

The duplicate is visible one layer down, without SNMP involved at all:

```
? (10.0.0.16) at e8:10:98:ca:a9:22 on en0
? (10.0.0.17) at e8:10:98:ca:a9:22 on en0
? (10.0.0.18) at e8:10:98:ca:9f:66 on en0
```

`.16` and `.17` resolve to the *same* MAC — one physical interface answering
at two addresses — while AP2 at `.18` has its own. That is materially better
evidence than matching `sysName`: it comes from data `LANDiscoveryService`
already collects, needs no community string, and two addresses sharing a MAC
is a fact about the hardware rather than an inference from a
user-configurable label. Two devices could easily be named `AP1`; they
cannot share a NIC.

The asymmetry matters, though, and bounds how far this can be pushed: a MAC
match *proves* one device, but a MAC mismatch proves nothing. Aruba here
answers the VRRP virtual address from the master's own physical MAC, which is
why this works — had it used a proper VRRP virtual MAC
(`00:00:5e:00:01:XX`), the virtual address would resolve to that instead and
the two would look like different devices. So MAC matching is a sound
positive signal to merge on, not a complete solution.

### What a proper fix likely needs

Two options worth considering, not mutually exclusive:

- **Manual configuration**: let the user declare which addresses form a
  VRRP pair (or mark one address as "virtual, backed by these physical
  addresses"). The topology is a fact only the user knows — a static pair
  of APs doesn't change often, so this is a small one-time cost for a
  model that's actually correct, versus inferring something SNMP can't
  distinguish on its own.
- **VRRP-MIB awareness**: RFC 2787 defines VRRP-specific SNMP OIDs
  (`vrrpOperState`, `vrrpOperMasterIpAddr`, etc.) that could, if the APs
  expose them, explicitly report which addresses are VRRP virtual
  addresses and which physical device currently holds mastership —
  removing the guesswork entirely. Not yet confirmed whether these
  specific Aruba APs expose the VRRP-MIB at all.

Either way, individual and virtual addresses should end up as distinct,
related entries — never merged into one ambiguous record the way the
reverted `sysName` approach did.

### A smaller, unrelated bug this merge caused (since fixed)

Separate from the modeling question above: merging by MAC means only the
primary address is ever polled again (`SNMPViewModel.poll` builds its
targets from the already-merged `devices` list), so the alias's own
`SNMPDeviceRecord` row stopped being written to entirely. Found via
`StoreInspector` — `10.0.0.17` (AP1's VRRP address) sat with a `lastSeenAt`
about 12 hours stale while `10.0.0.16` (same physical AP) polled
successfully every minute. Invisible in the popover, since the merge
already hides the duplicate — but a raw dump or a direct `sqlite3` query
read it as a device gone silent, when it's the exact same hardware the
primary had just proved was alive.

Fixed with `SnapshotStore.syncAliasFreshness`, called from
`SNMPViewModel.rebuildDeviceList` after every merge: for each alias
address, copy the primary's `sysDescr`/`sysName`/`uptimeTicks`/`lastSeenAt`
onto its row. No restart/software-change detection runs against the
alias — `recordSNMPDevice` already reports those once, for the primary;
doing it again here on the same underlying data would double the event.
Verified against a scratch copy of the real store: `10.0.0.17` jumped from
~12 hours stale to matching `10.0.0.16`'s timestamp exactly after one poll
cycle, with zero events logged.

This is purely a store-freshness fix, not a step toward the "proper fix"
above — it doesn't change what the popover shows or attempt to model VRRP
at all, only keeps the alias's persisted row honest about a fact the merge
already established.

### Open questions before implementing

- Manual config or VRRP-MIB (or both) — does auto-detection via the MIB
  make manual config unnecessary, or is manual config still wanted as a
  fallback for APs that don't expose it?
- If manual config: what's the UI for declaring a pair — a settings field
  parallel to the existing community-string list, or something in the
  SNMP Devices section itself (e.g. right-click "mark as VRRP pair")?
- If VRRP-MIB: needs testing against the actual Aruba APs to confirm the
  MIB is exposed under the community strings already in use, before any
  code is written against it.
- How should the UI actually present a confirmed pair — one row with both
  addresses shown, or two rows visually grouped/linked? Affects
  `SNMPDeviceRecord`'s shape either way.

## Per-network device scoping, and fixing the network fingerprint

`SNMPDeviceRecord` has no association with the network a device was found
on. It's keyed by `ipAddress` alone, so every device ever discovered lands
in one flat list regardless of which network it belonged to. That's the
root cause behind a string of symptoms already hit in practice: a guest-VLAN
gateway (`10.0.102.1`) sitting in the list beside the main-LAN one
(`10.0.0.1`) — the same physical Alta, identical `sysName` *and*
`sysDescr` — and main-LAN devices needing to be hidden by inference when
attached elsewhere.

`SNMPViewModel.pruneStaleDevices` currently patches this by inferring
membership from subnet arithmetic plus a candidate-set fallback. It works,
but it's a second notion of "which network does this belong to" that has to
be kept in agreement with the real one. Recording the association instead
of inferring it removes the guesswork, and should *replace* the pruning
rather than sit alongside it.

### The current fingerprint is already wrong

`NetworkIdentityViewModel.recognize` uses the bare router MAC:

```swift
let (network, isNew) = snapshotStore.recordNetworkSeen(fingerprint: routerMAC)
```

One router serving several VLANs answers on the same MAC for all of them.
Confirmed directly while dual-homed (Ethernet on the main LAN, Wi-Fi on the
guest SSID):

```
? (10.0.0.1)   at bc:b9:23:81:a6:d4 on en0
? (10.0.102.1) at bc:b9:23:81:a6:d4 on en1
```

So the main LAN, the guest VLAN, and Ethernet all collapse into a single
`KnownNetwork` today — one shared label, and a `timesSeen` counter
accumulating across networks that aren't the same network. This is a bug on
its own terms, independent of any SNMP work: the "Known network" row and its
visit count are currently wrong for anyone whose router hosts more than one
VLAN.

### Index on the VLAN, not the SSID

The devices live on a VLAN, not on an SSID. Several SSIDs bridged to the
same VLAN hand out addresses in the same subnet and reach exactly the same
devices, so they are one network for this purpose; SSID is a label worth
displaying, not an identity worth keying on — and it doesn't exist at all on
Ethernet, so it can't be the primary key regardless.

Router MAC **plus subnet** is the key that survives every case that has
actually come up:

| Case | MAC | Subnet | Wanted | MAC+subnet |
|---|---|---|---|---|
| Several SSIDs on the Ethernet VLAN | same | same | one network | one ✓ |
| Main LAN vs guest VLAN, one router | same | differs | distinct | distinct ✓ |
| Two sites both using `192.168.1.0/24` | differs | same | distinct | distinct ✓ |
| Plain Ethernet, no SSID | same | same | one network | one ✓ |

MAC alone fails row 2 (the setup this was reported from). Subnet alone fails
row 3. SSID fails rows 1 and 4.

Accepted cost: renumbering a DHCP scope reads as a new network. Rarer than
the multi-SSID and multi-VLAN cases, and it degrades to a re-discovery
rather than anything destructive.

### Schema consequences, including one that isn't optional

- `KnownNetwork.fingerprint` is `@Attribute(.unique)`. Changing how it's
  composed means every existing row stops matching, so previously labelled
  networks would come back as new and their labels orphan. Storing
  `routerMAC` and `subnet` as their own fields — with the fingerprint
  derived — at least makes a legacy match possible (old row whose
  fingerprint equals the new `routerMAC`), rather than silently losing user
  labels.
- **`SNMPDeviceRecord.ipAddress` cannot stay `@Attribute(.unique)`.** Once
  devices are scoped per network, two networks can legitimately each have a
  `192.168.1.1`, and a global uniqueness constraint makes that unstorable.
  Uniqueness has to become "IP within a network," which SwiftData can't
  express as a composite constraint — so the attribute comes off and
  `recordSNMPDevice` enforces it in code via its existing fetch. Worth
  flagging loudly because it's the same attribute that was removed and then
  restored during the `sysName` identity experiment; this time it's forced
  by the data model rather than a judgement call.
- `SNMPDeviceRecord` gains a defaulted `networkFingerprint: String?` so
  adding it stays a lightweight migration. Existing rows have no tag.

### Ordering problem worth designing around

The fingerprint depends on the router's MAC, which only comes from a LAN
scan (`recognize` returns early without it). SNMP discovery can finish
before that resolves, so "which network is this device on" may be unknown at
the moment a device is first recorded. Tagging therefore needs a defined
behaviour for untagged rows rather than assuming one is always available.

### Would "2 of 3 attributes" be a better identity than MAC+subnet?

Proposed refinement: treat router MAC, IP range and SSID as three signals and
call it the same logical network when any two agree. Tested against every
case that has actually come up, it is genuinely better than the MAC+subnet
key above — it wins two rows that MAC+subnet gets wrong:

| Case | MAC | Subnet | SSID | Agree | 2-of-3 | MAC+subnet |
|---|---|---|---|---|---|---|
| Several SSIDs, one VLAN | same | same | differs | 2 | same ✓ | same ✓ |
| Main LAN vs guest VLAN | same | differs | differs | 1 | distinct ✓ | distinct ✓ |
| Two sites, both `192.168.1.0/24` | differs | same | differs | 1 | distinct ✓ | distinct ✓ |
| **DHCP scope renumbered** | same | differs | same | 2 | same ✓ | distinct ✗ |
| **Router replaced, same config** | differs | same | same | 2 | same ✓ | distinct ✗ |

Those last two are real: a renumber was already noted above as an accepted
cost of MAC+subnet, and a router swap (or a gateway MAC that moves under
VRRP failover) breaks MAC+subnet too. Voting heals both.

**But it can't be a primary key, because it isn't transitive.** With
networks P(MAC X, subnet S1, SSID A), Q(X, S1, B) and R(X, S2, B): P≈Q on
MAC+subnet, Q≈R on MAC+SSID, yet P≉R on MAC alone. A relation where P≈Q and
Q≈R but P≉R can't induce a stable fingerprint — there is no value to compute
and store, only pairwise comparisons whose outcome depends on which existing
record you happen to test against first. That's a different architecture from
`KnownNetwork.fingerprint` as it exists: lookup becomes "compare against all
known networks and pick the best match," not a keyed fetch.

**And it degrades on Ethernet**, which has no SSID at all — voting collapses
to 2-of-2, so a renumber or a router swap on a wired network still reads as
new. The robustness gain applies only to Wi-Fi.

### Public IP is not a fourth vote

Tempting, and wrong for this purpose: the public IP belongs to the WAN side,
so it is *shared by every VLAN behind the same router*. Verified directly
from two captured sessions — while attached to the guest VLAN
(`10.0.102.131`), the observed public IP was `192.184.170.5`, the same value
seen from the main LAN.

So public IP votes "same network" for precisely the pair this whole entry
exists to keep apart. Adding it as a fourth attribute under a 2-of-N
threshold makes main-vs-guest match on MAC + public IP and merge — worse than
having no fourth attribute. It is also dynamic (changes with the ISP lease)
and unavailable while offline.

It is still worth *storing*: it identifies the site rather than the VLAN,
which is a genuinely useful grouping ("all the networks at home"), and it
would let the app tell "my ISP changed my address" apart from "I moved to a
different network." Just not as a term in the identity decision.

### Multi-homed sites and dual-router setups

Both are anticipated, and each pushes the design in a specific direction.

**Multi-homed (two or more WAN links at one site).** The public IP stops
being single-valued — which link a flow egresses decides what the outside
world sees, and that can change without anything on the LAN changing. This
kills public IP as an identity term outright (already argued above for a
different reason) and weakens it even as the "same site" grouping suggested
there: at a multi-homed site the same LAN legitimately reports two public
addresses. It also means the ISP edge router and traceroute path can change
while the LAN fingerprint stays fixed, so path monitoring has to be free to
re-evaluate without that being read as a network change.

**Dual routers on one LAN.** The risk is the gateway MAC: if failover moves
the gateway to different hardware without a shared virtual MAC, a MAC-keyed
fingerprint sees a brand-new network purely because the standby took over.
That is exactly the "router replaced, same config" row the 2-of-3 table
rescues, which raises its value from a nice-to-have to something closer to
required for this topology.

**VRRP virtual MACs are worth detecting explicitly.** RFC 5798 reserves
`00:00:5e:00:01:XX` for VRRP virtual routers, with the VRID in the final
octet. A gateway MAC matching that prefix tells you three things for free,
with no SNMP at all: the gateway is VRRP-managed, its MAC is stable across
failover (so MAC-keying is *safe* here), and the VRID is readable directly.
Checked against the current gateway: `bc:b9:23:81:a6:d4` — an ordinary
hardware MAC, so this router is not presenting a VRRP virtual gateway today,
and MAC stability across a future failover can't be assumed.

### Suggested resolution

Keep a deterministic key (router MAC + subnet) as the stored identity, and
record SSID and public IP as *attributes* of the network rather than
components of its fingerprint. Then add reconciliation as a separate,
explicit step: when a network is seen that matches an existing one on two of
three signals but not on the key, treat that as evidence they're the same
network and offer to merge — carrying the user's label across.

That keeps keyed lookup and a stable primary key, while still healing the
renumber and router-swap cases that pure MAC+subnet loses. It also makes the
non-transitivity harmless, because merging is a deliberate one-time
reconciliation rather than an identity computed fresh on every sighting.

### Open questions before implementing

- What do untagged rows do — show on every network until re-discovered, or
  stay hidden until a poll can tag them? Showing them reproduces today's
  flat-list behaviour for legacy data, which is at least not a regression.
- Backfill or re-discover? A one-time backfill can't know which network a
  historical device was on, so the honest options are "tag on next successful
  poll" or "leave legacy rows untagged forever."
- Should the UI show only the primary network's devices, or all networks
  currently attached? While dual-homed both are genuinely reachable, so
  showing both is defensible — but it reproduces the duplicate-router
  complaint that started this. Primary-only is the likely answer.
- Does `DiscoveredDeviceRecord` (LAN/ARP results) want the same treatment
  for consistency, or is per-snapshot association already enough there?
- Is reconciliation automatic or offered? Merging silently would make two
  networks the user considers distinct collapse without warning; prompting
  needs UI that doesn't currently exist anywhere in the popover.
- On Ethernet, 2-of-3 has only two signals to work with. Is a wired renumber
  or router swap reading as a new network acceptable, or does that case want
  something else (DHCP `server_identifier`, say, which `ipconfig getpacket`
  already exposes per the DHCP entry above)?
- None of this touches VRRP: AP1 at `10.0.0.16` and `10.0.0.17` is one
  device at two addresses on the *same* network, so no amount of network
  tagging separates them. See "Classical dual-router VRRP identity."

## Deferred Wi-Fi/link telemetry

BSSID and the router's fingerprint (its MAC) are now shown in the Info
section, since both are cheap, already-available identity facts. A larger
set of telemetry was considered alongside them and deliberately deferred —
none of it is identity, it's signal quality and link characteristics, and
the popover's Info section is already tight on vertical space (it's a fixed
list in a fixed-height window, not a scrollable table).

- **RSSI / signal strength** — `CWInterface.rssiValue()` and
  `noiseMeasurement()`, giving both signal and an SNR estimate. The obvious
  next thing to show, but it changes constantly (unlike SSID/BSSID, which
  are stable between roams), so displaying it raises its own question: is a
  point-in-time reading useful, or does it want a small history/sparkline to
  mean anything? That's more UI than a single `row(...)` line.
- **Wi-Fi channel/band** — `CWInterface.wlanChannel()`, which also implies
  the band (2.4/5/6 GHz) via `CWChannelBand`. Useful for diagnosing
  congestion or a bad roam to a crowded channel, but only actionable to
  someone who'd also want to see RSSI alongside it.
- **Negotiated PHY rate** — `CWInterface.transmitRate()` (Mbps). Read
  alongside the two above, since a low rate on strong RSSI is itself a
  useful signal, not something either one shows alone.
- **Security type** — `CWInterface.security()`. Low cost to add, but low
  value on a network the user already knows the security of; probably only
  worth showing if it changes unexpectedly (e.g. an AP silently downgrading
  from WPA3 to WPA2), which would want to be an *event*, not a static row.
- **Ethernet link speed** — not read anywhere today; would need
  `IOKit`/`ifconfig`-level lookup rather than CoreWLAN, since it's a
  different interface family entirely. Parallels PHY rate on the Wi-Fi side
  (a negotiated-speed sanity check — "am I actually getting gigabit").
- ~~DHCP lease detail~~ — implemented (see "DHCP lease tracking" above and
  the popover's DHCP History section). Not used as an identity signal for
  the 2-of-3 fingerprint discussed under "Per-network device scoping"
  above — that remains open.

### Open questions before implementing

- Do RSSI/channel/PHY-rate belong together as one addition, or is RSSI
  alone the minimum viable version? They come from the same `CWInterface`
  lookup already made for BSSID, so the marginal engineering cost of all
  three is small — the real cost is popover space and whether a static
  snapshot of a constantly-changing value is worth showing at all.
- Does a "show more" disclosure (a `DisclosureGroup` under Info) solve the
  space problem better than adding rows outright, given more of this is
  diagnostic depth than everyday-glance info?
- Is Ethernet link speed worth the different code path (IOKit vs CoreWLAN)
  for one more row, or does it wait until there's a broader Ethernet-side
  feature to justify the investment?

## Popover screenshot button

Built to close the loop on a real, recurring cost this whole project's
development has paid: verifying a UI change meant the user manually
screenshotting the popover and handing the file over — several times a
session, every session. `ScreenshotViewModel.capture` renders the
popover's own SwiftUI view tree directly to a PNG via `ImageRenderer`
(macOS 13+) — not a real screen capture, so no Screen Recording
permission and no risk of grabbing anything outside the app's own window
(a real screen-capture attempt earlier in this project's history grabbed
the whole desktop by accident). Saves to
`~/Library/Logs/NMS/screenshots/NMS-<timestamp>.png` and logs a
`.screenshotCaptured` event naming the exact file, so it's findable by
reading the event log instead of guessing which file on disk is the
relevant one (a real, separately-hit problem this project had: a user
screenshot's filename containing a non-ASCII space character defeated
literal-string file access, only working via a glob pattern).

### How it works

Three pieces, each existing because of a specific `ImageRenderer`
limitation found by looking at real output rather than assumed:

1. **`ContentView.isCapturingScreenshot`** — a plain stored `var`, not
   `@Environment` and not `@State`. The camera button copies the view
   (`var capturing = self; capturing.isCapturingScreenshot = true`) and
   hands the copy to `ImageRenderer`; `ContentView` is a struct, so
   that's an ordinary value copy that leaves the live popover untouched.
   Every scrollable section (`eventList`, `infrastructureList`,
   `speedTestList`, `dhcpHistoryList`, `tracerouteSection`) checks the
   flag and renders a plain `VStack` of every row instead of its normal
   fixed-height `ScrollView`.
2. **`.buttonStyle(.plain)`** on the rendered copy.
3. **`.background(Color(nsColor: .windowBackgroundColor))`** on the
   rendered copy.

The result is *better* than a manual screenshot, not merely equivalent:
the live popover clips Events to ~8 rows and Speed Test to a ~90pt
scroll window, while a capture shows the full fetched history (48
events, 10 runs, every SNMP device, verified against row counts in the
store).

### The three bugs, and how each was found

**Buttons rendered as broken-image placeholders.** Every button
(Refresh, Trace Now, Run Speed Test, Scan, Quit) came out as a generic
yellow placeholder instead of its label. `ImageRenderer` doesn't
reliably draw macOS's native bordered-button chrome off-screen; a style
with no native bezel has nothing to fail at. Found by reading the first
capture instead of trusting that file-creation meant success.

**`ScrollView` content rendered as nothing at all** — not clipped,
absent, with real non-empty data behind it. Diagnosed conclusively by a
side-by-side against a manual screen capture taken ~30 seconds apart:
every section backed by a plain `VStack` rendered (Network Health, Info,
Path to Internet with 2 hops, DHCP History with 2 leases), and every
section backed by a `ScrollView` came out blank (Events, SNMP Devices,
Speed Test's 17-run list) — 5 for 5. Path to Internet and DHCP History
were the useful controls there: they use the same
`count > n ? ScrollView : VStack` pattern as the others and happened to
be *below* their thresholds, so they isolated the `ScrollView` as the
variable rather than the section.

**A first fix for that didn't work, and was reverted before this one.**
An `@Environment` key carrying the same "we're capturing" flag never
reached the view during the render pass — logged from inside
`eventList` during a real capture and it read `false` every time.
That's why the working version uses a plain struct property: no
propagation machinery to fail. Worth knowing before anyone reaches for
`@Environment` here again.

**The capture had a transparent background**, which made every
default-colored (dark) row invisible — only explicitly-colored text
(green/red events, the blue hostname link) survived. The live popover's
background belongs to the `MenuBarExtra` window, not to `ContentView`,
so a detached render has none. Notable for *how* it was found: it was
invisible to the user, because Preview and Quick Look composite
transparency onto white and the file looked correct opened normally. It
only surfaced when Claude read the same file and composited onto black
instead — which matters precisely because being readable by Claude is
the entire point of the feature.

### Still open

- Nothing blocking. The one structural limit left is that a capture
  reflects the *fetched* history, not the full store — Speed Test shows
  10 of 17 runs because `fetchNetworkQualityHistory` caps at 10, and
  Events would cap at 50. That's a view-model fetch limit, not a
  rendering problem, and arguably correct.
- `CGWindowListCreateImage` scoped to the app's own window remains the
  alternative if `ImageRenderer` ever proves inadequate for something
  else — it reads real on-screen pixels, so none of the above
  limitations would apply. Not pursued, since it almost certainly
  requires Screen Recording permission (a more alarming prompt than
  anything this app currently asks for) to fix problems that are now
  fixed anyway.

## Store size in the footer

Returning to the tooling punch list. Small, well-scoped addition: the
popover footer now shows the SwiftData store's real on-disk size next to
the build hash — "3.8 MB store" — read fresh on every render via
`StoreSizeService`.

**Must sum three files, not one.** SwiftData's SQLite backend runs in
WAL mode: recent writes live in a separate `-wal` file until a
checkpoint flushes them into the main `.store`, plus a small `-shm`
shared-memory index. Checked directly against the real store rather than
assumed correct — at one point the `-wal` file (4.2 MB) was larger than
the main `.store` file itself (2.0 MB). Reporting only the base file
would have understated real disk usage by more than half.

**Read fresh, not cached**, unlike `buildInfo` (which genuinely can't
change during a run — the code doesn't change while running). Store
size does change continuously, so `ContentView` holds only the store's
*location* (`storeURL`, a `let` set once at launch) and recomputes the
formatted size directly in `body` on every render — a cheap local file
stat, the same class of "fine to call synchronously from body" as other
computed properties already in this file.

**`nil` reported as absence, not zero.** Before the very first write (or
in the in-memory fallback path, where there's no real file on disk at
all), `StoreSizeService.totalBytes` returns `nil` rather than a
misleading "0 bytes" — same convention `NetworkQualityRecord`'s optional
RPM fields and `ConnectivityCheckRecord.systemLoad` already established
this session: absence and zero mean different things, and collapsing
them loses information.

Shares the existing build-hash row rather than adding a new one — no new
vertical space cost, matching every other footer addition. Verified
directly: measured the real store at 3.72 MB via `ls -la` on all three
files, and a live capture showed the footer reading "3.8 MB store,"
matching within expected rounding. Scenario suite still 11/11.

## No retention policy anywhere (measured)

This document has now run into the same gap four separate times — from
Network Quality, from latency sparklines, from the event log, and from
RRDtool — each time as a *consumer* of the problem rather than a cause.
The sparklines section explicitly asked whether it deserved its own
entry, independent of any one feature. It does. This is that entry.

**`SnapshotStore` has no retention or pruning logic for any table.**
The only `delete` anywhere in it is `deleteAllSNMPDevices`, which exists
to support a manual rescan, not to bound growth. Every other table grows
without limit for the life of the install. The various `fetchLimit`
values scattered around (events at 200, speed-test runs at 10, snapshots
at 100) bound *reads*, not the tables themselves — a bounded query stays
cheap regardless of table size, which is exactly why this has stayed
invisible.

### What it actually costs, measured rather than estimated

From a real store, 4h29m of continuous running on a normal home network
(10 ping targets: 6 fixed layers + 4 infrastructure devices):

```
ZCONNECTIVITYCHECKRECORD   4280     <- 90% of all rows
ZDISCOVEREDDEVICERECORD     375
ZAPPEVENTRECORD              49
ZNETWORKQUALITYRECORD        17
ZSNMPDEVICERECORD             6
ZNETWORKSNAPSHOT              4
everything else             1-2 each
```

`ConnectivityCheckRecord` dominates completely, and it's the one table
whose growth is driven by a *timer* rather than by events: one row per
target per round, ~103 rounds/hour at the normal 30s cadence, so ~953
rows/hour. At ~154 bytes/row (measured: 712KB store / 4736 rows,
including index overhead) that extrapolates to roughly:

| Window | Rows | On disk |
|---|---|---|
| Day | ~23,000 | ~3.5 MB |
| Month | ~690,000 | ~106 MB |
| Year | ~8.4 million | ~1.3 GB |

Two things make that worse than the table suggests. The fast-recheck
path drops the interval from 30s to 5s whenever anything is unhealthy,
so a sustained outage writes at ~6x the normal rate — the condition
under which the app is least useful to have degraded is exactly the one
that fills the disk fastest. And `maxInfrastructureTargets` caps
infrastructure pings at 6, so a bigger network doesn't grow rows
proportionally; the number above is close to the realistic ceiling per
round, not a small-network best case.

A gigabyte a year for a menu bar utility that nobody ever asked to keep
history is not catastrophic, but it is silent, unbounded, and entirely
invisible to the user — there is no UI anywhere that shows the store's
size, and no way to clear it short of deleting the file by hand.

### What a fix probably looks like

The natural shape is age-based pruning on write, not a background
sweeper: whenever a table gets a new row, delete rows older than that
table's own window. Different tables plainly want different windows —
`ConnectivityCheckRecord` is raw telemetry that's only interesting in
aggregate after a few days, while `AppEventRecord`, `PublicIPRecord`
and `DHCPLeaseRecord` are change-logs whose entire value *is* their age
(a DHCP server change from six months ago is exactly the kind of thing
someone would want to find).

That asymmetry is the real design content here: the tables that grow
fastest are the ones whose history matters least, which is a genuinely
favorable position to be in. Pruning `ConnectivityCheckRecord` to ~7
days would remove ~99% of the growth while touching nothing anyone
would miss.

Worth noting the latency-sparkline entry above depends on this being
resolved sensibly — it wants to read exactly the table that most needs
pruning, so the retention window and the sparkline's own time range
have to be decided together, not independently.

### Built: `SnapshotStore.pruneIfNeeded`

Implemented after five encounters. Deletes rows older than
`telemetryRetention` (7 days) from exactly the three raw-observation
tables — `ConnectivityCheckRecord`, `DiscoveredDeviceRecord`,
`BonjourDeviceRecord` — and nothing else.

**A finding that shaped the design: all three pruned tables are
write-only.** Verified across the whole source — each is inserted and
registered in the schema, and never fetched anywhere. So ~90% of the
store is data no code reads. That makes the window choice nearly
costless: 7 days is ~700x what the only planned consumer (latency
sparklines, ~20–30 points ≈ 10–15 minutes) would ever want, and is
sized for human forensics — "what was happening overnight?" — rather
than for anything that exists today. Steady state lands near 160k rows
/ ~24 MB, bounded and small.

Resolving the two open questions above: **per-table**, in the sense
that the change-logs simply aren't pruned at all rather than getting
their own longer window — the asymmetry was stark enough (4280
telemetry rows to 456 everything-else) that pruning only telemetry
removes essentially all growth. And **on write, throttled hourly**,
triggered from `saveConnectivityChecks`: launch-only never fires on an
app designed to run for weeks, and a dedicated timer would be a second
scheduling mechanism to own. Tying cleanup to the write that causes the
growth is self-limiting — an idle app writes nothing and needs no
cleanup.

### The bug this would have shipped with, caught only by testing

The first implementation used SwiftData's batch
`delete(model:where:)` for all three tables and `try?` throughout. It
built, ran, and crashed nothing. Verified by temporarily shortening the
window to two hours and counting rows before and after:

```
ConnectivityCheckRecord   4794 -> 1250   correct
DiscoveredDeviceRecord     425 ->  425   325 eligible rows untouched,
                                         oldest still 5 hours old
```

**`delete(model:where:)` silently does nothing on models that hold a
relationship.** `ConnectivityCheckRecord` has none and pruned fine;
`DiscoveredDeviceRecord` and `BonjourDeviceRecord` both carry
`snapshot`, and neither was touched. The `try?` swallowed whatever was
thrown, so nothing surfaced anywhere.

Fixed by fetching and deleting those two individually (affordable —
hundreds of rows, written per scan, not per check round) while keeping
the batch path for the one table that actually gets large, and by
logging errors instead of discarding them. Retested: 325 eligible rows
went to 0, and every change-log table stayed exactly at baseline
(events 51, speed runs 17, DHCP leases 2, snapshots 4, public IP 1,
SNMP devices 6, known networks 1).

The general lesson is worth more than the specific API quirk: **a prune
that silently does nothing is indistinguishable from a prune that had
nothing to do.** Deletion features can't be verified by building and
running them; they need before/after counts against data that should
actually be eligible.

### Still open

- Should the popover surface the store's size at all? Everything else
  in this app is observable, and this remains the one piece of state
  that accumulates silently. A line in the footer next to the build
  hash would cost nothing and make the problem self-reporting. Less
  pressing now that growth is bounded, but not resolved.
- The 7-day window is unvalidated against real use — it was chosen
  against a consumer that doesn't exist yet. If sparklines get built,
  revisit whether their range and this window still agree.
- Nothing prunes on a schedule when the app is idle. An instance left
  running with no network activity writes nothing, so there's nothing to
  clean — but an instance that ran hot for a month and then idled keeps
  that month's data until the next check round. Harmless given the
  bound, but worth knowing it's age-since-write, not wall-clock.

## The concurrency warnings — all four now fixed

A clean build used to emit exactly four warnings, all concurrency-related.
All four are now fixed; a clean build emits zero. **None was ever flagged
"this is an error in the Swift 6 language mode"** — the thirteen that
carried that marker were fixed earlier (see the commit clearing them;
every one was an outer `[weak self]` closure whose captured var was read
from an inner `Task`, resolved by re-capturing weakly in the inner
`Task`).

```
UIStateLogger.swift:90     call to main actor-isolated instance method 'enqueue'
                           in a synchronous nonisolated context
UIStateLogger.swift:123    call to main actor-isolated initializer 'init()'
                           in a synchronous nonisolated context
ConnectivityViewModel:200  call to main actor-isolated static method 'runDNSCheck'
                           in a synchronous nonisolated context
LANDiscoveryViewModel:48   capture of 'snapshot' with non-Sendable type
                           'NetworkSnapshot?' in a '@Sendable' closure
```

### The fourth one, fixed first (separately, earlier this session)

`LANDiscoveryViewModel.scan(for:)` took a `NetworkSnapshot?` — a
SwiftData `@Model`, a reference type with thread affinity — and captured
it into a `DispatchQueue.global` closure, carrying it across the thread
boundary without ever dereferencing it there (which is why it had never
crashed — SwiftData's affinity constrains property *access*, and nothing
touched a property off the main actor). Fragile rather than broken: the
moment any future line inside that closure read a property of `snapshot`,
it would become a genuine crash, and nothing in the code said "don't" —
notable given this exact file's comments already recorded a four-minute
beachball once, from a different threading mistake.

Fixed by inverting the nesting so the main-actor `Task` is the outer
scope and the background hop happens inside it — `snapshot` never leaves
the main actor at all:

```swift
Task { @MainActor [weak self] in
    let result = await Self.performScan(service)  // hops to background internally
    self?.apply(result, for: snapshot)            // snapshot never leaves the main actor
}
```

See the commit fixing this (`e650c00`) for the full verification: `arp`
still ran off-thread, devices delivered, the VRRP pair still merged
correctly.

### The other three: one root cause, and the earlier diagnosis was wrong about the fix's size

`UIStateLogger:90/123` and `ConnectivityViewModel:200` are the same
problem wearing different clothes: code that *deliberately runs off the
main thread* is nested inside (or a member of) a `@MainActor` type and
inherits isolation it never wanted.

- `WriterThread` is nested in `@MainActor enum UIStateLogger` — for a
  class whose entire reason to exist is owning its own pthread so it
  keeps draining when the shared pool is starved.
- `runDNSCheck` is a `static` member of `@MainActor final class
  ConnectivityViewModel` — for a function that blocks on `getaddrinfo`
  and must never run on the main thread.

**A fix was attempted once and reverted**, marking individual *members*
(not the enclosing type) `nonisolated`. That cascaded — a member marked
`nonisolated` while its enclosing type stays implicitly isolated can no
longer see that type's *own* other properties (`WriterThread.enqueue`
couldn't reach `pending`/`condition`), taking the warning count from 4 to
9. The conclusion at the time was that a proper fix meant "pushing
`nonisolated` outward through `OverallStatus` and `DNSResolutionService`
— a much larger change than three non-breaking warnings justify," and it
was left alone.

**That conclusion was revisited and found to overstate the cost.**
Re-reading `OverallStatus` and `DNSResolutionService` directly shows
neither has any real dependency requiring main-actor isolation —
`OverallStatus` is a stateless enum of constants and pure functions;
`DNSResolutionService` is a stateless struct wrapping a blocking
`getaddrinfo` call behind a semaphore. Both only *appeared*
main-actor-isolated because of a target-wide build setting neither
mentions: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (confirmed in
`project.pbxproj`), which silently isolates every type in the module by
default unless explicitly opted out — including plain structs and enums
with zero UI ties.

The actual fix ended up small, once the real diagnosis was made:

- `WriterThread`: mark the *class itself* `nonisolated`, not its
  individual members — since it's fully self-contained (never touches
  any of `UIStateLogger`'s other static state), this has nothing left to
  cascade into.
- `runDNSCheck`: mark the function itself `nonisolated` — safe, since
  its only two dependencies (`OverallStatus.dnsLabel`,
  `DNSResolutionService.probe()`) don't actually need main-actor access.
- `OverallStatus` and `DNSResolutionService`: mark both types
  `nonisolated` entirely. Safe in every direction — `nonisolated` never
  *prevents* a call from the main actor, it only removes the requirement
  to be on it — and neither type holds any state that isolation was ever
  protecting.

Verified directly: a clean build now emits zero project warnings (the
one remaining line, `appintentsmetadataprocessor: ... No AppIntents
.framework dependency found`, is an unrelated Xcode tooling notice, not
a compiler warning). Confirmed at runtime too, not just at compile time
— the main-thread heartbeat still fires normally after the `WriterThread`
change, a live DNS check still ran and produced a real result, and the
full scenario suite still passes 11/11.

### What this changes about adopting Swift 6 language mode later

Previously: adopting it would turn all four of these into hard errors,
requiring the isolation cascade to be worked through then instead of now.
That's no longer the real cost — there's nothing left in this category to
work through.

## Historical health score (green / yellow / red)

Distinct from `ConnectionLayer`'s real-time status (what's true right
now) — this is a trend signal: how has the network behaved over some
window (last hour, last day, last week). Worth keeping visually separate
from the live indicator rather than merging them, since conflating "down
right now" with "was flaky an hour ago" makes both harder to read at a
glance.

### Useful statistics

- **Latency: percentiles (p50/p95), not the mean.** Latency is
  right-skewed — a mean gets dragged by rare bad spikes and stops
  representing typical experience. p50 is "typical," p95 is "how bad do
  the worst moments get," which is usually the more actionable number.
- **Jitter, as its own axis**: std-dev or IQR on latency, separate from
  the median. Consistently-slow and wildly-variable read very
  differently to a user even at the same average.
- **Outage character: MTBF and MTTR, not just uptime %.** Derived by
  pairing up `AppEventRecord`'s existing down/up transitions. Five short
  outages and one long one can have identical total downtime but very
  different real-world impact — worth keeping as two numbers, not one.
- **Trend: a rolling recent-window vs. longer-baseline comparison**, not
  fixed absolute thresholds alone — accounts for some networks just
  being naturally noisier than others. Deliberately not reaching for
  ARIMA/anomaly-detection/ML here — disproportionate complexity and
  opacity for a single-network app; a black-box anomaly score is hard to
  explain to yourself when the indicator changes color. The plain stats
  above stay legible enough to debug by eye, which is worth more than a
  cleverer model here.

### Scoring scheme

Z-score against the network's own historical mean/SD for a given metric
(assumes higher = better — uptime %, throughput — not raw latency,
which would need inverting first):

- `z > 0` (above mean) → **green**
- `-1 ≤ z ≤ 0` → **yellow**
- `z < -1` → **red**

Asymmetric on purpose: for a roughly-normal distribution, "above the
mean" covers about half of all readings, so green means "at or above
typical," not "exceptionally good." That's the right shape for
something glanced at constantly — green should be the common case, not
a rare treat.

Two real costs of this approach, both worth accepting knowingly rather
than discovering later:

- **Self-relative, not absolute.** Mean/SD come from the network's own
  history, so a chronically mediocre network still reads green about
  half the time relative to its own drifted-down baseline. This answers
  "is today typical for this network," not "is this objectively good" —
  a different question than it might look like at a glance.
- **Needs a dead zone around `z = 0`.** Noise straddling the exact mean
  would otherwise flip the color on nearly every reading. Require
  something like `z > 0.1` / `z < -0.1` to actually change the displayed
  color, or a minimum-duration-in-zone rule — the same kind of
  hysteresis a thermostat uses to avoid short-cycling.

Also needs a minimum-sample-size guard: with too little history, mean/SD
are noise, not signal. Below some threshold, show "not enough data yet"
— the same shape as `ConnectionLayer`'s existing `.unknown` state —
rather than a color that looks confident and isn't.

### Storage: this is what the RRDtool section's open question was asking

The RRDtool section above concluded `SnapshotStore.pruneIfNeeded`
already closes the *unbounded growth* gap, but left one question
explicitly open: whether genuine long-term consolidated history (weeks
or months, not the sparkline's 10–15 minutes) is an actual goal. The
z-score baseline above is exactly that goal arriving — a multi-day (or
longer) mean/SD can't be computed from 7 days of raw rows once older
rows are pruned, and re-deriving it from scratch on every launch by
re-reading everything would be the "old fine-grained rows accumulate
forever" problem that section warned about, just moved earlier.

A narrow, SwiftData-native answer, without adopting RRDtool: store
**sufficient statistics** per day per layer, not raw rows — small,
additive, and enough to reconstruct an exact multi-day mean/SD without
re-touching the pruned raw data:

```swift
@Model
final class ConnectivityDailySummary {
    var layer: String              // matches ConnectionLayer's identifiers
    var day: Date                  // start of day, truncated

    var sampleCount: Int
    var successCount: Int

    // Sums, not pre-computed averages — additive across days, so a
    // multi-day mean/SD is exact, not an average of averages (which
    // would be wrong: you can't average per-day standard deviations
    // and get the correct combined SD).
    var latencySum: Double         // Σx
    var latencySumSquares: Double  // Σx²

    var outageCount: Int
    var outageDurationSum: TimeInterval   // feeds MTTR
}
```

Computed once per day (e.g. opportunistically at launch, rolling up
whatever `pruneIfNeeded` is about to discard, rather than a new
scheduler), then queried by summing the additive fields across the
requested window:

```swift
func baselineStats(layer: String, days: Int) -> (mean: Double, stdDev: Double)? {
    let summaries = fetchDailySummaries(layer: layer, sinceDays: days)
    let n = summaries.reduce(0) { $0 + $1.successCount }
    guard n > minimumSampleThreshold else { return nil }  // .unknown, not a guess

    let sum = summaries.reduce(0) { $0 + $1.latencySum }
    let sumSq = summaries.reduce(0) { $0 + $1.latencySumSquares }
    let mean = sum / Double(n)
    let stdDev = sqrt(max(0, sumSq / Double(n) - mean * mean))
    return (mean, stdDev)
}
```

Storage cost is trivial either way — roughly 1,460 rows/year across all
`ConnectionLayer` values kept indefinitely — so this isn't solving a
size problem, it's solving an information-loss problem: `pruneIfNeeded`
deleting raw rows after 7 days is exactly right for the sparkline use
case and exactly wrong for "what's normal for this network over the
last month," unless something like this sits between the two.

### Open questions before implementing

- Does this get its own UI element, or fold into an existing one (e.g.
  an outline/badge around the `ConnectionLayer` rows it summarizes)?
- One score per layer, or one overall score combining all layers
  (worst-of, matching the existing root-cause philosophy, or something
  else)?
- What's the actual minimum-sample threshold before trusting mean/SD —
  needs picking, not just gesturing at "enough history"?

## Business SaaS monitoring

A different kind of "is the network working" question: not "is the
internet reachable," but "are the specific services this business
actually depends on reachable" — Slack, Zoom, Salesforce, Microsoft
365, and similar. Splits into two problems with very different
feasibility.

### Discovery ("what's this Mac actually using") — real ceiling

`lsof -i -P -n` (bundled with macOS, confirmed working without root for
the current user's own processes) maps each live connection to the
local process that owns it — the same "shell out to an OS-native tool"
pattern as `ping`/`arp`/`traceroute`/`snmpget`. For a native SaaS
client — Slack.app, zoom.us, the Dropbox/OneDrive sync agents — this
cleanly answers "is Slack connected right now," no IP-address guessing
involved.

Two things limit it, one fundamental and one closeable:

- **Raw IP address doesn't reliably identify a service.** Most SaaS
  traffic sits behind shared CDN infrastructure (Cloudflare, Akamai,
  AWS) — one IP can serve many unrelated services, one service can
  present hundreds of IPs. `netstat` alone (IP:port, no process) can't
  distinguish services this way; `lsof`'s process-name mapping sidesteps
  the problem entirely for native apps, which is why it's the better
  tool here, not `netstat`.
- **Browser-hosted SaaS is invisible to process-mapping** — Salesforce,
  Google Workspace, and most CRM/HR/finance tools used through a browser
  tab all show up as "Safari"/"Chrome," indistinguishable by service.
  Real visibility would need the DNS query or TLS SNI hostname, which
  means actual packet capture — on current macOS that's a Network
  Extension / content-filter entitlement from Apple, not an Info.plist
  key like the Location/Local-Network permissions this app already
  requests. Materially bigger technical and administrative lift than
  anything else in this app — closer to building a Little Snitch than
  adding a monitored service. Treated as out of scope rather than
  chased.

### Monitoring (once you know what to watch) — the easy, useful part

Doesn't need discovery to work — a small, fixed list of SaaS endpoints
that matter (consistent with this app's existing minimal-configuration
bias) is enough on its own. Periodic reachability/latency checks against
those endpoints are the same pattern `HTTPCheckService` already runs
against the captive-portal probe, just pointed at a business SaaS
endpoint instead — and feed directly into the health-score design above
with no new storage shape needed, since a SaaS check is just another
`ConnectionLayer`-shaped row.

**Prefer a vendor's status-page API over pinging their marketing
domain**, where one exists — it reports actual service state
("operational"/"degraded"/"major outage") rather than inferring health
indirectly from raw request latency, the same reason `HTTPCheckService`
already checks a real endpoint instead of a bare ping. The following
were checked directly (`curl`, live, this session) rather than assumed
from documentation:

| Service | Endpoint | Format |
|---|---|---|
| Slack | `https://slack-status.com/api/v2.0.0/current` | JSON |
| Zoom | `https://www.zoomstatus.com/api/v2/summary.json` | JSON |
| Salesforce | `https://api.status.salesforce.com/v1/instances/<INSTANCE>/status` | JSON, per-org instance |
| Google Cloud | `https://status.cloud.google.com/incidents.json` | JSON |
| Jira / Confluence | `https://status.atlassian.com/api/v2/summary.json` | JSON |
| Trello | `https://trello.status.atlassian.com/api/v2/summary.json` | JSON |
| Asana | `https://status.asana.com/api/v2/summary.json` | JSON |
| Notion | `https://www.notion-status.com/api/v2/summary.json` | JSON |
| Dropbox | `https://status.dropbox.com/api/v2/summary.json` | JSON |
| Zendesk | `https://status.zendesk.com/api/incidents/active` | JSON (custom, not Atlassian-shaped) |
| Intercom | `https://www.finstatus.com/api/v2/summary.json` | JSON (rebranded domain) |
| Xero | `https://status.xero.com/api/v2/summary.json` | JSON |
| QuickBooks / Intuit | `https://status.quickbooks.intuit.com/api/v2/summary.json` | JSON |
| Gusto | `https://status.gusto.com/api/v2/summary.json` | JSON |
| BambooHR | `https://bamboohr.statuspage.io/api/v2/summary.json` | JSON |
| NetSuite | `https://status.netsuite.com/api/v2/summary.json` | JSON |
| AWS | `https://status.aws.amazon.com/rss/<service>-<region>.rss` | RSS (legacy, unauthenticated; the modern Health Dashboard requires sign-in) |
| Azure | `https://azure.status.microsoft/en-us/status/feed/` | RSS |

No public, unauthenticated endpoint found for three, despite looking:
**Microsoft 365** (the real API — Microsoft Graph Service
Communications API — requires an OAuth app registration; confirmed
`401` without one), **Workday** (`status.workday.com` redirects
straight to a SAML login, tenant-authenticated only), and **ADP** (no
public status page found at all). A plain `HTTPCheckService`-style
reachability check against their login domain is the fallback for
these three — there's no higher-signal alternative to prefer.

One flagged as unreliable despite existing: **Okta** — Statuspage-
powered per its page source, but `status.okta.com/api/v2/summary.json`
returned `401` on a direct, unauthenticated request even though the
human-facing page loads fine, suggesting bot/access protection on the
API path specifically. Worth a periodic re-check rather than building
on it as-is.

### Where this fits the existing green/yellow/red severity scheme

Red is already reserved for the core network itself being broken
(interface/router/DNS/HTTP/Internet unreachable) and yellow already
means "marginal" — something worth noting that isn't a core-network
failure. A SaaS outage is exactly that shape: the network is fully
healthy, but a service that's depended on isn't. That's a better fit
for yellow than a stretch, but it raises two questions the existing
single-LAN-device definition of yellow never had to answer:

- **Does SaaS monitoring share yellow with the current trigger, or
  replace/extend it?** Today yellow means "a monitored LAN device (not
  the router) is unreachable." If SaaS reachability gets folded into
  the same color without a way to tell them apart, yellow starts
  meaning "either a LAN device is offline or a business SaaS app is
  down" — two structurally different problems collapsed into one
  glance-level signal. Solvable (the app already has a root-cause
  drill-down pattern for `ConnectionLayer`), but worth deciding
  deliberately rather than by accident.
- **Should every SaaS outage land at exactly yellow, or should severity
  scale with what's actually affected?** A low-priority internal tool
  being briefly unreachable and a CRM being down during business hours
  aren't the same severity, even though both are "network's fine, a
  SaaS app isn't." Yellow is currently defined as low-stakes by
  default ("worth noting, not itself a real problem") — that
  undersells a Salesforce outage in a way it doesn't undersell an
  offline printer. Once several SaaS services are monitored at once,
  there's a real choice between "any outage triggers yellow uniformly"
  and "severity scales with how many/how critical the affected
  services are," potentially warranting something above yellow even
  with the underlying network fully healthy.

### Does this vary by network? (home / coffee shop / office)

Splits into two signals that have been talked about as one so far, and
they behave oppositely once you're roaming between networks:

- **A vendor's own status-page result is a global fact.** If Slack's
  status API reports a major outage, that's true at home, at a coffee
  shop, and at the office, all at once — it doesn't need per-network
  tracking, and scoping it to whichever `KnownNetwork` happened to be
  active when it was observed would be actively wrong. One real-world
  incident, reported the same way regardless of location.
- **The plain-reachability fallback (Workday/ADP/Microsoft 365, or
  anything without a status API) genuinely is network-dependent.** A
  stricter office network might filter or block a SaaS domain outright;
  a coffee shop's captive portal can make *everything* fail until you
  log in, which isn't "Slack is down" at all. Neither should be
  reported as a global SaaS outage — they're local-network problems,
  and should be tagged by `KnownNetwork` (already in the app,
  fingerprints by gateway MAC) the same way other per-network state
  already is, specifically so "blocked at the office" doesn't get
  misreported as "Slack is down" once you're back home on a network
  where it works fine.

Practical consequence: a status-API check reporting an outage should
be cross-checked against whether the core `ConnectionLayer` layers
(router/DNS/HTTP) are themselves healthy first. If they're not, there's
no internet at all, and "the SaaS service is down" would be the wrong
diagnosis — only trust a status-API outage reading when the underlying
network is otherwise fine.

This also reaches back into the health-score baseline design above: if
SaaS latency ever gets folded into the same z-score-against-historical-
baseline scheme as everything else, mixing home-fiber latency with
coffee-shop-WiFi latency into one baseline would produce a number that
means nothing — "normal" at a coffee shop looks nothing like "normal"
at home. That baseline would need to be computed per-`KnownNetwork`,
not globally, for the same reason the reachability signal does.

### AI assistants: Claude, ChatGPT, Gemini

For a lot of people right now this category is as load-bearing as
Slack or a CRM — a real candidate for the "critical" flag above, not a
novelty addition. Same direct verification as the rest of this table:

| Service | Endpoint | Format |
|---|---|---|
| Claude (Anthropic) | `https://status.claude.com/api/v2/summary.json` | JSON — confirmed live; status.anthropic.com now redirects here (recent rebrand). Tracks `claude.ai`, the API, Claude Code, etc. as separate components |
| ChatGPT (OpenAI) | `https://status.openai.com/api/v2/summary.json` | JSON — confirmed live; tracks ChatGPT, API, Images, Playground, Sora separately |
| Gemini (Google) | — | No public JSON API found. `aistudio.google.com/status` is plain HTML; Gemini incidents are otherwise scattered across Google Cloud's general dashboard (not Gemini-specific) and the Google Workspace dashboard (consumer app only). Plain reachability check against `gemini.google.com` is the honest fallback, same shape as the M365/Workday/ADP gap below |

Both Claude and ChatGPT ship native macOS apps (`Claude.app` confirmed
installed on this machine), so the `lsof`-based native-app signal
above applies to them directly too — no domain-guessing needed to tell
whether the app itself is running and connected.

### Identity/SSO providers, and Apple/iCloud

Identity providers are arguably the highest-leverage entries to
monitor in this whole list — if Okta or Auth0 goes down, it doesn't
degrade one app, it can cut off login to everything that depends on
it. Stronger "critical" candidates than most individual productivity
apps. Also verified directly:

| Service | Endpoint | Format |
|---|---|---|
| Apple (iCloud, App Store, etc.) | `https://www.apple.com/support/systemstatus/data/system_status_en_US.js` | JSON — confirmed live, and unusually granular: separate entries per iCloud sub-feature (Account, Backup, Bookmarks, Calendar, Contacts, Drive, Keychain, Mail, Notes, ...), not one blob like everything else in this table |
| Auth0 (Okta) | `https://auth0.statuspage.io/api/v2/summary.json` | JSON |
| Duo Security (Cisco) | `https://status.duo.com/api/v2/summary.json` | JSON |
| Ping Identity | `https://status.pingidentity.com/api/v2/summary.json` | JSON |

Two more checked and not resolved, same as the earlier gaps: **OneLogin**
(no working status API found — the obvious `onelogin.statuspage.io`
guess just redirects to Statuspage's own homepage, not a real page)
and **Microsoft Entra ID / Azure AD** (no separate status page at all —
folded into the Azure/M365 dashboards already listed above; nothing
new to add, Azure's existing RSS entry already covers it).

Worth a decision before implementing: Apple's per-sub-feature
granularity is finer than every other entry in this table (which
report one status per named component). Does NMS care about "iCloud"
as a single thing, or is exposing that it's specifically iCloud Backup
that's down (say) actually useful?

### Login/session signals for discovery — what to use, what to avoid

A different question from monitoring itself: could NMS use the fact
that the Mac is actively logged into a SaaS service to *auto-discover*
what's worth monitoring, instead of requiring the user to type each
one in? Two categories of answer here, and they're not close calls in
either direction.

**Ruled out — touches actual credential/session material:**

- **Reading Keychain-saved passwords** for other apps/sites needs
  either a disruptive per-item consent prompt or Full Disk Access — an
  extremely broad, all-or-nothing grant, wrong to ask for from a
  background monitoring utility. Also a saved password only proves
  "an account exists," not "currently logged in" — a static fact, not
  a live one.
- **Reading browser session cookies** (the actual proof of an active
  login) is a materially bigger ask than anything else in this app's
  design — functionally equivalent to being able to impersonate the
  user's live sessions to those services. Ruled out independent of
  technical feasibility; this is exactly the kind of access that
  should require explicit, per-service, informed consent, not passive
  background monitoring.

**Worth considering — doesn't touch credentials at all:**

- **Browser tab inspection via AppleScript/Apple Events**
  (`tell application "Safari" to get URL of every tab of every
  window`, or Chrome's equivalent) can tell whether a tab is open to
  `slack.com` or `salesforce.com` without ever reading a password or
  cookie. Partially closes the "browser-based SaaS is invisible to
  `lsof`" gap noted above, specifically for *discovery* — suggesting
  what to monitor, not proving an active session. Real costs: needs an
  Automation permission prompt ("NMS wants to control Safari"), a
  genuine user-facing consent step; and it's a weaker signal than it
  sounds — an open tab doesn't prove authentication, and most SaaS
  sessions outlive the tab being open anyway, so a closed tab doesn't
  prove logged-out either.
- **macOS's own Internet Accounts** (System Settings → Internet
  Accounts) — if the user has already added a Google or
  Microsoft/Exchange account at the OS level, that's an explicit,
  already-consented signal about which identity providers matter to
  them, without touching a password. Not verified here whether there's
  a clean public API to enumerate that list generically, versus access
  scoped per-framework (Contacts/Calendar/Mail); needs checking before
  relying on it.

Net position: neither of the acceptable options proves an active
session the way Keychain/cookie access would — both are meant for
*discovery* (auto-suggesting a starter monitoring list), not as a
live "are you logged in right now" gate on whether a check counts.

### The privacy risk isn't hypothetical — confirmed by actually running it

Ran both `lsof -i -P -n` and a real AppleScript tab scan (`tell
application "Brave Browser" ... get URL of every tab of every
window`) live against this Mac, not just designed on paper. `lsof`
behaved exactly as scoped — process-to-connection mapping only, no
sensitive content. The tab scan is where the risk stopped being
theoretical: alongside the expected SaaS-relevant tabs (GitHub, a
statuspage-related search), it also returned several tabs that were
personal investment/finance research — a portfolio-tracking URL among
them — with zero discrimination between "useful for SaaS discovery"
and "none of this feature's business." The scan doesn't know the
difference; it returns every open tab, full URLs included.

That confirms the fix from the design above isn't optional, and
sharpens what it needs to be: **filter against the known SaaS domain
table immediately, in memory, before anything else happens with the
result.** Non-matching tabs must never be logged, displayed, written
to any persisted store, or even held past the filtering step — not
"redact before display," which would still mean the raw list existed
somewhere first. The only output of this subsystem should be "these
of your configured/candidate SaaS domains have an open tab," never
the tab list itself in any form.

One thing the same test validated positively: combining the two
signals produced a more confident read than either alone — `lsof`
independently confirmed the GitHub connection the tab scan also
showed (Brave holding a connection to GitHub's own dedicated IP range
at the same time a GitHub tab was open), the same "combine, don't
pick one" argument the LAN-discovery section above makes for ARP vs.
SNMP vs. the switch's MAC table. Relevant to the open question below
about whether to combine the status-page check with the `lsof`
signal — this is a second, independent data point in favor of
combining rather than treating them as redundant.

### Can network activity be attributed to a specific tab? No — checked directly, not assumed

Came up while thinking through the priority-tracking idea above: if
tab-open-frequency risks over-weighting stale tabs left open for
days, could actual network activity per tab do better — is this tab
still *live*, not just open? Checked rather than assumed, since it
matters which answer is true.

Brave's process tree right now has roughly 20 separate renderer
processes, one per tab/site (confirmed via `ps`). But every
connection `lsof -i` reports is attributed to a single shared helper
process — none of the individual renderer PIDs carry any network
connections at all. This isn't a missing capability to work around;
it's how Chromium's architecture actually works — all real network
I/O is centralized in one shared network-service process regardless
of how many renderer processes exist for tab isolation. The
OS-visible process boundary and the tab boundary don't line up for
network traffic, so no amount of `lsof`/`ps` cleverness gets from
"this connection" to "this tab." Confirmed for Brave (Chromium); not
checked for Safari, whose WebKit process model may differ.

The only place that association genuinely exists is inside the
browser itself — a browser extension using `chrome.webRequest`
(which does expose a `tabId` per request) or Chromium's internal
`net-export`/DevTools Protocol logging. That's a materially heavier
design than anything else here: a separate installable artifact,
browser-specific (wouldn't cover Safari the same way), and it would
need its own channel back to the native app (native messaging or a
local socket) — a new category of complexity, not a refinement of
the AppleScript approach. Not pursued further for now.

Practical consequence for the stale-tab problem: since
network-correlation is a dead end at the OS level, **which tab is
currently frontmost/active** (AppleScript can get this directly —
`active tab of front window`) is the honest ceiling of what's
available without taking on a browser extension. Weaker than true
per-tab activity data, but a real, achievable recency signal — better
than raw open-frequency alone, and doesn't require anything beyond
what the rest of this section already proposes.

### Does the macOS DNS cache help? No — checked directly, rejected on two independent grounds

Same instinct as the network-attribution question: the system DNS
cache holds recently-resolved hostnames, which in principle could
surface SaaS domains a browser tab-scan or `lsof` might miss. Checked
directly on this machine rather than assumed:

```
$ dscacheutil -cachedump -entries Host
Viewing host entries requires administrator privileges.

$ dscacheutil -statistics
Unable to get details from the cache node
```

Confirmed: even the lightest statistics query is blocked without
root. The one technique that does still work —
`sudo killall -INFO mDNSResponder`, which makes mDNSResponder dump its
cache state to the system log rather than a queryable API — still
needs `sudo`. That's a different privilege class than anything else
in this app: `arp`/`ping`/`traceroute`/`snmpget`/`lsof` are all usable
by a regular account, no elevation needed anywhere. Root access here
means either prompting for a password (nothing else in NMS does that)
or a privileged helper tool — a new architecture category, not a flag
on an existing shell-out.

Rejected on a second, independent ground even setting privilege
aside: the content itself is worse than what's already designed for
this purpose.
- **No history** — TTL-evicted, point-in-time only, same limitation
  `arp -a` has, but without this app's existing periodic-snapshot
  workaround for that problem.
- **No attribution to origin, worse than the per-tab finding above**
  — the system DNS cache is shared by every process on the Mac, not
  scoped to one browser, so a cached entry can't be traced to a SaaS
  tab vs. a background OS check vs. an ad network.
- **Much noisier** — a single page load triggers lookups for a dozen
  third-party/tracker/CDN domains unrelated to the page's actual
  purpose, with no clean way to separate those from the domain the
  user actually cares about, unlike the tab list (which only contains
  URLs the user actually navigated to).

Net: a real, verifiable macOS capability, but strictly worse than the
tab-scan approach already proposed on every axis that matters here —
more privileged, less attributable, noisier. Not worth building.

### Bookmarks and history — one usable the same way as tabs, one rejected like Keychain

Checked directly, and the two need different treatment, not the same
one.

**Bookmarks (Chromium/Brave): fully readable, no special permission
at all.** A plain JSON file under the user's own `~/Library/
Application Support/...`, owned by the user, no TCC gate. Verified by
actually parsing it: 2,267 real bookmarks read back successfully, no
prompt, no Full Disk Access.

**History (Chromium/Brave): not TCC-blocked, but unreliable in
practice while the browser is running.** The file itself is readable,
but querying the live SQLite database returned `database is locked` —
Brave holds a lock on it whenever it's open, which is essentially
always for a browser in active use. Working around that means copying
the file first and querying the copy, not querying in place.

**Safari: both blocked outright.** `ls` on Safari's data directory
(legacy path and the modern sandboxed-container path) returned
"Operation not permitted" — real TCC protection, stronger than
Chromium's plain-file approach. Reaching Safari's data at all would
need Full Disk Access, the same broad grant already ruled out for
Keychain above.

Recommended treatment, and they diverge:

- **Bookmarks**: viable as a discovery source, same rules as the tab
  scan above — filter against the known SaaS domain list immediately,
  never persist or display the rest. Worth weighing that a bookmark
  is a weaker recency signal than an open tab (bookmarked once, years
  ago, proves nothing about current use) even though it's a more
  deliberate one ("I cared about this" vs. "I happen to have this
  open").
- **History**: reject on the same grounds as Keychain/cookies above,
  not treated as "the tab scan, but bigger." It isn't credential
  material, but it is a comprehensive log of everywhere the user has
  ever browsed, and the copy-the-file workaround needed to dodge the
  lock makes "the app briefly holds the whole thing" concrete rather
  than theoretical. It would genuinely solve the frequency/recency
  problem better than anything else considered — Chromium's schema
  already tracks `visit_count` and `last_visit_time` per URL, so no
  new sampling system would be needed — but that convenience isn't
  worth what it costs. If ever revisited, it needs its own explicit,
  separate consent, not bundled into "the tab-scan feature" as if
  it's the same ask.

### Open questions before implementing

- Which services actually get a built-in entry vs. requiring the user
  to supply a domain — full table above, or a smaller curated subset?
- Combine the status-page check with an `lsof`-based native-app signal
  when both exist (e.g. Slack), or keep them as two independent checks?
  A status-page "operational" plus the local app showing no open
  connections would be a genuinely useful combined signal, not just
  redundant.
- Does an unresolvable service (Workday/ADP/M365/Gemini/OneLogin) get
  a visibly different UI treatment ("reachability only, no status
  API") so it isn't mistaken for the higher-confidence
  status-page-backed checks?
- Does SaaS monitoring share yellow with the existing LAN-device
  trigger, or get its own visually distinct signal?
- Does severity scale with the number/criticality of affected SaaS
  services, or does any single outage trigger the same yellow
  uniformly?
- Is AppleScript-based tab inspection worth the Automation-permission
  ask for a discovery aid alone, or should the built-in table above
  just be considered good enough as a starting default?
