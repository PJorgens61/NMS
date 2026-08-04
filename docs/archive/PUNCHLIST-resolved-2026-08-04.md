# Resolved punchlist items (archived 2026-08-04)

Items checked off `PUNCHLIST.md`'s "Open" section as of 2026-08-04,
moved here to keep that file scannable. Each entry's original reasoning
is preserved verbatim -- this is an archive, not a summary. See
`PUNCHLIST.md` itself for what's still open, and `DESIGN-NOTES.md` for
the deeper reasoning behind anything non-obvious that these entries
reference.

- [x] ~~Estimate and document NMS's system requirements.~~ **Built**
  (`306e009`, found already done while sweeping the open list for
  partial/already-landed work). `README.md`'s "System requirements"
  section has exactly what this item asked for: measured (not
  estimated) CPU (0.9% of one core steady-state), memory (~74 MB
  resident), disk (~3.6 MB early, ~35 MB projected at 7-day steady
  state), and network use, plus macOS version/hardware floor — real
  numbers from the app's own instrumentation
  (`ConnectivityCheck.systemLoad`, `StoreSizeService`), not adjectives.
  Never checked off here even though the work landed.

- [x] ~~Shrink SNMP Devices' box height.~~ **Superseded — not built as
  proposed, and the premise no longer holds.** This item's baseline
  (`200` → `150`) is stale: `SectionLayout.boxHeight(on:)`'s
  `.snmpDevices` case is `300` today, not `200` — box height went
  through its own separate, live-tested saga this session (several
  explicit height changes while chasing an unrelated `sysDescr`
  text-truncation bug) and landed at `300`, the opposite direction from
  this item's request. The truncation bug itself was ultimately fixed a
  different way — splitting `sysDescr` into fixed single-line `Text`s
  (`sysDescrLines(_:)`) rather than relying on wrapping inside a taller
  box — so the box height and the wrap-accommodation reasoning this item
  cited are no longer connected the way its own text assumed. If
  shrinking the box is still wanted, it needs a fresh look against the
  current `300`/line-split reality, not this text.

- [x] ~~Network Health and Info tiles: real content overlap, worth a
  combined design.~~ **Built.** Merged into one "Network" tile
  (`ContentView.connectionHealthSection`) — `infoSection` is gone
  entirely, its content folded row-by-row into the matching
  `ConnectionLayer` rather than kept as a separate trailing section:
  Router/Public IP/DNS now show their identity value alongside
  reachability/timing in one row each ("10.0.0.1 · 8ms"), ISP's name
  and status-page link moved onto the ISP Edge Router row, and the
  known-network count + this Mac's own IP moved onto the Network row.
  `publicIP.lastError` and `ddnsRow` still render, now at the bottom of
  the merged tile instead of Info's own bottom.

  The `networkQuality` quick check moved to the top of the Grid (most
  aggregate/dependent signal of the set) and gained a real dot-history
  trail in its sparkline slot, backed by new persistence that didn't
  exist before: `NetworkQualityResult`/`NetworkQualityRecord` gained a
  `.quickCheck` source case and a `combinedResponsivenessRPM` field
  (`downloadMbps`/`uploadMbps` widened to optional, safe-migration
  shape), `SnapshotStore.fetchQuickCheckHistory(limit:)` reads them
  back per-network-scoped, and `runQuickCheck` persists a row on every
  run. Visual iteration mattered here: an evenly-`Spacer`-distributed
  row of 2pt dots stretched to the layer rows' shared 44pt sparkline
  width was confirmed live to be technically-visible-but-unreadable;
  shipped instead as 5pt dots at a fixed 2pt gap, packed tight and
  growing with history rather than pinned to that width.

  Also added while this tile was open, raised directly: a DHCP status
  row (`dhcpGridRow`) with a three-state color
  (green/yellow/red = normal/changed recently/abnormal) that doesn't
  reuse `LayerStatus` — `.unknown` already means "nothing to judge yet,"
  not "changed," so it needed its own tri-color logic
  (`dhcpStatusColor`) rather than a fourth `LayerStatus` case.
  `DHCPLeaseViewModel.isRenewalOverdue` is new too — the overdue signal
  already existed for event logging but wasn't published for the UI to
  read before now.

- [x] ~~Info tile: move the DDNS row above the ISP row.~~ **Superseded
  by the Network Health/Info merge above**, not built as originally
  described — the structure this referred to no longer exists. There's
  no separate "ISP row" to reorder against anymore (folded onto the ISP
  Edge Router row), and `ddnsRow` already moved as part of that merge
  (now at the bottom of the merged tile, alongside `publicIP.lastError`).
  If a specific DDNS position is still wanted relative to the new
  layout, that's a fresh request against the current structure, not
  this one.

- [x] ~~Rebuild the UI from scratch in "simpler" SwiftUI, to stop the
  recurring breakage?~~ **Done — rebuilt as a traditional single-window
  app.** Investigated before rewriting: the breakage wasn't accidental
  complexity, it was three separate `MenuBarExtra(.window)` platform
  gaps (no pure-SwiftUI fix for bounce-free chaining scroll, `.help()`
  rendering nothing, and safe screenshotting) each papered over with its
  own AppKit bridge (`NoBounceScrollView`, `ToolTip.swift`,
  `ImageRenderer`-based capture) — and each bridge accumulating its own
  interop bugs (`Grid` clipping, SNMP Devices clipping, the Events-list
  ghosting) as the app grew. Rather than keep patching bridges, dropped
  the popover entirely for a `.regular`-policy single window: that alone
  made `.help()` work natively (deleted `ToolTip.swift`), made a real
  window-scoped screen capture safe (deleted the whole Screenshot/Bug
  Report feature — redundant with `Cmd+Shift+4` on a real window
  anyway), and removed the reason `NoBounceScrollView` existed (deleted
  it for a plain `ScrollView`, with `.frame(maxHeight: .infinity)` to
  stop the window floor-clamping to full content height). The `Grid`
  clipping bug did not reoccur once `NoBounceScrollView` was gone,
  confirming it was an AppKit-bridge quirk, not a `Grid` bug. Also added
  `ContentView+Preview.swift`'s `#Preview` support (the project had none
  before) so future tile layout changes don't need a full
  build-relaunch-screenshot cycle to check.

