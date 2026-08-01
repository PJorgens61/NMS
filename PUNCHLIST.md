# Punchlist

Open items, tracked here so they survive between sessions. Not a spec —
see `DESIGN-NOTES.md` for the reasoning behind anything non-obvious.
Actual defects live in `BUGS.md` instead — this file is ideas, testing
tasks, and decisions. Check items off or delete them as they land; add
new ones as they come up.

## Open

- [ ] **Network Health's Router row: add a web link too.** Requested
  directly, same idea as the SNMP Devices entry below but simpler in
  one real way: the router's IP is already known with certainty here
  (`connectivity.checks.first { $0.label == OverallStatus.routerLabel
  }`'s `target`, or `info.routerAddress` — same value `routerDisplay(_:)`
  already shows in the Info tile), not something that needs discovering
  the way an arbitrary SNMP device's presence does. Real open question
  this raises that the SNMP Devices entry didn't have to: does *this*
  row still run the same "detect a web server first" probe before
  showing a link, or is a home router's admin UI close enough to
  universal that it's worth just always showing the link and letting a
  failed click-through (browser's own "can't connect") be the fallback,
  skipping the probe entirely for this one case? If it does keep the
  probe, this and the SNMP Devices item should share one detection
  service rather than two copies of the same self-signed-cert-handling
  logic.

- [ ] **SNMP Devices: detect a web server on the device, add a link if
  found.** Requested directly. Real for a lot of what's already
  discovered here — this network's own router, switch, and both APs
  (see the SNMP Devices screenshots throughout `BUGS.md`) all plausibly
  have an admin web UI. Rendering: an inline link on
  `infrastructureRows`' first `HStack` line (`ContentView+Window.swift`
  ~494), alongside `device.displayName`/`uptimeDescription` — the
  natural spot, no new row needed.

  Detection isn't a drop-in reuse of `HTTPCheckService` — that checks
  one known endpoint for one expected body; this needs "does *anything*
  answer on 80/443 for this arbitrary IP," a different, more open-ended
  shape.

  **HTTPS/self-signed-cert question, resolved directly**: accept
  invalid certs for the detection probe, matching what the user already
  does by hand in a browser for exactly this kind of device. Scoped
  narrowly, though — a custom `URLSessionDelegate` (`urlSession(_:
  didReceive:completionHandler:)`, trusting unconditionally) used *only*
  for this one probe, not applied to `URLSession.shared` or anything
  else in the app, so nothing else here silently loses real cert
  validation. Defensible specifically because these are LAN devices
  SNMP already confirmed answer to the configured community string —
  not an arbitrary internet host. The link itself still just opens in
  the default browser (`NSWorkspace.open`), not rendered in-app, so the
  user's own normal click-through still happens there too — NMS's
  relaxed trust only ever covers the lightweight background "does
  something answer here" check, never the actual page content.

  Remaining open questions:
  - **When does this run?** At first discovery only (cheap, one-time,
    but stale if a web UI gets enabled/disabled later), or on every
    SNMP scan (fresher, but a new per-device network round trip added
    to every scan cycle, on top of the existing `snmpget` sweep).
  - **Cheapest real signal**: a bare TCP connect to 80/443 (proves a
    server process is listening, not that it's genuinely HTTP) versus
    a real HTTP `HEAD`/`GET` (confirms the protocol, costs more time
    and has the cert question above). Worth deciding which "detected"
    actually means before building either.

- [ ] **SaaS fault injection: already built, but three real gaps found
  while checking.** Asked "how to test SaaS services that rarely fail,
  can we inject faults" — turns out `FailureInjector.applySaaSChanges`
  already does exactly this (`defaults write
  ~/Library/Preferences/Thistle.NMS.plist NMSInjectSaaSOutage -array
  Slack`, DEBUG-only, `[injected]`-tagged, real fetch still runs
  underneath). Confirmed working, not new. What's actually missing:
  1. **Not in README's "Experimental features" list.** That section's
     "Failure injection" bullet names connectivity/interface-down/DHCP/
     SNMP explicitly but not SaaS — someone reading just the README
     wouldn't know this exists. Add a line.
  2. **`script/scenarios.sh` doesn't cover it either** — that script's
     own description says "connectivity, DHCP, and SNMP," 11 checks;
     SaaS outage injection has no automated scenario test at all today.
  3. **Only simulates `.major`** — `applySaaSChanges` hardcodes
     `.major` for every forced service (confirmed reading the code);
     there's no way to inject `.minor` or `.critical` specifically, so
     the UI's handling of the full indicator range (if it differs at
     all beyond color) can't actually be tested or demoed today, only
     the "is something wrong at all" case.

