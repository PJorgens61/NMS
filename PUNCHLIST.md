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

- [ ] **Known Networks still opens behind other windows, sometimes.**
  Note this is *not* a missing `openWindowInFront` call — that landed in
  `0f8f80e` and all three footer buttons use it. So the remaining case is
  narrower, and worth pinning down before changing anything:
  - Does it happen only when the window is **already open** (just buried)?
    `openWindow(id:)` on an existing window doesn't necessarily order it
    front, and `NSApp.activate` raises the app's *key* window, which may
    be a different one.
  - Or on first open too, in which case the likely cause is ordering —
    `NSApp.activate` runs synchronously, before SwiftUI has actually
    created the window, so there's nothing to raise yet.

  Fix probably needs the window itself ordered front once it exists
  (`NSApplication.shared.windows` lookup by identifier, then
  `makeKeyAndOrderFront`), rather than relying on app activation alone.
  Reproduce first — an intermittent one is easy to "fix" without evidence.

- [ ] **Investigate whether a network label can be silently cleared.**
  Observed once: a label set to `foo bar` read back as `NULL` a few
  minutes later. Ruled out at the time — the `KnownNetwork` row was *not*
  recreated (same `Z_PK`, same `firstSeenAt`, `timesSeen` still
  incrementing), so only an explicit `setLabel` could have written NULL.
  Never established whether it was cleared by hand while testing or
  cleared itself.

  Suspect if it's real: `KnownNetworksView.commitLabel` fires on focus
  loss whenever a draft exists, so if SwiftUI ever writes an empty string
  into the row's `TextField` binding during a `List` rebuild (which
  `refreshKnownNetworks()` causes by reassigning the array), that creates
  an empty draft and blanks the label on the next focus change.

  Cheapest first step is making it answerable rather than guessing: log
  label writes to `UIStateLogger`, then check the log next time it
  happens.

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
