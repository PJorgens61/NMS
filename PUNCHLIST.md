# Punchlist

Open items, tracked here so they survive between sessions. Not a spec —
see `DESIGN-NOTES.md` for the reasoning behind anything non-obvious.
Check items off or delete them as they land; add new ones as they come up.

## Open

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

- [ ] **No window comes to the front on the MacBook** — Open in Window,
  Preferences and Known Networks all fail there, while all three work on
  the iMac from the same build. That it's *all three* is the important
  part: this isn't a per-window bug, the whole `openWindowInFront`
  mechanism is inert on that machine, so look for a machine-level cause
  before touching per-window logic.

  **Leading suspect: macOS tightened focus-stealing.**
  `NSApp.activate(ignoringOtherApps: true)` has been deprecated since
  macOS 14, and later versions increasingly decline to let a background
  app pull itself forward. The iMac runs 15.7.7; if the MacBook is on a
  newer major version, that alone would explain a clean split between two
  machines running identical code. **Get the MacBook's `sw_vers` first —
  that single fact probably settles it.** If confirmed, the fix is the
  modern activation path (`NSApp.activate()` with no arguments, or
  `NSRunningApplication.current.activate(options:)`) rather than more
  window ordering.

  Background: foregrounding was fixed twice already. `0f8f80e` added
  `NSApp.activate`; `1ca9dc8` deferred a run loop turn and then ordered
  the specific window front by identifier, which fixed both windows on
  the iMac (verified from the state log, not by eye).

  **Start with the log rather than the code** — `openWindowInFront`
  already records what it matched:

  ```bash
  grep openWindowInFront ~/Library/Logs/NMS/ui-state.log
  ```

  - `nms-window → nms-window` means the window was found and
    `makeKeyOrderFront` ran, so the failure is *after* that — something
    is re-ordering above it, or the app never became active. Suspect
    Stage Manager, multiple displays, or a different Space, none of
    which the iMac has in the same configuration.
  - `NO WINDOW MATCHED` means SwiftUI hadn't created the window yet when
    the deferred block ran — one run loop turn is enough on the iMac but
    not on the slower/busier machine. That would make the current fix
    timing-dependent, and it should instead retry or hook window
    creation rather than assume a single turn is enough.

  Worth noting the two machines differ in more than speed: the MacBook
  is Apple Silicon and the iMac is Intel, so this may also be a macOS
  version difference rather than a race.

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

- [ ] **Decide whether to keep the printer alerts feature.** It's built,
  correct, and will report "OK" forever on the current Brother printer,
  which exposes nothing useful through either CUPS/IPP or the standard
  SNMP Printer MIB while idle (both verified against the real device with
  a drawer physically open — see DESIGN-NOTES.md's "Printer fault
  detection" section). Keep it for hardware that does populate those
  fields, or pull it and stop running `lpstat` every check round for no
  signal.

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
