# Punchlist

Open items, tracked here so they survive between sessions. Not a spec —
see `DESIGN-NOTES.md` for the reasoning behind anything non-obvious.
Actual defects live in `BUGS.md` instead — this file is ideas, testing
tasks, and decisions. Check items off or delete them as they land; add
new ones as they come up.

## Open

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

- [ ] **Split by audience: popover for business users (summary only),
  the real window for IT users (everything).** Raised directly: liked
  the full app window enough to wonder whether the popover and the
  window should eventually serve two different audiences rather than
  being "the same content, one has more room" — popover trimmed to
  summary status indicators only, window keeps the full detail
  (Network Health rows, Info, Path to Internet, SNMP Devices, DHCP
  History, everything).

  This is the natural conclusion of a question `DESIGN-NOTES.md`'s
  "Business SaaS monitoring" section left half-resolved — it worked out
  that a business user wants "can I work, what's restricted" while an
  IT-minded read wants root cause and specificity, and left the
  resolution at "headline color stays simple, detail lives one level
  down via drill-down." Splitting by *surface* (popover vs. window)
  instead of by interaction depth within one surface is a cleaner
  version of that same resolution, not a new idea.

  Real open questions before this is a plan, not just a direction:
  - **What exactly counts as "summary"?** The popover today isn't
    thin — it's the full 2×2 tile grid (Network Health, Info, Path to
    Internet, Speed Test) plus Events/SNMP Devices/DHCP History.
    Reducing it to indicators-only is a genuine content
    redistribution, closer in scope to the popover-height-calibration
    work already done than to a UI tweak — needs its own real
    specification (just the top-level red/yellow/green icon? A
    handful of key rows?).
  - **Is there a confirmed business-user audience yet, or is this
    designing ahead of one?** The README's "Status: early" framing is
    explicit this is currently a personal project. Not a reason not to
    log the direction, but worth being honest that nothing is forcing
    this redesign right now.
  - Does "Open in Window" become the *only* full-detail surface, or
    does the popover keep an expand/collapse path for someone who's
    both audiences at once (this app's actual current usage)?

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
