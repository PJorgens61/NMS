# Punchlist

Open items, tracked here so they survive between sessions. Not a spec —
see `DESIGN-NOTES.md` for the reasoning behind anything non-obvious.
Actual defects live in `BUGS.md` instead — this file is ideas, testing
tasks, and decisions. Check items off or delete them as they land; add
new ones as they come up.

## Open

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

- [ ] **The in-app Screenshot/Bug Report capture doesn't render the same
  layout the live app uses — raised directly ("the screenshots don't
  seem to work... i can do manual screenshots faster"), and just caused
  a real diagnostic miss.** Found while fixing the "snmp needs more
  space for text" report (`NMS-2026-08-01-165919.png`, see `BUGS.md`):
  the attached screenshot showed the Switch device's `sysDescr` wrapping
  correctly across two lines — because `capture(_:)`/`captureBugReport(_:)`
  render `scrollableContent` with `isCapturingScreenshot = true`, which
  makes every `scrollBox`-boxed section (Events, SNMP Devices, DHCP
  History, Speed Test, traceroute hops) skip `NoBounceScrollView`
  entirely and render as a plain, unclipped `VStack` instead (see
  `scrollBox`'s own doc comment — this was deliberate, to work around
  `ImageRenderer` not rendering `NSViewRepresentable`/`ScrollView`
  content off-screen at all). The live window, going through the real
  `NoBounceScrollView`/`NSHostingView`, was actually truncating that
  same text to one line with a "…" — confirmed only by scrolling the
  real running app and comparing screenshots by hand, not by anything
  in the report itself. So the capture path's whole design (unclip
  everything so `ImageRenderer` has something to draw) makes it
  structurally unable to reproduce a layout bug that only exists
  *inside* the boxes it's deliberately avoiding — exactly the failure
  mode that prompted this report to begin with. Nothing built yet;
  worth a real pass on what a screenshot tool that can actually show
  `NoBounceScrollView` content would need (a different capture
  mechanism entirely, e.g. `screencapture`-driven against the real
  `NSWindow` rather than `ImageRenderer` against a modified copy of the
  view tree), weighed against just leaning on manual `screencapture` /
  the OS's own screenshot shortcut instead of maintaining this one.

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