- [x] ~~Website: mention bufferbloat detection (via macOS's built-in
  `networkQuality`) in the homelab section.~~ **Shipped** (`gh-pages`
  `83fcaa4`): a new homelab feat-list bullet — "Runs Apple's own
  networkQuality test on demand to catch bufferbloat... know it's the
  network, not your aim" — a different pitch than the swift-programmers
  section's existing `networkQuality` bullet (that one sells "implements
  a real IETF standard" for developer credibility; this one sells the
  outcome).

  **A gaming-specific angle was considered and explicitly rejected as
  its own hop-section, resolved directly**: competitive gamers
  overwhelmingly play on Windows, not macOS, and a dedicated pitch for
  an audience that mostly can't run the product isn't worth building —
  "that's their problem, not this app's." Real nuance kept, though:
  NMS doesn't need the *gamer* to be the Mac user, just a Mac somewhere
  on the same home network (someone working on a MacBook while gaming
  happens on a separate Windows rig/console down the hall still shares
  one connection) — so gaming shipped as one concrete example inside
  the bufferbloat bullet itself, not as its own section, and the
  shipped copy states it plainly rather than hedging about the
  Windows/macOS split.

- [x] ~~A local Wi-Fi stress test: many concurrent MTU-sized ping
  streams to the local router for ~1 second.~~ **Built** (`90f584f`) as
  the "Local Stress Test" tile — reports packet loss and RTT min/avg/
  max/stddev across the burst, plus this Mac's own CPU load during it
  (`CPULoadSampler`). Matches the design below: N independent concurrent
  `ping -c 1 -s 1472 -D` streams, no `-f`/flood mode, no elevated
  privileges. Gated on a known router address (`currentInterface?.routerAddress`)
  and works over Ethernet too, not just Wi-Fi — the mechanism doesn't
  care which link carries it, so the tile is titled "Local," not
  "Wi-Fi." Ships with the "generates real traffic" framing flagged
  below: an opt-in confirmation alert before the first run per launch.
  The TCP/UDP idea below is still open — this only covers the local-hop
  ping stress test. Raised directly, motivated by validating the
  local Wi-Fi specifically *before* trusting any test that crosses the
  internet — several test networks used this session had slow DSL,
  where an internet-facing test can't tell you whether a problem is
  local or upstream. Small networks in particular have no one
  monitoring them, so a self-triggered local check has real value on
  its own. The local router is already a known address with no new
  discovery work (`traceroute` hop 1 / `NetworkIdentityViewModel`'s
  recognized gateway).

  **Concurrency, not flood mode, is the actual mechanism — resolved
  directly over the course of this discussion.** The first instinct
  (`ping -f`, true kernel flood mode) is a dead end: it requires root,
  which this app doesn't have and shouldn't ask for. The real design
  is **N independent concurrent streams, each just repeated `ping -c 1
  -s 1472 -D`** (`-s 1472` for a full 1500-byte MTU after the 28-byte
  IP+ICMP header, `-D` so an oversized packet fails loudly instead of
  silently fragmenting) — each stream fires its next packet the
  instant its own previous reply lands, independent of every other
  stream, for a fixed ~1 second window. No `-f`, no elevated
  privileges, at any concurrency.

  **Why concurrency is what makes this work at all**: a single ping
  stream is fundamentally round-trip-time-bound, not bandwidth-bound —
  at a typical ~2ms local RTT, one stream tops out around 500 packets/
  sec, which at MTU size is only ~6 Mbps, nowhere near enough to
  stress a real Wi-Fi link. N independent concurrent streams multiply
  that roughly linearly (~20 streams ≈ 120 Mbps) since each is its own
  independent request/reply chain — the only reason this approach can
  generate meaningful load at all. There's no fixed load-percentage
  target here (raised and then explicitly dropped as a requirement) —
  the point is generating *real, sustained* load for about a second
  and seeing how the link responds, not hitting a specific number.

  **What this can and can't actually reveal — worth being precise
  about, prompted by a comparison to classic T-1 BERT (bit-error-rate)
  testing with specialized bit patterns.** This is a real, useful, but
  *different* mechanism, not the same technique: BERT uses deliberately
  chosen worst-case bit patterns (all-1s, alternating, pseudorandom) to
  stress specific physical-layer failure modes; `ping`'s payload is
  just an incrementing byte pattern, not a designed stress pattern. It
  doesn't replicate BERT. What concurrent MTU-sized load genuinely does
  expose that small pings don't: packet loss/corruption specifically
  under sustained large-frame load — a marginal Wi-Fi signal often
  handles small packets fine while dropping or retransmitting large
  ones once the link is loaded, a real and different failure mode from
  what one small ping can show.

  **Chased down directly: is there an 802.11-specific "best" ping
  payload bit pattern the way BERT has one for T-1? No — and the
  reason is a genuine, checked-not-assumed answer, not a shrug.**
  Every 802.11 payload passes through a mandatory PLCP scrambler (a
  length-127 PRBS, polynomial x⁷+x⁴+1) that XORs every payload bit with
  a pseudo-random sequence before it ever reaches the PHY/modulation
  stage — the standard's own built-in equivalent of what BERT patterns
  manually engineer for unscrambled serial lines. Whatever content
  `ping` puts in its payload gets whitened into essentially the same
  statistical bit distribution before transmission regardless, so
  payload-content tuning is a dead end at this layer; there's no lever
  available for the app to pull here. Independent confirmation from
  the other direction: ["Are All Bits
  Equal?"](https://ieeexplore.ieee.org/document/6361252/) (IEEE
  Trans. Networking, also on
  [ResearchGate](https://www.researchgate.net/publication/260353749_Are_All_Bits_Equal-Experimental_Study_of_IEEE_80211_Communication_Bit_Errors))
  found 802.11 bit errors correlate with *position within the frame*
  (a roughly linear relationship, plus some hardware-dependent
  patterns), not with bit value — consistent with the scrambler already
  washing out content-dependent effects. This actually validates the
  design above rather than changing it: MTU-sized packets matter
  because they're larger and spend longer on air (more exposure to a
  fade or interference burst mid-transmission), not because of what's
  in them — size and volume are the real, available knobs, which is
  exactly what concurrent MTU-sized streams already target.

  **Two practical limits to design around, not just build past**:
  1. **Process-spawn overhead becomes the real ceiling at high
     concurrency.** Each stream is a real subprocess
     (`Process()`/fork+exec, the same mechanism `ConnectivityService`
     already uses) — above some concurrency count, the test starts
     measuring this Mac's own process-spawn rate instead of the Wi-Fi
     link. 20-30 concurrent streams for ~1 second is almost certainly
     fine; hundreds probably isn't. Needs an empirical check on real
     hardware before picking a default.
  2. **Still worth a clear "this generates real traffic" framing**,
     even bounded to ~1 second and root-free — this app's first
     feature whose whole point is deliberately loading the network
     rather than quietly observing it, the same category of "needs an
     explicit yes" already flagged for the external-firewall-checker
     idea further down, just at a much smaller/safer scale (1 second,
     LAN-only, no elevated privileges) than a sustained flood would be.

  **What the test should actually report**: aggregate sent/received
  counts across every stream (loss %) and RTT distribution (min/avg/
  max, maybe stddev) during the burst — that's the real diagnostic
  payoff, not just confirmation that load was generated.

- [x] ~~Give Apple's `networkQuality` its own tile, separate from
  Speed Test.~~ **Shipped** (`4eb6f81`): a dedicated "Apple
  networkQuality" tile with its own run history, real byte-transfer
  reporting, a "View Full Report" verbose-output sheet, and a
  popover-only 5-second quick check with a green/yellow/red verdict.
  Also added to the website's homelab section (`gh-pages` `e1dfcb9`,
  copy refined further in `4361a25`) — "Runs Apple's own networkQuality
  test on demand to catch bufferbloat... Know if it's the network, not
  your aim."

