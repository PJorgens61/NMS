# Developer setup (multi-machine)

This project is developed across two Macs — an iMac and an M1 MacBook
Air — kept in sync by git alone, never by copying a built `.app` between
them (code signing resets on transfer, and an earlier iCloud-Drive-synced
`.app` caused a real sync-conflict/wedged-process incident). Each machine
clones independently and builds its own local binary. This doc is what a
second machine needs to match the first, and the handful of things that
are allowed to differ.

## Prerequisites

- **Xcode 15+** (this project currently develops against Xcode 26.3;
  check `xcodebuild -version` on each machine and don't worry about
  matching exactly, but a large gap — a major version or more — is worth
  knowing about before debugging something that turns out to be a
  toolchain difference rather than a code difference).
- **Command Line Tools** for git (`xcode-select --install` if `git
  --version` fails).
- No Apple Developer Program membership needed to build and run locally
  — see [Signing](#signing) below.

## First clone and build

```bash
git clone https://github.com/PJorgens61/NMS.git
cd NMS
```

Then either open `NMS.xcodeproj` in Xcode and Run (⌘R) on the `NMS`
scheme, or from the command line:

```bash
script/build-and-run.sh --run
```

That script pulls `origin/main`, builds Debug, and launches the result —
the standard way to bring a machine's checkout and binary up to date
together, rather than as two separate steps that can drift apart. See
the next section for why "built" and "up to date" drifting apart is a
real, not theoretical, risk here.

## Verifying you're running what you think you're running

**This bit the project once already, expensively.** A binary built on
2026-07-29 kept running for two days after several commits had landed
on top of it — including a database schema change — and nothing said so.
The footer's "Build `<hash>`" line looked current because
`BuildInfoService` used to read `git rev-parse HEAD` *at launch*, which
answers "what does the checkout say right now," not "what was this
binary actually built from." The two are the same thing only if you
rebuild every time the checkout changes, which is exactly the assumption
that failed.

Fixed in `4104b24`: the hash is now stamped into `Info.plist` at build
time and never touches git at runtime, so the footer can't drift from
the binary again. Two things still worth doing on a new or
long-idle checkout:

- **After pulling, always rebuild before trusting the footer** — the
  stamp is only as fresh as the last build, same as any compiled
  artifact. `script/build-and-run.sh` does this for you.
- **Check `~/Library/Developer/Xcode/DerivedData/` for more than one
  `NMS-*` directory.** This project hit that too: two stale DerivedData
  folders for the same project meant a glob-based `open` could launch
  either one. If you find more than one, delete the older ones —
  `DerivedData` is disposable, never anything to preserve.

## First run: permissions

Each machine prompts independently — granting these on one Mac has no
effect on the other:

- **Local Network** — for the ARP table read and SNMP polling. Denying
  it doesn't crash anything; those features just report nothing.
- **Location, "When In Use"** — solely to unlock `CWInterface.ssid()`.
  macOS treats Wi-Fi network names as location-sensitive, so reading the
  current SSID requires this even though NMS has no other use for
  location data. See `LocationAuthorizationService`'s doc comment if the
  prompt doesn't appear at all — it has to `activate()` the app briefly
  first, since a `.accessory`-policy app that's never been foregrounded
  can otherwise never get the OS to show it.

## Signing

`CODE_SIGN_STYLE = Automatic` on every target, and neither development
machine has a paid Apple Developer Program membership. Xcode's automatic
signing handles this fine for local development — on a fresh machine, if
you're prompted, either add a free personal team (Xcode → Settings →
Accounts → **+**) or let Xcode fall back to "Sign to Run Locally." Either
way the app runs; a paid membership is only needed for the separate,
optional Developer ID-signed/notarized release path (`script/release.sh`,
see the README's "Signed and notarized releases").

## The store is per-machine, and never migrates automatically today

`~/Library/Application Support/NMS/default.store` holds all persisted
history (Events, DHCP leases, SNMP devices, known networks) and is
**never synced between machines** — each Mac accumulates its own. That's
by design (this is a local-only app; see the README's privacy section),
but it means a fresh clone on a new machine starts with genuinely empty
history, not a copy of the other machine's.

More important: **this project has no `SchemaMigrationPlan`.** SwiftData's
lightweight migration handles additive, optional changes to `@Model`
types, but a non-optional attribute added to a model that already has
rows fails outright — confirmed the hard way (`BUGS.md`, "The persistent
store fails to open"): the store silently fell back to an in-memory
container, every launch started empty, and nothing said so for two days.
That specific bug is fixed, and the fallback is loud now (a red popover
banner, not silence) — but the underlying limitation is not: **a future
schema change that adds a new non-optional stored property to an
existing `@Model` type will hit the same wall.** When changing a model:
prefer optional properties or new tables over new mandatory attributes,
and if you must add one, back up the store first:

```bash
cp -R ~/Library/Application\ Support/NMS/default.store* /tmp/nms-store-backup/
```

If the store ever does fail to open, `MANUAL-TESTS.md`'s launch checklist
already covers what that looks like in Console.

## Feature flags: decide whether both machines match

One feature is off by default (`UserDefaults`-backed, see the README's
"Experimental features"):

```bash
defaults write Thistle.NMS FeatureSNMPDevices -bool true
```

There's no requirement that both machines run the same setting — a
MacBook used for field testing away from a home LAN, for instance, has
less use for `FeatureSNMPDevices` (it probes whatever network the Mac
is actually on). Worth a deliberate choice either way rather than an
accidental one, since a bug that "doesn't reproduce" on the other
machine is sometimes just a flag difference.

Expert Mode (the resizable window alternative to the popover) used to
be a second flag here, `FeatureComparisonWindow` — that's gone; it's a
permanent, always-on part of the app on both machines now, nothing to
keep in sync.

## Git workflow

Direct on `main`, no long-lived feature branches for solo/pair work like
this. Before editing on either machine:

```bash
git fetch origin
git log HEAD..origin/main --oneline   # anything to pull first?
git status --porcelain                 # anything local uncommitted?
```

If both the working tree and the incoming pull touch the same file,
`git stash push -m "..." <file>` → `git pull --ff-only` → `git stash pop`
has resolved every real conflict this project has hit so far (clean
auto-merge, no markers). Never `--force` push to `main`.

Commit messages here favor the *why* over the *what*, with enough detail
that `BUGS.md`/`DESIGN-NOTES.md` entries can point back at a specific
commit and have it hold up on its own. Not a hard rule, just the
established style — match the surrounding log.

## Coordinating across machines

[GitHub issue #6](https://github.com/PJorgens61/NMS/issues/6) (pinned)
is the low-ceremony channel for cross-machine status: "can you confirm
this fix on your machine," "here's what I found on mine," things that
don't merit their own `BUGS.md`/`PUNCHLIST.md` entry. It's proved
genuinely useful for exactly the case it was built for — confirming a
machine-specific bug's fix on the machine that actually exhibited it.

For anything that's an actual defect or a real decision, `BUGS.md` and
`PUNCHLIST.md` are the durable record; the issue is for the back-and-forth
that gets a fix to that point.

## Real differences to expect between these two machines

Not bugs — worth recognizing as environment, not regression, when they
show up:

- **macOS version gap** (developed against both 15.7 and 26.5 at once).
  At least one real AppKit behavior change has already been found this
  way: `NSApp.activate(ignoringOtherApps:)` silently stops bringing a
  `.accessory` app's window forward on the newer OS (`BUGS.md`, "No
  window comes to the front on the MacBook"). If something works on one
  machine and not the other, a deprecated-API grep
  (`NSApp\.|NSApplication\.|NSRunningApplication`) is worth trying before
  assuming a logic bug.
- **Screen size** — the MacBook Air's shorter screen is what's forced
  every popover-height trim so far (`NMS/Views/SectionLayout.swift`
  documents the current budget and the measured 17pt/row constant behind
  it). A layout that fits comfortably on the iMac may not on the MacBook;
  `SectionLayout.estimatedPopoverCeiling` is still an estimate, not a
  confirmed number, pending an actual `ContentView.liveHeight` reading
  taken on the MacBook Air.
- **Ethernet vs. Wi-Fi** — whichever machine is normally on Ethernet
  exercises no Wi-Fi-only code path (the Wi-Fi tile, BSSID, SSID
  recognition) in day-to-day use. A Wi-Fi-specific bug may only ever
  show up on the other machine, and a fix built on the Ethernet machine
  may be entirely unverified there until the other machine confirms it.