- [ ] **Use SNMP against the router/switch itself to discover devices on
  subnets too large to sweep, instead of a raw IP sweep.** Follows
  directly from the just-shipped fix restricting
  `SNMPViewModel.candidateAddresses()` to strictly the current subnet
  (see DESIGN-NOTES.md's "A router serving two VLANs..."): above
  `SubnetCalculator.maxSweepHosts` (1024 hosts, e.g. a `/21` or larger —
  or the real `/8` case raised directly this session), the app now
  correctly refuses to brute-force every address and falls back to just
  the gateway, logging `.subnetTooLargeToScan` so it isn't silent. But
  the router/switch that runs that subnet already knows every device on
  it, via its own ARP table and/or switch forwarding table — asking it
  directly would restore real discovery on a large subnet without ever
  touching every host address one at a time.

  Two standard SNMP tables would do this, if the hardware actually
  supports them (unverified — see the neighboring "Cross-check the
  router's own interfaces/routes via SNMP" item above, which found this
  network's printer had weak standard-MIB support and never got to test
  the router itself):
  - `ipNetToMediaTable` (`1.3.6.1.2.1.4.22`, RFC 1213) — the router's own
    ARP cache: IP ↔ MAC pairs for everything it's talked to on that
    subnet. Directly gives candidate addresses without sweeping.
  - `dot1qTpFdbTable` (Q-BRIDGE-MIB, `1.3.6.1.2.1.17.7.1.2`) — a
    managed switch's CAM/forwarding table, MAC-keyed rather than
    IP-keyed, so it'd need combining with the router's ARP table (or a
    fresh sweep of just the resulting small candidate set) to get to IP
    addresses worth polling for `sysDescr`/`sysName`/uptime.

  **Concrete next step, before any code**, same shape as the neighboring
  item: `snmpwalk` this network's own router/switch directly —
  ```bash
  snmpwalk -v2c -c public -t 2 -r 1 <router-ip> 1.3.6.1.2.1.4.22   # ipNetToMediaTable
  snmpwalk -v2c -c public -t 2 -r 1 <switch-ip> 1.3.6.1.2.1.17.7.1.2  # dot1qTpFdbTable
  ```
  If both come back empty or unpopulated on this network's own gear,
  this is a dead end on real hardware and worth writing up as such,
  same as the printer and (pending) router-route-table findings — not
  worth half-building against a MIB that isn't actually there. If one
  or both work, this would need its own decision on where it plugs into
  `candidateAddresses()`: worth noting this reintroduces exactly the
  off-subnet risk the ARP-cache removal just fixed if not scoped
  carefully — a *stale* entry in the router's own ARP table for a
  device that's since moved to a different network would need the same
  same-subnet filter `rebuildDeviceList` already applies to everything
  else, not a blanket trust of whatever the router reports.

- [ ] **macOS notifications for sustained outages? Raised, not yet
  designed.** The idea: push a system notification (not just the
  popover/Events log, which only get seen if someone's already
  looking) for a real, sustained problem. Biggest risk identified up
  front: this network is demonstrably flap-prone (dozens of "became
  unreachable/reachable again" Events-log entries in a few minutes of
  ordinary testing this session) — naively notifying on every
  Events-log entry would be noisy enough to train someone to ignore it
  fast. The useful version would almost certainly need to reuse
  `ConnectivityViewModel`'s existing sustained-vs-transient filtering
  (`isWithinTopologyChangeWindow`/`shouldSuppressAsLocalInterference`)
  rather than hooking raw event logging, and probably scope to just
  `OverallStatus.critical` (router/internet/DNS/HTTP actually down),
  not SNMP restarts or printer blips. Nothing designed or built yet —
  needs its own real pass before starting.

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

- [ ] **Shrink SNMP Devices' box height.** `SectionLayout.boxHeight(on:)`:
  `200` → `150` (requested directly, down 25%). That 200 is explicitly
  taller than its neighbors "because `sysDescr` wraps instead of
  truncating and needs the extra room" (that type's own comment) —
  worth a live check that a real wrapped `sysDescr` (the switch's is
  the longest seen so far, two lines) still reads fully at 150 before
  landing on it, not just trusting the arithmetic. (The matching
  Printer Alerts half of this item is moot — that tile was removed
  entirely; see "Decide whether to keep the printer alerts feature.")

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

- [ ] **iCloud needs a scoping decision too — it isn't one service.**
  Raised directly. Apple's system status feed
  (`https://www.apple.com/support/systemstatus/data/system_status_en_US.js`)
  is real, live, and unauthenticated — confirmed against a real
  *resolved* incident (Apple Cash, 07/31/2026), whose event shape is
  `{"messageId", "statusType", "message", "datePosted", "startDate",
  "endDate", "epochStartDate", "epochEndDate", "usersAffected",
  "affectedServices", "eventStatus": "resolved"}`. Two real problems,
  neither a drop-in the way Cloudflare/Figma/HubSpot/Docusign were:
  - **Completely different shape** from every existing entry: one flat
    list of ~78 named Apple services, each carrying its own `events`
    array (empty when healthy), not a Statuspage `status.indicator`
    summary. Would need a new `Shape` case — structurally closer to
    the existing `.googleIncidents` parser (a rolling incident list,
    "healthy" is the absence of one) than to `.statuspage`.
  - **"iCloud" is 13 separate entries on this feed**, not one: iCloud
    Account & Sign In, Backup, Bookmarks & Tabs, Calendar, Contacts,
    Drive, Keychain, Mail, Notes, Private Relay, Reminders, Storage
    Upgrades, Web Apps (iCloud.com), plus iWork for iCloud. Needs a
    decision — track one representative sub-service (which one?), or
    aggregate all 13 into a single rolled-up "iCloud" status (red if
    *any* has an active event).

  Also unconfirmed: the *active* (not-yet-resolved) event shape — only
  a resolved one has been observed live, so whether `endDate`/
  `eventStatus` reliably distinguish "still ongoing" isn't verified yet.
  Worth checking the next time any of these 78 services has a real,
  ongoing issue before writing the parser.

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

**From off-site testing** (8 items originally; 3 turned out
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

- [ ] **File the two `swift-frontend` compiler crashes with Apple
  Feedback Assistant.** Two genuinely different crashes, not two copies
  of one — the previous wording here conflated them: (1) "failed to
  produce diagnostic for expression" at type-checking, on a conditional
  `Window` scene inside `@SceneBuilder`; (2) an `EarlyPerfInliner` SIL-
  optimizer crash, Release/Archive builds only, on a class's
  synthesized `deinit` when that class is nested inside a generic type.
  Raised as a to-do three times now and never actually filed — actual
  submission needs the user's Apple ID in Feedback Assistant's own app,
  not something doable from here.

  **Both reports fully drafted and ready to paste in** — title,
  description, minimal standalone repro code, and the toolchain
  versions they were found on (Xcode 26.3/17C529, Swift 6.2.4, macOS
  15.7.7). Delivered to the user as a file; not committed here since its
  only job is a one-time paste into Feedback Assistant, not ongoing
  project documentation. Both workarounds already live in the real code
  (`NMSApp`'s `comparisonWindowContent`; `NoBounceScrollCoordinator` at
  the top level) — filing these is purely for Apple's benefit at this
  point.

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