- [x] ~~Add GitHub to the SaaS monitoring list.~~ **Built.** Confirmed
  live via `curl` first (`www.githubstatus.com`, standard `.statuspage`
  shape, healthy at verification time), then added as a plain
  `MonitoredService` entry. `PreferencesView.swift`'s description text
  updated to include it.

- [x] ~~Add Cloudflare, Figma, HubSpot, and Docusign to the SaaS
  monitoring list.~~ **Built.** All four confirmed live via `curl` first
  and added as plain `.statuspage`-shaped `MonitoredService` entries —
  zero new parsing code:
  - Cloudflare: `https://www.cloudflarestatus.com/api/v2/summary.json`
    (confirmed live *during* a real "Minor Service Outage" — not just
    the healthy path)
  - Figma: `https://status.figma.com/api/v2/summary.json`
  - HubSpot: `https://status.hubspot.com/api/v2/summary.json`
  - Docusign: `https://status.docusign.com/api/v2/summary.json`

  Also updated `PreferencesView.swift`'s "Periodically checks the
  public status pages of..." description text to include all four.

  **Three other obvious candidates checked and found not to be
  drop-ins — don't re-attempt these the same way:**
  - **Stripe** (`status.stripe.com`) doesn't serve
    `/api/v2/summary.json` at all (404) — different shape or path,
    not confirmed.
  - **Okta** (`status.okta.com`) returns an HTML redirect page at that
    path, not JSON.
  - **Salesforce** (`status.salesforce.com`) explicitly blocks it:
    `{"error":"Direct API access not allowed"}` — a locked-down custom
    Trust site, not Statuspage.
  - **Intercom**'s old `intercomstatus.com` domain 301s to
    `finstatus.com` entirely (a status-page-vendor migration) — the
    old API path is just gone; whatever the new one is wasn't checked.