- [ ] **Network Health's "Network" row: Wi-Fi signal sparkline, or plain
  "Ethernet."** Requested directly — narrower and more concrete than
  the general "Add Wi-Fi signal strength to Network Health" item below,
  which this mostly answers: attach the sparkline to the existing
  combined Network row (`ContentView.swift`'s `networkLayer`,
  built from `networkDisplay(_:)` — already correctly shows plain
  `"Ethernet"` with no name when not on Wi-Fi, confirmed reading the
  code) rather than adding a new row or a new health-status color.
  Real wiring gap: `connectionHealthSection`'s sparkline slot
  (`latencyHistory[layer.id]`) is typed for `LatencySample.latencyMs`
  from `ConnectivityViewModel.latencyHistory()` — RSSI comes from a
  different source entirely (`WiFiSSIDViewModel.recentSamples`,
  already used by the existing Wi-Fi section's own Signal row). Needs
  either a small special case for `layer.id == "network"` when
  `info.isWiFi` (use `wifiSSID.recentSamples` instead of
  `latencyHistory` for that one row) or a slightly more general
  sparkline-source parameter — not a drop-in reuse of the existing
  slot as-is.

- [ ] **Shrink SNMP Devices and Printer Alerts' box heights.**
  `SectionLayout.boxHeight(on:)`:
  - **SNMP Devices**: `200` → `150` (requested directly, down 25%).
    That 200 is explicitly taller than its neighbors "because
    `sysDescr` wraps instead of truncating and needs the extra room"
    (that type's own comment) — worth a live check that a real wrapped
    `sysDescr` (the switch's is the longest seen so far, two lines)
    still reads fully at 150 before landing on it, not just trusting
    the arithmetic.
  - **Printer Alerts**: `rowHeight * 3` (51) → **30, exact value given
    directly**, superseding an earlier "down 50%" ask. `rowHeight` is
    17, so 30 is 1.76 rows — below even the *exact* 2-row boundary
    (34), not just below the row-of-headroom-past-it that 51 was tuned
    to. That headroom came from a real same-day Bug Report ("Confirm
    Printer Alerts' new fixed-height box actually fits 2 printers
    live," below); 30 sits inside the boundary that report flagged as
    too tight in the first place, so a real second printer showing 2
    alerts at once would need to scroll to see both — likely fine
    given today's 1-printer network can't actually show that case
    either way, but worth going in with eyes open rather than
    rediscovering the same report's finding.

- [ ] **Blocked on the user: GCP OAuth client setup for "Sign in with
  Google" (Personalized Service Health).** Everything else for this
  feature (code, API research — see `DESIGN-NOTES.md`'s "Google Cloud,
  interactive Sign in with Google variant") is ready to build; this is
  the one piece only the account owner can do. Exact steps:
  1. Pick or create a GCP project:
     `gcloud projects create nms-service-health --name="NMS Service Health"`
     (an existing project works fine too).
  2. Enable the API: `gcloud services enable servicehealth.googleapis.com
     --project=YOUR_PROJECT_ID`
  3. Grant yourself the viewer role on whichever project(s) NMS should
     monitor: `gcloud projects add-iam-policy-binding YOUR_PROJECT_ID
     --member="user:your-email@example.com" --role="roles/servicehealth.viewer"`
  4. Console → APIs & Services → OAuth consent screen: User type
     **External** (or Internal if this project is under a Workspace
     org); add scope `https://www.googleapis.com/auth/servicehealth.readonly`;
     add your own email as a test user; leave publishing status as
     **Testing** for now.
  5. Console → APIs & Services → Credentials → Create Credentials →
     OAuth client ID → Application type **Desktop app** → copy the
     **Client ID** (`...apps.googleusercontent.com`) — safe to hand to
     Claude/embed in the app; PKCE secures the flow, not secrecy of
     this value.
  - **Real caveat, checked directly**: while the consent screen stays
    in **Testing**, Google expires refresh tokens after exactly 7 days
    regardless of activity — a weekly forced re-sign-in. Moving
    publishing status to **Production** avoids that (indefinite
    refresh tokens); for a single personal-use client this is usually
    just a checkbox, not a full verification review, but which bucket
    `servicehealth.readonly` falls into (verification-required or not)
    hasn't been confirmed. Try Production first; Testing + weekly
    re-consent is a real, non-fatal fallback if it demands review.

- [ ] **Add Wi-Fi signal strength to Network Health.** Requested
  directly. Signal (RSSI/SNR, with a sparkline) already exists today —
  `ContentView+Window.wifiSection`, window-only — this is about
  surfacing it in **Network Health** too, which is one of the two tiles
  that renders unconditionally on both the popover and the window
  (`SectionLayout`'s doc comment: nothing about Network Health/Info is
  surface-conditional). Two real open questions, not just a
  copy-the-row job:
  - Network Health's existing rows are all colored-dot
    `ConnectionLayer`s with a health status (green/yellow/red) driven
    by latency thresholds — does Wi-Fi signal get the same treatment
    (needs a real "what RSSI counts as degraded" threshold decision,
    unlike anything else in that list) or does it show as a plain data
    row with no color, which would look inconsistent next to every
    other row in that tile?
  - This directly reopens the audience-split reasoning `SectionLayout`
    already settled for the Wi-Fi section specifically ("everything
    diagnostic... lives only in the window" — see that section's own
    doc comment): is signal strength "can I work" material that
    belongs on the popover, or diagnostic detail that was deliberately
    scoped out of it? Worth a real answer, not an accidental
    reopening of a decision that was made on purpose.

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

- [ ] **Add AWS to SaaS monitoring — needs a scoping decision first.**
  `https://status.aws.amazon.com/rss/<service>-<region>.rss` (RSS,
  re-confirmed live, `ec2-us-east-1` tested) is real but per-service-
  per-region, not one aggregate feed the way Google Cloud/Workspace are
  — there's no single "AWS" entry to add without first deciding which
  service/region slugs actually matter (e.g. just this house's actual
  AWS usage, or a fixed starter set like EC2 us-east-1). Also a new
  `Shape` case needed (RSS/XML parsing, unlike every existing entry).

- [ ] **Microsoft 365 needs a decision before it can be added at all.**
  No public, unauthenticated endpoint exists — `DESIGN-NOTES.md` already
  confirmed `401` on the real API (Microsoft Graph Service
  Communications) without an OAuth app registration. Options, same
  three as Workday/ADP's existing gap: skip it, fall back to a plain
  reachability check against a Microsoft 365 domain (weaker signal,
  same shape as the Workday/ADP fallback already designed), or treat it
  as the first candidate for the separate tenant-auth project in
  `DESIGN-NOTES.md`. No pull toward one yet.

- [ ] **Let users add their own website(s) to monitor, via Preferences.**
  Explicitly requested — reverses a scope cut made earlier this session
  (a prior punchlist entry, since removed as redundant, deliberately
  ruled this out as "materially bigger, separate feature"). Different
  problem from the curated table above: a random user-supplied URL
  can't be assumed to be Statuspage-shaped JSON the way every curated
  entry is, so this needs the **reachability-only** fallback
  `DESIGN-NOTES.md` already designed for Workday/ADP/M365 but never
  actually built — a plain `HTTPCheckService`-style up/down check
  against a URL, not real status-page parsing. This would be the first
  real implementation of that shape.
  Shape of the work:
  - A new `SaaSStatusService.MonitoredService.Shape` case (e.g.
    `.reachabilityOnly`) whose "parser" is just "did the request
    succeed" — `.none` on 2xx, `.unknown` (not `.major`/`.critical`;
    a failed fetch to a URL with no real status API doesn't carry
    Statuspage's severity grading) otherwise, matching how the
    Workday/ADP/M365 fallback was already scoped in design.
  - Preferences UI: a distinct add/remove list (URL entry + optional
    nickname, validated as a real URL before saving), separate from the
    existing curated-table checklist — these are two different
    interaction shapes (toggle existing vs. add new), not one list.
  - Storage: `UserDefaults`, same mechanism `saasEnabledServices`
    already uses for `[String]` (not `@AppStorage`-compatible) — likely
    a `[String: String]` or small `Codable` struct array (URL +
    nickname) rather than a bare string array.
  - Does a user-added entry get folded into the same
    `SaaSMonitoringViewModel.statuses` list as the curated ones (one
    unified Events/rollup treatment), or does "reachability only, no
    real status API" need its own visually distinct row so it isn't
    mistaken for a higher-confidence status-page-backed check — same
    open question `DESIGN-NOTES.md` already raised for Workday/ADP/M365
    specifically.

- [ ] **Popover should roll up non-green SaaS statuses.** SaaS monitoring
  is window-only per `SectionLayout`'s audience split (popover = "can I
  work, what's restricted"), so a real outage (e.g. Slack red) is
  currently invisible unless someone opens the window. Would fit the
  popover's existing "can I work" framing without reopening the
  deliberate cut against `OverallStatus`/menu-bar color integration
  (see the SaaS monitoring plan's Context section): this would be its
  own independent popover signal, not a change to what the menu-bar
  color means.

  **Concrete shape proposed directly**: a small, fixed-height (2 lines)
  box, shown only when at least one monitored service isn't `.none` —
  problems only, not a full status list, so it costs zero popover space
  when everything's healthy (same "earn its keep" principle
  `SectionLayout.scrollThreshold`'s doc comment already states for
  every other box in this app). At exactly 2 lines it can show at most
  2 problem services before needing to scroll or truncate — worth
  deciding which once there's a real case with 3+ simultaneous
  degradations to test against (today's monitored set has never shown
  more than one at a time). Other open questions: does each line carry
  severity (worst indicator per service) or just the name; does a line
  link/scroll to the window's SaaS section when clicked; does it appear
  at all when the feature flag is off (no, matching every other
  conditional section).

- [ ] **Do we need a "dark mode" for the app?** Raised directly, not yet
  investigated. Worth checking what actually happens today first —
  `MenuBarExtra(.window)` and the plain `Window` scenes may already pick
  up the system appearance for free via standard SwiftUI/AppKit
  materials, or specific colors here (the status dots, `Sparkline`'s
  hardcoded `.secondary`/`.red`, the orange debug-override banner, the
  yellow bug-report tint) may not adapt correctly against a dark
  background. Needs a real check in dark mode before deciding whether
  there's anything to build at all.

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

- [ ] **Confirm Printer Alerts' new fixed-height box actually fits 2
  printers live.** Built (`3bea552`, `65c4c00`): `ContentView` now has a
  `printerAlertsList` wrapping `printerAlertRows` in the same
  `NoBounceScrollView` + fixed-height pattern DHCP History and SNMP
  Devices use, sized at 3 x 17 = 51pt (a row of headroom past the exact
  2-row boundary, after a same-day Bug Report — "might need to be taller
  for 2 printers" — flagged that the first cut, sized to exactly 2 x 17
  = 34pt, was untested against a real second printer). Still only 1 real
  printer configured on this network, so the live fit has never actually
  been seen. `PrinterDiscoveryService.parseAlerts`'s multi-printer
  parsing itself is already confirmed correct (existing `multiPrinter`
  unit test pins exactly two, and nothing downstream narrows to one) —
  this remaining task is purely "does 51pt actually look right with 2
  real rows," which needs a second printer to check.

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

- [ ] **Is the plain Screenshot button still needed now that Bug Report
  exists?** Real question, but the two aren't redundant — checked what
  each actually does. Screenshot (`ScreenshotViewModel.capture`) is a
  single no-prompt action: grabs the image, logs `screenshotCaptured`,
  done. Bug Report (`captureBugReport`) is a strict *superset* of that
  same screenshot mechanism, plus a state dump, plus a comment/severity
  — but its own doc comment is explicit this was a deliberate design
  choice, not an oversight: "Deliberately a separate button from
  Screenshot above, not a prompt bolted onto it — that one's whole
  value is staying a fast, no-prompt capture. This one exists
  specifically to stop and ask 'what are you seeing.'"

  Submitting Bug Report with an empty comment *would* work as a
  Screenshot replacement functionally (the code already handles an
  empty comment gracefully — `"(none)"`), but costs two extra clicks
  (open the prompt, confirm with nothing typed) and always writes a
  state-dump file even when nobody needed one. This session's own
  history argues for keeping both: several screenshots handed over
  mid-session this exact week were all the fast, no-prompt button,
  precisely because typing a comment first would have been friction
  for "just look at this."

  Leaning toward **keep both** — but it's your workflow being optimized
  here, not a technical necessity either way.

- [x] ~~"Open in Window" shouldn't appear once you're already in the
  window.~~ **Done.** Gate is now
  `if FeatureFlags.comparisonWindow && !isInWindow`, the inverse of the
  `isInWindow && ...` pattern every window-only section already uses.
  Build clean, 64/64 tests, relaunched without issue. Not yet confirmed
  by eye that the button actually disappears from the window's own
  footer — no Accessibility permission to click through it from here.

- [ ] **Add a length cap to untrusted network-derived text before it's
  persisted.** Found during a security review requested ahead of
  letting friends try the app. SNMP `sysDescr`/`sysName`
  (`SNMPService.probe`) and DHCP option strings
  (`DHCPLeaseService.parse`) are genuinely untrusted — they come from
  whatever a device on the LAN chooses to send back — and neither has a
  length limit before being stored in SwiftData and rendered in a
  `Text` view. Not exploitable (every string only ever reaches plain
  `Text(String)`, never `Text(markdown:)` or `AttributedString(markdown:)`,
  so there's no rendering-injection path regardless of size), but a
  misbehaving or malicious device could still bloat the store or slow a
  render with an oversized response. Low severity, real gap — a
  reasonable cap (a few KB) at the parsing boundary would close it
  cheaply. The rest of the review came back clean: every subprocess
  call uses `Process`'s array-form arguments (no shell, no injection
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

**From off-site testing at Martha's** (8 items originally; 3 turned out
to be bugs and moved to `BUGS.md` — Known Networks not recognizing an
unfamiliar network, the first-traceroute latency inflation, and the
Wi-Fi transition event misfiling. 4 more were already fixed and dropped
from this list. This one remains, since it's an idea, not a defect):

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

- [x] ~~Decide whether to keep the printer alerts feature.~~ **Decided:
  keep.** Reasoning: the ~91ms-avg `lpstat -l -p` cost every round is
  marginal next to what's already accepted elsewhere (the SNMP sweep's
  up to 32 concurrent `snmpget`s), the UI is window-only so it costs no
  popover space, and it's forward-compatible for free — works the
  moment better-behaved printer hardware is on the network, no code
  changes needed. Known, accepted risk: since it's never produced a
  true positive on real hardware, the "an actual alert renders
  correctly" path has only ever been exercised by the negative case
  (`Alerts: none`), not confirmed against a real fault making it all
  the way to the UI.

- [ ] **Run `/code-review ultra` on the branch.** User-triggered and
  billed, so it can't be launched from a session. Worth it: a manual pass
  over just the concurrency and event handling found a shipped crash and
  a main-thread stall, so a multi-agent pass over the whole branch would
  likely surface more.

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
- **IPv4 Record Route (or other IP options) for explicit path recording**,
  raised from prior experience with them on Cisco routers. Largely
  non-functional on today's public internet: modern backbone/ISP routers
  widely treat any packet carrying IP options as a slow-path case and
  drop, rate-limit, or ignore them outright — long-standing practice from
  when options-bearing packets were a common scanning/DoS vector, and
  because fast-path forwarding hardware doesn't handle them. Even where a
  router does cooperate, the classic 40-byte options field caps Record
  Route at about 9 hops before running out of room. `TracerouteService`'s
  existing TTL-increment/ICMP-Time-Exceeded technique already gets the
  same "explicit path recording" outcome without needing any router
  cooperation beyond generating a TTL-expiry ICMP message, which every
  router still does regardless of how it treats IP options — so this
  would add nothing traceroute doesn't already show, and would likely
  work less reliably given how often options get dropped in transit.
