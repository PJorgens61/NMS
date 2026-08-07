# Trust assessment — TRUST.md's expanded prompt, run 2026-08-06 (17:1x PT)

**Commit reviewed:** `dffe0b07e06fa7c6fbb829ad54065c9073a9b61a` (`main`,
clean tree)
**Reviewed by:** Claude (Sonnet 5), via Claude Code, at the repo
owner's request.
**Reviewed for:** an actual run of [`TRUST.md`](../../TRUST.md)'s own
nine-question prompt (expanded the same day from the original six —
see that file's git history), against the current repository, rather
than a description of what the prompt covers.

## Read this section first: what this document is, and isn't

Same non-certification caveat as the other three review docs in this
directory — no accountable third party, no proof this wasn't edited
after generation, don't trust the byline, verify instead.

Method for this run, specifically: re-verify via
`script/privacy-security-check.sh` against its checked-in baseline
first (a clean diff means nothing in scope drifted since the baseline
commit), then fresh source reads only for the two items that script
doesn't cover (sandboxing status, feature safety scoping — code had
moved files since the 2026-08-03 review named them), then one live
spot-check against the actual running instance for the VALIDITY
BOUNDARY question.

```
script/privacy-security-check.sh
```
Result: `No changes since the baseline captured at the last review.`

## Findings

### 1. PRIVACY
Endpoint enumeration and telemetry-SDK grep both come from the
automated script — clean, matching the committed baseline exactly. On
the specific new question the expanded prompt adds — does a
reachability-only check avoid downloading the full response body —
**no**: `SaaSStatusService.swift:129-149`'s `.reachabilityOnly` shape
still issues a plain `GET` and downloads the entire response before
discarding it. Filed as
[PJorgens61/NMS#18](https://github.com/PJorgens61/NMS/issues/18), not
yet fixed as of this commit.

### 2. SECURITY
Script confirms: zero hardcoded secrets, zero shell-string subprocess
risk, array-form arguments throughout. Entitlements unchanged
(`NMS/NMS.entitlements`: `keychain-access-groups` only). SNMP community
strings still deliberately in `UserDefaults`, documented as a reasoned
tradeoff (`CommunityRow.swift:4`), not an oversight.

### 3. DEPENDENCIES
Script confirms zero SPM dependencies (no `Package.swift`/
`Package.resolved`, zero `XCRemoteSwiftPackageReference` entries). Only
third-party code: `scamper` (GPL-2.0), invoked as a subprocess only,
never linked.

### 4. COPYRIGHT/LICENSING
`LICENSE` present, MIT, © 2026 Paul Jorgensen. Standard disclaimer
clause confirmed present verbatim, unmodified.

### 5. PLATFORM SANDBOXING / PRIVILEGE
```
grep -n "ENABLE_APP_SANDBOX" NMS.xcodeproj/project.pbxproj
```
`ENABLE_APP_SANDBOX = NO` at both lines 426 and 471 (Debug and
Release) — unchanged from the 2026-08-03 finding, still true at this
commit. Documented reason holds: the app needs `ping`/`arp`/
`traceroute`/`snmpget` subprocesses and raw ARP/DHCP reads, which the
App Sandbox blocks. Practical implication, stated plainly: NMS runs
with the same filesystem/network access as any other unsandboxed app
you've granted permission to run — not Mac App Store-eligible as
shipped (`README.md:867`).

### 6. FEATURE SAFETY SCOPING
Re-verified at current commit — this logic moved files since
2026-08-03 (`WiFiStressTestViewModel.swift`/`LocalStressTestTile.swift`
now, not `ContentView+Window.swift`), same behavior:
```
grep -n "\.run(routerAddress" NMS/Views/LocalStressTestTile.swift
grep -n "hasConfirmedBefore" NMS/ViewModels/WiFiStressTestViewModel.swift
```
Local Stress Test still only ever targets
`viewModel.currentInterface?.routerAddress`
(`LocalStressTestTile.swift:32,37,54`) — the Mac's own auto-detected
gateway, never free-form input — and still requires passing a
confirmation alert unless `hasConfirmedBefore` is true
(`WiFiStressTestViewModel.swift:46`). LAN discovery is still passive
— reads the kernel ARP cache (`arp -a`), no active subnet probing
(`LANDiscoveryService.swift:3-6`).

### 7. RED FLAGS
Script's OAuth/GoogleCloud/ASWebAuthenticationSession grep: zero
matches, same as 2026-08-03. No obfuscation or undisclosed complexity
found in anything read across this or prior reviews.

### 8. TRUST SIGNALS
Commit history remains real and incremental (400+ commits, dated,
explained messages). `PUNCHLIST.md`/`BUGS.md` still read as genuine
engineering logs. CI (tests + CodeQL + gitleaks) still running as
documented.

### 9. VALIDITY BOUNDARY
This report is valid as of `dffe0b0`. A live spot-check was actually
run, not just cited:
```
lsof -i -a -p 16796 -n -P
```
against the still-running Debug instance (PID `16796`) caught roughly
15 simultaneous `ESTABLISHED` connections. Each was reverse-resolved
(`dig -x`) and matched exactly against the forward-resolved IPs
already established in
[2026-08-06-runtime-network-audit.md](2026-08-06-runtime-network-audit.md),
confirming `trello.status.atlassian.com`, `status.atlassian.com`,
`status.asana.com`, `status.claude.com`, `status.docusign.com`,
`www.cloudflarestatus.com`, `slack-status.com`, `api.ipify.org`, and
`captive.apple.com` all firing in a single round. This closes the gap
that earlier runtime audit explicitly left open — it hadn't caught a
full 300-second poll cycle; this run did.

## Bottom line

Everything holds up except the one already-known, already-filed gap
(#18 — the full-body `GET` on reachability-only checks). No new issues
found. This run also retired the one open caveat from the 2026-08-06
runtime audit: a full SaaS Status poll cycle has now actually been
observed live, not just inferred from source.