- [x] ~~SNMP device web-detection prefers HTTP over HTTPS — a real
  security tradeoff, flagged directly, not yet reconsidered.~~
  **Fixed** by doing the "actually checking" option this item's own
  text called out, rather than a fixed protocol preference either way.
  `DeviceWebDetectionService.detectWebURL` now tries HTTPS *twice*: once
  with real, unmodified certificate validation (`strictSession` — no
  delegate override, so it accepts exactly what a real browser would
  accept without a warning) before HTTP, and once with the existing
  lenient trust-all session after HTTP, as a last resort ahead of the
  Aruba `4343` port. A device with a genuinely valid, modern cert now
  gets its encrypted link automatically; a device with a self-signed or
  outdated-TLS cert (confirmed live: this network's own printer) falls
  through to HTTP exactly as before, since `strictSession` correctly
  fails there the same way a real browser would. Verified against the
  real network end-to-end (not just built): relaunched the app and
  confirmed via `ui-state.log` that the printer and every other real
  device on this network still resolve to their working `http://` URL,
  with the strict-HTTPS path now genuinely exercised (and correctly
  failing) ahead of it rather than skipped. No user-facing preference
  added — this was the "just make the code correct" fix, not a decision
  that needed exposing as a setting.

  **Known, accepted verification gap, stated directly**: every device
  on this network lacks a browser-trusted certificate, confirmed live
  (all five — router, switch, both APs, printer — fell through to
  HTTP). That exercises and confirms the *failure* branch of
  `strictSession` correctly, but the "a device genuinely has a valid
  cert, so HTTPS wins automatically" branch this fix exists for has
  never actually succeeded against real hardware, on this network or
  any other checked so far. The logic is straightforward enough to
  trust by inspection (it's exactly what `URLSession` does by default
  with no delegate override, the same validation any ordinary networking
  client performs), but "trusted by inspection" and "confirmed working"
  are different claims — this is the former only, same honesty this
  file already applies to Printer Alerts' own never-triggered true
  positive.

- [x] ~~Rename "Expert Mode"'s internal Swift symbols to match its
  UI name.~~ **Done.** `NMSApp.comparisonWindowContent` →
  `expertModeWindowContent`; `ContentView.isInWindow` →
  `isExpertModeWindow`; the `Window(..., id: "nms-window")` scene
  identifier and every `openWindow`/`openWindowInFront` call site →
  `"expert-mode-window"`. Every affected doc comment across
  `NMSApp.swift`, `ContentView.swift`, `ContentView+Window.swift`, and
  `NoBounceScrollView.swift` updated to say "Expert Mode window" instead
  of "comparison window." Purely cosmetic — confirmed nothing
  user-facing changed by relaunching the real app and reading
  `ui-state.log`'s own `MenuBarLabel.autoOpenWindow` line, which
  resolved the renamed scene identifier correctly:
  `expert-mode-window → expert-mode-window`. Old occurrences left alone
  in `BUGS.md`/`DESIGN-NOTES.md` — those are historical narration
  (one directly quotes a real past log line), not current-state claims.

- [x] ~~Network Health's Router row: add a web link too.~~ **Built**,
  alongside ISP identification below: `ConnectionLayer` gained an
  optional `url`, set on the Local Router layer to `http://<routerAddress>`.
  Resolved the open question directly — always show the link once the
  address is known, no "detect a web server first" probe, letting a
  failed click-through be the browser's own fallback. That probe's
  self-signed-cert complexity stays scoped to the still-open SNMP
  Devices item below, not shared with this simpler case.

- [x] ~~ISP identification: worth an event message for the edge cases
  found while building it?~~ **Built** the one candidate that was worth
  it (below); the rest deliberately stayed silent. Raised directly after
  shipping RDAP-based ISP identification
  (`ISPIdentityService`/`ISPIdentityViewModel`). Looked at each
  candidate edge case; most don't actually have anything observable to
  log:
  - **A corporate network/proxy blocking the `rdap.org` lookup** — the
    failure is silently swallowed today (`identify(ip:)`'s `try?`), same
    "a parsing/fetch gap should be recoverable, not crash" posture
    `SaaSStatusService`'s own catch branch already has. An event here
    would mean logging *every* transient lookup failure, which this
    codebase deliberately doesn't do elsewhere either (SaaS's `.unknown`
    catch branch doesn't log an event; `WiFiSSIDViewModel` logs nothing
    when Location authorization is simply denied) — the honest answer
    is probably "no event," but flagged here rather than assumed.
  - **The Local Router/ISP status-page link failing to actually load**
    — genuinely unobservable: once `Link`/`NSWorkspace.open` hands off
    to the default browser, this app has no way to know whether that
    page loaded, 404'd, or the device wasn't there at all.
  - **The pre-existing ISP Edge Router hop-detection never confirming a
    hop on a complex multi-hop corporate WAN** — already has its own
    graceful `.unknown`/"Not confirmed" state (`connectionLayersLowToHigh`),
    not something new this feature introduced.
  The one candidate that actually was worth it: logging when the
  identified organization *changes* (mirroring `PublicIPViewModel`'s own
  `publicIPChanged` event) — a real, observable transition, unlike the
  cases above. **Built**: `AppEventKind.ispOrganizationChanged`
  (neutral polarity, no recovery pair, same shape as `publicIPChanged`)
  logged from `ISPIdentityViewModel.identify(ip:)` — guarded so neither
  the first-ever identification each session nor the one right after a
  network change (`reset()` clears the baseline) counts as a "change."
  Needed `ISPIdentityViewModel` to gain a `SnapshotStore` dependency it
  didn't have before (previously "identification for display only, no
  events to log" — now it logs exactly one).

- [x] ~~SNMP Devices: detect a web server on the device, add a link if
  found.~~ **Built** (`DeviceWebDetectionService`). Both open questions
  resolved directly: probes once at first discovery only (not every
  poll — a device's web UI toggling later within the same session won't
  be picked up until the address is forgotten by a full rescan), and
  "detected" means a real HTTP response on a candidate port, not a bare
  TCP connect. Tries HTTPS, then HTTP, then HTTPS on port `4343` — this
  network's own real Aruba APs use that non-standard admin port; see
  `DESIGN-NOTES.md`'s "SNMP device web-detection" entry for the finding
  and why it isn't generalized into a vendor-pattern registry yet. Same
  self-signed-cert handling this item had already resolved (a dedicated
  `URLSession` with a trust-all delegate, never `URLSession.shared`).
  Reuses `externalLinkIcon`, the same helper built for the Local
  Router/ISP links.

  Also fixed a related gap found while testing this: `SNMPViewModel`
  only ever discovered devices via the popover's manual "Scan" button —
  a first-time user enabling the feature saw an empty list forever
  unless they found and clicked it. `activate()` now sweeps
  automatically the one time there's nothing rehydrated from history,
  accepting the one-time launch-time-contention risk that comment
  already documented (see that function) rather than the ongoing "every
  launch" version of that risk. The button stays — nothing else
  triggers a fresh sweep, so it's still the only way to find a device
  added to the LAN after that first discovery.

- [x] ~~Network Health's "Network" row: Wi-Fi signal sparkline, or plain
  "Ethernet."~~ **Built.** The wiring gap this item flagged
  (`connectionHealthSection`'s sparkline slot was typed for
  `latencyHistory`, not RSSI) resolved with the small special case
  already anticipated: `layer.id == "network"` when `info.isWiFi` now
  reads `wifiSSID.recentSamples` instead, same values/reversal
  `wifiSection`'s own Signal row already uses. Final spec, requested
  directly: "Name" + "Ethernet" (`networkDisplay(_:)`, unchanged) or a
  sparkline + "Wi-Fi" — the network's name is dropped from this row on
  Wi-Fi specifically (the Info tile's own row still shows it), not
  appended alongside the sparkline as first drafted here.

- [x] ~~Add Wi-Fi signal strength to Network Health.~~ **Built**, via the
  "Network" row item above. Both open questions resolved in practice
  rather than by a separate up-front decision: the sparkline shows as a
  plain, uncolored data row (no new RSSI-degraded threshold introduced —
  the row's existing green/gray status still comes from whether a
  network name/label resolved, unchanged), and it *does* now appear on
  the popover, since Network Health is one of the two tiles that was
  never subject to the audience-split's window-only scoping to begin
  with — not a reopening of that decision, just this row using the
  exemption Network Health already had.

- [x] ~~Add Google Workspace and Google Cloud to SaaS monitoring.~~
  **Built.** Both added to `SaaSStatusService.monitoredServices` with a
  new `.googleIncidents` `Shape` (a rolling incident-history array, not
  a Statuspage-style current-status summary — see the parser's own doc
  comment for how "currently healthy" is derived from it, and the real
  judgment call in the severity mapping). Verified live end-to-end, not
  just via `curl`: enabled `FeatureSaaSMonitoring`, ran a real check,
  both reported `.none` / "All Systems Operational" with correct
  status-page URLs — including Google Workspace's, which needed a small
  explicit override (`MonitoredService.dashboardPath`) since its
  `incidents.json` lives under `www.google.com`, a host that isn't
  itself a status page the way every other entry's endpoint host is.

- [x] ~~README.md has fallen behind real, shipped behavior — needs a
  refresh pass.~~ **Done.** All items found in the original audit fixed:
  the popover's actual current shape (Network Health + Info + footer
  only — the "2×2 grid"/"Events, full width" description was stale on
  two independent counts, predating this session in one case), the
  Network row's new Wi-Fi sparkline, the Path to Internet tile's new
  "NAT" row, a full SaaS Status writeup (new section, new TOC entry, new
  Experimental Features entry for `FeatureSaaSMonitoring` — including
  the `FeatureSaaSEnabledServices` new-service gotcha found live this
  session), Info's per-network-scoping list, Events' multi-line
  wrapping and link icon, and the stale NMSUITests appearance-toggle
  paragraph. Test counts corrected (105 unit, 3 UI). Also gave Wi-Fi and
  Printer Alerts their own `###` subsections to match DHCP
  History/SNMP Devices/SaaS Status, and found (via a script checking
  every `NMS/**/*.swift` filename against the README) that Project
  Layout was missing seven real files entirely —
  `BugReportExportService`, `BlockingWork`, `DebugArtifactRetention`,
  `DeviceWebDetectionService`, `ISPIdentityService`/`ISPIdentityViewModel`,
  `SaaSMonitoringViewModel`, and `SaaSStatusService` itself — all added.

- [x] ~~Let users add their own website(s) to monitor, via
  Preferences.~~ **Built.** The three open questions this item raised
  all got resolved during implementation, not left open:
  - New `Shape.reachabilityOnly` case — reuses `checkStatus`'s existing
    fetch entirely (no new HTTP code), just handled before the shared
    `== 200` guard since it accepts any 2xx and needs no body parsing:
    `.none`/"Reachable" on success, `.unknown` on anything else (via
    the caller's existing catch branch, unchanged).
  - Storage: `FeatureFlags.UserAddedSaaSSite` (`Codable`, `url` +
    `nickname`), JSON-encoded into `UserDefaults` `Data` under
    `FeatureUserAddedSaaSSites` — the `[String: String]`-or-`Codable`-array
    question resolved as the latter.
  - **Visually distinct, not folded into the curated list** — a new
    `SaaSMonitoringViewModel.userAddedStatuses`, checked by its own
    `checkUserAddedSites()` on the same timer cadence but *never*
    logging Events transitions the way `apply()` does for the curated
    list. That's not an oversight, it's the point: per DESIGN-NOTES.md's
    "Does this vary by network?", a plain reachability check is
    genuinely network-dependent (a restrictive network can fail it with
    nothing wrong at the site), so logging a down/recovered pair here
    could misreport "blocked on this network" as "this site went down
    and came back" once roaming elsewhere. Rendered in the live UI as a
    separate "Your Own Sites" group below the curated rows, same
    reasoning.
  - Preferences UI: a real add ( nickname + URL, `http`/`https`-validated
    before the button enables) / remove list, separate from the curated
    checkboxes above it.

  **Honest gap: the add/remove UI itself wasn't click-verified live** —
  `System Events`' `entire contents` walk was unreliable this session
  (see `CLAUDE.md`) and repeated retries didn't resolve it. Build is
  clean, the full test suite passes, and the actual check *logic*
  (`FeatureFlags` storage round-trip, `SaaSStatusService.checkStatus`'s
  `.reachabilityOnly` path, `SaaSMonitoringViewModel
  .checkUserAddedSites`) was traced by hand rather than guessed at, but
  a real click-through of the Preferences form itself is still worth
  doing manually before fully trusting it.

- [x] ~~Path to Internet's Provider Edge History may not be worth
  showing on a single-homed network.~~ **Removed the display.** The
  caveat that kept this open (removing it "reopens" the Path to
  Internet/Speed Test tile-height mismatch) stopped being true once both
  tiles moved to one shared `ContentView.tileHeight` — matching height no
  longer depends on either tile's actual content. With that gone, the
  real data made the call easy: on this single-homed network, the address
  changed twice in 3 real `ProviderEdgeRecord` rows over ~35 hours, and
  one of those two "changes" was a flap-and-revert 3 seconds apart —
  thin, noisy signal, not a diagnostic worth a permanent list. The
  underlying mechanism stays (`SnapshotStore.recordProviderEdgeIfChanged`,
  `ProviderEdgeRecord`): `TracerouteViewModel.monitoredHopAddress` still
  depends on `latestProviderEdge()` to survive an outage without
  dropping to "Not checked," and hostname enrichment still patches the
  latest row. Only the UI (`ContentView+Window.swift`'s edge-history rows
  and divider) and the display-only plumbing that fed it
  (`TracerouteViewModel.edgeHistory`, `reloadEdgeHistory()`,
  `SnapshotStore.fetchProviderEdgeHistory`) are gone.

- [x] ~~Confirm Printer Alerts' new fixed-height box actually fits 2
  printers live.~~ **Moot — the Printer Alerts tile was removed
  entirely.** See "Decide whether to keep the printer alerts feature."
  This box-fit question no longer applies to anything that exists.

- [x] ~~`BuildInfoService`'s hardcoded repo path breaks when more than
  one checkout exists on a machine.~~ **Done — took the third option
  (`4104b24`).** The item below already framed the choice: keep the
  hardcoded path, derive it from the running binary, or "dropping the
  design's original assumption and adding the build-time Run Script
  stamp the doc comment already considered and passed on." The stamp
  won, after the same class of bug recurred in a much more expensive
  form.

  What forced it: a binary built 2026-07-29 12:26 ran for two days
  reporting `dead27c+dirty`, a commit made well after it, across
  several bug reports. Same silent-staleness mechanism as the
  two-checkouts case originally recorded here, but this time it also
  hid a High-severity data bug — that stale binary predated `e2f9ba2`'s
  schema change, so it was the only reason the store still opened, and
  the misreported hash is what made the resulting failure look
  impossible for as long as it did. See `BUGS.md`, "The persistent
  store fails to open."

  A "Stamp build info" run-script phase now writes the hash, subject
  and dirty flag into the built `Info.plist`, and `BuildInfoService`
  reads those instead of running `git` at launch. A stamp can't drift:
  it's written by the build that produced the binary, or it's absent
  (and absent stays graceful — `nil`, shown as "unknown"). Verified by
  committing without rebuilding: the unrebuilt binary kept reporting
  its own older hash instead of the new `HEAD`, which is exactly what
  the old code got wrong. Also fixes the original two-checkouts case
  for free — the stamp depends on no path at all — and drops a process
  spawn at launch.

  **One tradeoff worth knowing**: this needs
  `ENABLE_USER_SCRIPT_SANDBOXING = NO`, scoped to the NMS app target
  only (project default and both test targets stay `YES`). Confirmed
  necessary rather than assumed, by reading the generated `.sb`
  profile: it denies `file-read*` across all of `SRCROOT` including
  `.git`, granting only individually declared input files — and
  `git status --porcelain` can't work that way, since it stats the
  entire worktree.

- [x] ~~Remove SNMP Devices from the popover; keep it window-only.~~
  **Done.** `ContentView`'s SNMP Devices block now reads
  `if FeatureFlags.snmpDevices && isInWindow`, same pattern as Wi-Fi/
  DHCP History/Printer Alerts. README's popover and "Open in Window"
  sections updated to match (also caught DHCP History and Printer
  Alerts already being window-only but not yet reflected in the
  "Open in Window" section's own text, and the popover's content list
  still listing DHCP History as if it were still there — both fixed in
  the same pass, plus the Bug Report button, missing from the footer
  description). Build clean, 64/64 tests, relaunched without issue.

- [x] ~~"Open in Window" shouldn't appear once you're already in the
  window.~~ **Done.** Gate is now
  `if FeatureFlags.comparisonWindow && !isInWindow`, the inverse of the
  `isInWindow && ...` pattern every window-only section already uses.
  Build clean, 64/64 tests, relaunched without issue. Not yet confirmed
  by eye that the button actually disappears from the window's own
  footer — no Accessibility permission to click through it from here.

- [x] ~~Add a length cap to untrusted network-derived text before it's
  persisted.~~ **Built** (`UntrustedText.swift`). Found during a
  security review requested ahead of letting friends try the app. SNMP
  `sysDescr`/`sysName` (`SNMPService.probe`) and DHCP option strings
  (`DHCPLeaseService.parse`) are genuinely untrusted — they come from
  whatever a device on the LAN chooses to send back — and neither had a
  length limit before being stored in SwiftData and rendered in a
  `Text` view. Not exploitable (every string only ever reaches plain
  `Text(String)`, never `Text(markdown:)` or `AttributedString(markdown:)`,
  so there's no rendering-injection path regardless of size), but a
  misbehaving or malicious device could still bloat the store or slow a
  render with an oversized response. Fixed with a shared 4096-character
  cap applied at the parsing boundary in both services — SNMP caps
  `sysDescr`/`sysName` individually; DHCP caps every option value
  uniformly as it's parsed, covering `domain_name` (the one currently
  read downstream) and any option added later, not just today's known
  case. The rest of the review came back clean: every subprocess call
  uses `Process`'s array-form arguments (no shell, no injection
  surface), no `String(format:)` call anywhere uses untrusted content
  as the format string itself, and the ARP-parsing regex is simple and
  anchored (no ReDoS risk).

- [x] ~~Split by audience: popover for business users (summary only),
  the real window for IT users (everything).~~ **Done (`4104b24`+).**
  Resolved the open questions below with a direct answer: "summary"
  means Network Health plus Info — status plus which network you're on,
  nothing else. Path to Internet, Speed Test, and Events all moved to
  window-only (`SectionLayout.surfaces`), joining Wi-Fi/SNMP Devices/
  DHCP History/Printer Alerts, which were already there. The popover's
  scroll-box budget (`SectionLayout.popoverBoxTotal`) is now pinned to
  exactly `0` by a test — any box-bearing section landing back on the
  popover fails the build.

  "Open in Window" stays the only full-detail surface — no
  expand/collapse path was added to the popover itself, since the whole
  point was moving detail *out*, not adding a second way to reach it
  from the same place. Confirmed live via accessibility-driven AppleScript
  (a fresh capability this session — see below): the split renders
  correctly and 560pt still looks right for two tiles, no dead space on
  the right edge.

  That same check surfaced a real, immediate follow-up, in two rounds.
  **Round 1**: Network Health (7 rows) and Info (5-6 rows) no longer
  shared a column with a second tile absorbing the height difference, so
  their borders visibly mismatched. A same-day Bug Report caught it
  within minutes ("can we align the two tiles?"). First fix used a
  `GeometryReader`/`PreferenceKey`/`@State` round-trip and looked correct
  when checked via a live `screencapture` of the real popover — but a
  *second* same-day Bug Report on the same two tiles ("bottom edge of
  tiles not aligned") turned out to be right: `ScreenshotService.capture`
  renders via `ImageRenderer` once, synchronously, with no run-loop turn
  for that state round-trip to land before the image is captured, so
  every actual Bug Report/Screenshot still showed the unsynced heights.
  Confirmed by measuring the captured PNG's border pixels directly, not
  by eye — the same class of `ImageRenderer` quirk already documented
  three times on `ScreenshotService`, now a fourth.

  **Round 2**: replaced the state-based sync with a `Grid`/`GridRow`
  for just Network Health and Info — `Grid` synchronizes cell heights in
  one deterministic layout pass, no state round-trip, no window for a
  single-shot renderer to miss. Measuring again showed the *same* gap
  persisting, which turned up a second, real SwiftUI subtlety: `Grid`
  synchronizes each cell's layout *slot* to the row's tallest cell, but a
  shorter cell's own drawn background/border doesn't stretch to fill that
  slot unless the cell explicitly opts in with `maxHeight: .infinity`.
  Added a `fillHeight` parameter to `ContentView.tile(title:content:)`,
  applied only to the Network Health/Info `GridRow` — Path to Internet
  and Speed Test keep the plain, unstretched `tile()` in their own
  `HStack`, so their independent sizing (Speed Test's history can grow
  arbitrarily tall; forcing that onto Path to Internet was rejected once
  already, see `scrollableContent`'s "Independent columns" comment) is
  unaffected.

  Verified via the real popover's own Screenshot button (accessibility-
  clicked, not just built) and a tight crop of the resulting PNG. One
  more lesson from this round: the pixel-measurement script written to
  check it had its own bug (picking up the footer's button borders below
  the tiles, the same false-positive class the orange Bug Report banner
  caused earlier) — direct visual comparison of the crop, cross-checked
  against the user's own live view, is what actually confirmed the fix,
  not the automated heuristic.

  **Round 3, a different pair**: a *third* same-day Bug Report ("can you
  align the bottom edges of path to internet and speed test?") named the
  window's other tile-grid row. First attempt: a `SectionLayout
  .forcesWindowBox` flag letting Path to Internet size to content below
  3 rows instead of always boxing at 150pt, on the theory that an empty
  box (2 confirmed hops in a box sized for the worst case) was the whole
  problem. Live verification (a real screencapture of the frontmost
  window, not a build check) showed it wasn't: Speed Test's real history
  already had 5 entries, past its own threshold, so it kept boxing at
  140pt regardless of the flag — the mismatch persisted, just for a
  different reason. That reason turned out to be structural, not a
  layout bug at all: **a network path is almost always short (1-4 hops,
  usually confirmed down to 1-2), while Speed Test's history only
  grows** — no box-forcing rule reconciles a tile whose content is
  inherently sparse with one that's inherently an accumulating log.

  Raised directly and answered directly: rather than keep chasing that
  asymmetry with layout rules, give Path to Internet the same kind of
  content Speed Test already has. `SnapshotStore.fetchProviderEdgeHistory`
  / `ProviderEdgeRecord` already existed for exactly this — a real
  change-log of the ISP edge address, built earlier and never wired into
  any UI — so this was surfacing existing data, not building a feature
  from scratch. Added `TracerouteViewModel.edgeHistory`, network-scoped
  the same way DHCP/Events are (`ProviderEdgeRecord.networkFingerprint`,
  optional — a mandatory version would have hit the exact migration
  failure `BUGS.md`'s store bug describes), wired
  `NetworkIdentityViewModel.onNetworkRecognized` to reload it (same gap
  as today's earlier Events/DHCP fix), and appended it below the current
  hop list inside Path to Internet's existing box — one shared
  scrollable area, mirroring how Speed Test's history *is* its content
  rather than an addition below a separate "current state" display.
  `forcesWindowBox` was reverted (the window boxes unconditionally again,
  for every section) and Path to Internet's declared window height was
  set equal to Speed Test's (140, not derived from either tile's actual
  content — "reasonable sizes, the window scrolls past whatever doesn't
  fit" was the explicit call, since squeezing every tile to fit exactly
  stopped being the point once nothing has to fit inside a popover
  anymore). Verified against the real store (3 existing
  `ProviderEdgeRecord` rows migrated and adopted cleanly, no fallback)
  and live via a screencapture of the actual frontmost window: both
  tiles' bottom borders and the divider below them now land on the same
  row.

- [x] ~~Add a debug key to auto-open the real window at launch, for
  headless/scripted verification.~~ **Done.** Built as unconditional-in-
  DEBUG rather than its own `defaults` key — see `MenuBarLabel` in
  `NMSApp.swift` for the reasoning (why it has to live on the
  `MenuBarExtra` label, not `init()`/`AppDelegate`/`ContentView`).
  Verified end-to-end: built, launched, confirmed
  `MenuBarLabel.autoOpenWindow` in `ui-state.log`, and screenshotted the
  real window's actual content (Network Health, Info, a live
  traceroute, Wi-Fi telemetry) with no Accessibility permission
  involved at all.

- [x] ~~Test per-network scoping and Network Review on a second network.~~
  **Done**, on a real live switch (this Mac's own Home ↔ guest-Wi-Fi
  VLANs, same router). All confirmed clean via direct `sqlite3` queries
  against the real store, not just the UI: the guest network recognized
  as distinct (its own Known Networks row, `timesSeen` incrementing on
  return visits); Events (550 vs. 47), DHCP History (301 vs. 6), and
  Wi-Fi samples (12 vs. 29) cleanly separated with zero cross-network
  leakage; Home's row, label, and full history stayed intact and
  reachable through the Review sheet while connected to the guest
  network (screenshotted directly — header, label, seen count, and
  populated Events section all correct); the crash-shape duplicate-row
  query stayed empty throughout. This also closes out the Network
  Review UI itself, which had only ever been build-verified before
  this — now actually seen rendered, live, for both networks.

  **One real gap found, since fixed — see DESIGN-NOTES.md's "A router
  serving two VLANs is a genuine edge case per-network scoping doesn't
  fully cover."** The router's guest-side address was getting a
  persisted SNMP row under *both* networks' fingerprints, kept alive
  indefinitely by `syncAliasFreshness` — invisible in the live UI (the
  shared-MAC alias merge papered over it), but a real persisted-data
  leak. Root cause traced to `SNMPViewModel.candidateAddresses()`
  scanning beyond the current subnet (raw ARP cache, plus "local"
  traceroute hops added for ISP edge router discovery); fixed by
  restricting it to strictly the current subnet plus its gateway. SNMP
  no longer auto-discovers an off-subnet ISP edge router as a result —
  an accepted tradeoff for scanning never reaching outside the current
  network.

- [x] ~~"Generate Report" button on Network Review.~~ **Built and
  verified live.** Reuses `ScreenshotService`'s `ImageRenderer` against
  the Review sheet itself — same `isCapturingScreenshot`/
  `capturingScreenshotCopy` shape as `ContentView`'s own screenshot
  path, needed because `ScrollView` content otherwise renders as
  completely absent off-screen (see `ScreenshotService`'s own doc
  comment). Also fixed the DHCP row's `appKitToolTip(..., enabled: true)`
  that this same file's own comment had flagged as a landmine for
  whoever built this — an `NSViewRepresentable` `ImageRenderer`
  substitutes a yellow "prohibited" glyph for, now `enabled:
  !isCapturingScreenshot` like every other tooltip in the app.
  `ScreenshotService.capture` gained an optional `filenamePrefix` (default
  `"NMS"`, unchanged for every existing caller) so a report is
  distinguishable by filename alone — `NMS-Review-<network>-<date>.png`.
  Confirmed end-to-end against the real running app: a real "Home"
  report saved as a complete, correctly-rendered 1677×15374px PNG (full
  Events/SNMP/DHCP/Wi-Fi history, no blank sections, no tooltip glyph),
  revealed in Finder on completion.

- [x] ~~DHCP tile → Events as a multi-line message.~~ **Resolved: keep
  them separate, deliberately not merged.** The blocking *technical*
  tension was already gone: Events moved window-only in the audience
  split, so it no longer shares the popover's precise 17pt/row height
  calibration this was originally worried about breaking — the window's
  Events box is just a generous, independently-scrolling 350pt area
  regardless of how many lines any one entry takes, and `eventRows` no
  longer truncates to one line as a result. What remained was the
  original *idea* — folding DHCP History's own detail into a multi-line
  Events entry instead of keeping it a separate section — and on
  reflection that's the wrong direction, for three reasons:
  1. **Different audiences at different granularity.** `dhcpHistoryList`
     shows every field of every real lease change (server, address,
     broadcast, gateway, DNS, domain, lease/T1/T2 timing, transaction
     ID — "the densest jargon in the app," per its own tooltip).
     Events already logs a one-line summary of the same transition
     (`dhcpLeaseChanged`). Merging means either bloating every Events
     row to DHCP's full technical density, or discarding that detail to
     fit Events' shape — a real loss of diagnostic value either way.
  2. **Events is a shared, cross-subsystem list with one row shape.**
     Interface changes, SNMP restarts, connectivity outages, SaaS
     status, and DHCP changes all render through the same
     colored-dot-plus-label-plus-detail row. Making just DHCP's entries
     uniquely two-line-dense would make that one list inconsistent, not
     simpler.
  3. **This already matches the app's own established pattern.** The
     popover/window audience split works exactly this way — headline in
     one place, full detail one level down (see this file's "Split by
     audience" entry). Events is the headline ("something changed");
     DHCP History is already the "one level down" detail view. Merging
     them would collapse a distinction the rest of the app deliberately
     keeps, not simplify anything.

- [x] ~~Ethernet link speed telemetry.~~ **Built.** Discussed alongside
  the Wi-Fi telemetry work; scoped and shipped end-to-end this session.
  `EthernetLinkService` shells `networksetup -getMedia <device>` — same
  free-ride pattern as `ping`/`arp`/`traceroute`/`ipconfig`/`snmpget`,
  no IOKit needed — verified against this Mac's own real Gigabit
  connection before writing the parser (`1000baseT <full-duplex
  flow-control>`). `EthernetLinkViewModel` mirrors
  `WiFiSSIDViewModel.refresh(isWiFi:)`'s shape but simpler: no persisted
  history, no events, no periodic timer — link speed only changes on a
  physical event (cable swap, different switch port), which is exactly
  when `NMSApp`'s existing topology-change wiring already calls
  `refresh` again, so a timer polling a static value would add nothing.
  New `SectionLayout.ethernetLink` case (window-only, 60pt — just Speed
  and Duplex, no signal to chart, no BSSID/channel/security the way
  Wi-Fi's box has), gated the same way as the Wi-Fi section it sits
  alongside and is mutually exclusive with. No sparkline — a link speed
  is a step function that only ever answers "still negotiated the same
  it always does" or "cable's unplugged," not a continuously-varying
  trend RSSI's own sparkline actually earns. Verified live end-to-end:
  relaunched the real app, confirmed `ui-state.log`'s
  `EthernetLinkViewModel.currentSpeedMbps | 1000.0` against this Mac's
  actual Ethernet connection.

- [x] ~~Decide whether to keep the printer alerts feature.~~ **Reversed:
  removed.** Originally decided "keep" on cost grounds (marginal
  `lpstat -l -p` overhead, no popover space, forward-compatible for
  free) without weighing whether it ever shows real content. Revisited
  directly ("does the tile add anything? is SNMP sufficient?") against
  what `DESIGN-NOTES.md`'s "Printer fault detection... a real dead end"
  entry had already established: both CUPS (`lpstat -l -p`) and the
  standard SNMP Printer MIB (`prtAlertTable`/`prtCoverStatus`) were
  tested against a real fault (a physically open drawer) and both came
  back empty or meaningless, on this hardware. A tile that can only
  ever say "OK" is worse than no tile — it implies fault-monitoring
  that isn't real. Removed entirely: `PrinterDiscoveryService
  .printerAlerts()`/`parseAlerts()`/`humanReadable(reasons:)`,
  `ConnectivityViewModel.refreshPrinterAlerts()`/`applyPrinterAlerts()`/
  `printerStatuses`, the `.printerAlert`/`.printerAlertCleared`
  `AppEventKind` cases, and the window-only tile — reachability
  monitoring (`configuredNetworkPrinters()`,
  `infrastructureUnreachable`/`Reachable` events) is completely
  untouched, since that was never in question. A note for the future is
  left directly in `DESIGN-NOTES.md`'s dead-end entry: a different
  printer's firmware might expose real fault detail through either
  path, so this isn't a permanent "never build this" — just a "not on
  this hardware, verify concretely before trying again."

- [x] ~~Code review the Screenshot and Bug Report code.~~ **Done
  (`d505b6f`, `6cd9caa`).** Found exactly the recurring bug class this
  was raised to check for: `communityRow`'s `TextField` had no
  `isCapturingScreenshot` guard at all, unlike `bugReportRow`'s identical
  field — never reported since it only triggers if a community-string
  edit happens to be in progress at the exact moment a capture fires.
  Fixed, then hardened structurally: extracted a shared
  `ContentView.captureSafeTextField` (mirroring how `scrollBox`/
  `tile(fixedHeight:)` already centralize the equivalent
  `NoBounceScrollView` guard) so both call sites — and any future one —
  go through one path instead of hand-rolling the branch. Added a
  "Capture-mode guard audit" test that scans the source for raw
  `TextField`/`NoBounceScrollView` constructions and pins the count, so
  a future bypass fails the build. Also added retention for the
  screenshots/state-dumps directories (30 days, neither had any before)
  and a privacy notice in every state dump, both raised as follow-on
  ideas during the same pass.

- [x] ~~Monitor a user-configured DDNS hostname for staleness — does it
  actually still point at the current public IP?~~ **Shipped**:
  `DDNSResolutionService` (`dig @1.1.1.1`, not `getaddrinfo` — see that
  type's own doc comment for why the anti-caching trick below couldn't
  apply here), `DDNSViewModel` (per-hostname `syncState`: `.current`/
  `.stale`/`.blockedByCGNAT`, the last one reusing
  `TracerouteViewModel.includesConfirmedCGNAT` rather than adding new
  detection, and preempting the plain comparison rather than
  supplementing it — see `syncState`'s own doc comment), one or more
  hostnames configured via a new Preferences section
  (`FeatureFlags.DDNSHostname`, same shape `UserAddedSaaSSite` already
  established) with a 1-minute/5-minute check-interval picker, three
  new `AppEventKind` cases (`ddnsRecordStale`/`ddnsRecordCurrent`/
  `ddnsBlockedByCGNAT`), a window-only summary row in the Info tile
  (colored dot + hostname/count + interval, a manual "check now" button,
  full per-hostname detail in the tooltip), and `FailureInjector
  .applyDDNSChanges`/`isDDNSForced` for scripted testing of the
  transition logic. Verified against a real, live stale DDNS record —
  a genuine full round trip (real stale → fault-injected stale → real
  recovery), not just unit tests.

