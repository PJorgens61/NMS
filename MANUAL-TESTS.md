# Manual test checklist

Run this against a fresh build before calling it good, or after any
change likely to touch the areas below. Not a substitute for the real
unit tests (`NMSTests`) — this is for the things those can't reach:
actual network transitions, actual windows, actual hardware.

**Before you start**: note the build hash from the popover footer
("Build `<hash>`[+dirty]") — every failure you log (here or in
`BUGS.md`) should reference it, same convention `BUGS.md` uses.

Log each run at the bottom of this file: date, build hash, pass/fail
summary, and a link to any new `BUGS.md` entry a failure produced.

## Launch and persistence

- [ ] App launches, menu bar icon appears (📶 or 🔌).
- [ ] Popover opens on click; no crash, no blank tiles.
- [ ] **Check the Console log for a CoreData migration error**
  (`NSCocoaErrorDomain 134110` / "Cannot migrate store in-place") — the
  known failure mode after any `KnownNetwork`/SNMP/DHCP/Events schema
  change. If the app silently degrades to an in-memory store, this is
  expected *only* right after a schema change (delete
  `~/Library/Application Support/NMS/default.store*` and relaunch to
  confirm a clean store loads) — otherwise it's a regression.
- [ ] Store size in the footer is non-zero and plausible after a few
  minutes running (not stuck at 0, not immediately huge).

## Network Health (the core loop)

- [ ] All seven rows populate within one check cycle; no row stuck on
  "checking" indefinitely.
- [ ] Sparklines render per row (not just the top-level color).
- [ ] Disconnect Wi-Fi/Ethernet: the interface goes down, dependent rows
  go red, an `interfaceDown` event appears in Events.
- [ ] Reconnect: rows recover, an `interfaceUp`/recovery event appears,
  and the root-cause dimming logic looks right (only the lowest failed
  row full-red, the rest dimmed) if you can catch a multi-row failure.

## Network transitions and Known Networks — the highest-risk area right now

- [ ] **Join an unfamiliar network** (guest Wi-Fi, phone hotspot,
  somewhere new) and confirm it actually gets added to Known Networks —
  this is `BUGS.md`'s open "Known Networks silently never adds an
  unfamiliar network" bug; a failure here is that bug reproducing, not a
  new one.
- [ ] Events / SNMP Devices / DHCP History all scope to the *current*
  network only — nothing from a previously-visited network bleeds in.
- [ ] Return to a known network: label and prior history are intact and
  reachable via Network Review.
- [ ] Watch the very first traceroute after joining — compare its
  latency against a second trace run a minute later. A big gap
  reproduces `BUGS.md`'s inflated-first-traceroute bug.
- [ ] Check for duplicate SNMP device rows after a transition:
  ```bash
  sqlite3 ~/Library/Application\ Support/NMS/default.store "SELECT ZIPADDRESS, ZNETWORKFINGERPRINT, COUNT(*) n FROM ZSNMPDEVICERECORD GROUP BY 1,2 HAVING n>1;"
  ```
  Empty output means clean.

## SNMP Devices

- [ ] Devices populate within one sweep; no permanently-empty list.
- [ ] A device that VRRP-merges (if you have one) shows as one row, not
  two, and its alias address's `lastSeenAt` doesn't go stale (per-device
  spot check, not usually visible from the UI alone).
- [ ] Restart or upgrade a real SNMP-capable device if you can — confirm
  the restart/software-change event actually logs.

## DHCP History, Events

- [ ] Both populate with plausible, current-network-only entries.
- [ ] A DHCP renewal or lease change (if you can force one) shows up.

## Speed Test

- [ ] Runs to completion on both a normal connection and, if available,
  a deliberately slow one (throttle, or a known-slow network) — confirms
  the 2MB-probe-then-escalate logic isn't stuck defaulting to the full
  25MB on a slow link.
- [ ] Numbers are plausible against a known reference (another speed
  test tool, or expected ISP tier).

## Windows — check on every machine you have, not just one

- [ ] **Open in Window**, **Preferences**, and **Known Networks** each
  open *and come to the front* — this is `BUGS.md`'s open MacBook
  foregrounding bug; if any window opens but stays behind the main
  window, note which machine and macOS version (`sw_vers`).
- [ ] Open in Window: independent scrolling per section, scrollbar
  reaches full content, no bounce-back.
- [ ] Wi-Fi tile appears in the window (Wi-Fi only, not Ethernet).
- [ ] Known Networks: rename a network, delete a network (confirm its
  Events/SNMP/DHCP rows are actually gone after, not orphaned), review a
  past network's data while connected elsewhere.

## Screenshot and misc footer controls

- [ ] Screenshot button produces a real, correctly-sized image.
- [ ] Refresh button triggers an immediate re-check, not just a UI
  no-op.
- [ ] Quit actually quits (no orphaned background process).

## Debug tooling (DEBUG builds only)

- [ ] Interface-down injection produces real `interfaceDown`/`interfaceUp`
  events, not just a UI state change.
- [ ] Active-overrides banner appears when a debug override is active,
  and clears when it isn't.
- [ ] UI state log (`~/Library/Logs/NMS/ui-state.log`) is actually being
  written to during the run — useful for diagnosing anything above,
  including the window-foregrounding bug.

## Run log

<!-- Newest first. One line per run; link new bug reports. -->

- _(none yet — first entry goes here)_
