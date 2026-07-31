# Punchlist

Open items, tracked here so they survive between sessions. Not a spec —
see `DESIGN-NOTES.md` for the reasoning behind anything non-obvious.
Actual defects live in `BUGS.md` instead — this file is ideas, testing
tasks, and decisions. Check items off or delete them as they land; add
new ones as they come up.

## Open

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
