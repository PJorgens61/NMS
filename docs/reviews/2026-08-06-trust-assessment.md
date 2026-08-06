# Trust assessment — 2026-08-06

**Commit reviewed:** `af345267cbeb34737a892706dc26ff3b1e534ae8`
**Reviewed by:** Claude (Sonnet 5), via Claude Code, at the repo owner's request.
**Reviewed for:** the six questions [`TRUST.md`](../../TRUST.md) asks a
reader's own LLM to answer — privacy, security, dependencies,
copyright/licensing, red flags, and trust signals — run against the
actual local clone at the commit above, not a guess from the README.

## Read this section first: what this document is, and isn't

Same caveat as
[2026-08-03-privacy-security-review.md](2026-08-03-privacy-security-review.md):
this is not a certification. No accountable third party stands behind
it, and there's no way for a reader to confirm this file wasn't edited
after being generated. Don't trust the byline — rerun the commands.
This is a static, manual source read (local clone, not a fresh
`git clone`), not a runtime network capture, not a formal audit, and
not a legal license opinion.

## Methodology

All commands below were run from the repo root at the commit above,
against the local clone (already up to date with `origin/main`, clean
working tree). Anyone can rerun them and should get matching results.

## Findings

### 1. Privacy

Local-only for most features: SwiftData persistence, `arp -a`, SNMP
GETs, ping/traceroute, `lpstat`, `ipconfig` do no network I/O beyond
the LAN. `README.md`'s "Network activity and privacy" section (lines
695-739) names four WAN destinations: `api.ipify.org`,
`captive.apple.com` (plain HTTP, deliberately, since TLS would defeat
captive-portal detection), a randomized never-resolving `*.apple.com`
DNS query, and Cloudflare/`networkQuality` (user-triggered only).

**Gap found**: that list is incomplete against the actual Release-build
code.

- `NMS/Services/SaaSStatusService.swift:101-123` polls roughly 15
  third-party status-page APIs (Slack, OpenAI, Anthropic, Atlassian,
  Zendesk, Zoom, Trello, Asana, Notion, Dropbox, Discord, GitHub,
  Cloudflare, Figma, HubSpot, DocuSign, Google Cloud, Google) every
  300 seconds:
  ```
  grep -n "checkInterval" NMS/ViewModels/SaaSMonitoringViewModel.swift
  ```
- This is gated by `FeatureFlags.saasMonitoring`
  (`NMS/Services/FeatureFlags.swift`), which **defaults to on** for any
  install that has never touched the key:
  ```
  grep -n "saasMonitoring" NMS/Services/FeatureFlags.swift
  ```
- `NMS/Services/ISPIdentityService.swift:26` also reaches `rdap.org`,
  confirmed user-triggered only (not on a timer):
  ```
  grep -n "identify(ip:)" NMS/ViewModels/ISPIdentityViewModel.swift
  ```

Neither destination is mentioned in README's "Four things reach beyond
the local network" list. Both are honestly documented in their own
source-level comments and toggle off with one `defaults write`
(`FeatureSaaSMonitoring -bool false`), but the section a reader would
check for "everything that leaves this machine" is stale relative to
what actually ships.

`GlobalpingReverseTraceService`/`HoihoService` reach
`api.globalping.io`/`api.hoiho.caida.org` unauthenticated, but both are
wrapped in `#if DEBUG`:
```
head -5 NMS/Services/GlobalpingReverseTraceService.swift
head -5 NMS/Services/HoihoService.swift
```
Compiled out of Release entirely — not a real-world exposure.

Optional Firewall Visibility (`NMS/Services/FWClient.swift`) sends this
Mac's public IP to a user-configured server for port-reachability
testing — off by default, requires pasting a server URL and token, real
opt-in friction, not silent.

### 2. Security

No hardcoded secrets:
```
grep -rniE "api_?key|secret|password|token|bearer" NMS/ --include="*.swift" | grep -viE "keychain"
```
Every hit is a doc comment, a UI label, or a legitimate runtime value
(a Bearer header built from a Keychain-stored token; a random
per-launch path token for the local diagnostic server).

Every subprocess call uses array-form arguments, confirmed directly:
```
sed -n '75,80p' NMS/Services/SNMPService.swift   # user-supplied community string, one array element
sed -n '24,29p' NMS/Services/DHCPLeaseService.swift
grep -rn "bin/sh\|bash -c\|/bin/bash" NMS/
```
No shell string construction anywhere in `NMS/` — matches the README's
own claim (lines 736-739).

Entitlements are minimal:
```
cat NMS/NMS.entitlements
```
Only `keychain-access-groups`; no broader permissions requested.
`Info.plist` usage-description strings
(`NMS.xcodeproj/project.pbxproj:434-436`) plainly and accurately
describe why local-network and location permissions are requested (ARP/
SNMP sweep; macOS treats Wi-Fi SSID as location-sensitive).

One disclosed-but-unresolved caveat, not a security hole: `PUNCHLIST.md`'s
2026-08-06 field-test entry documents a twice-reproduced, "not yet
root-caused" report of NMS itself appearing to disrupt the Mac's own
Wi-Fi. Worth knowing about; disclosed candidly rather than hidden.

### 3. Dependencies

```
grep -c "XCRemoteSwiftPackageReference\|XCSwiftPackageProductDependency" NMS.xcodeproj/project.pbxproj
```
No bundled third-party code. Apple system frameworks (SwiftUI,
SwiftData, Network, CoreLocation) plus subprocess calls to standard
macOS CLI tools (`ping`, `traceroute`, `arp`, `snmpget`, `lpstat`,
`ipconfig`), plus one optional, user-installed subprocess: `scamper`
(GPL-2.0, CAIDA), never bundled or linked — correctly avoids pulling
GPL obligations into the MIT-licensed app, per `README.md:884-893`.

### 4. Copyright/licensing

```
head -5 LICENSE
```
MIT License, © 2026 Paul Jorgensen — matches the README's claim.
Nothing read during this review looks copied from elsewhere; comments
consistently read as original reasoning tied to specific incidents
(field tests, bug reports), not lifted boilerplate.

### 5. Red flags

None that look obfuscated or undisclosed. The SaaS-monitoring/
ISP-identity README gap under Privacy above is the one concrete
finding — a documentation lag, not concealment: the destinations are
named in-code, gated by a discoverable, well-commented feature flag.

### 6. Trust signals

```
git log --oneline | wc -l              # 403 commits
git log --format="%ad" --date=short | tail -1   # 2026-07-22
```
Commit history is real and incremental — dated daily, specific
messages ("Revert FWKeychain's DEBUG-only file bypass now that signing
is stable"), not one unexplained dump.

```
wc -l PUNCHLIST.md BUGS.md
```
`PUNCHLIST.md` (4701 lines) and `BUGS.md` (1145 lines) read as genuine
engineering logs, including failures and explicitly-not-built ideas —
closer to the truth than marketing copy, same as `TRUST.md` itself
claims.

```
wc -l NMSTests/NMSTests.swift
cat .github/workflows/tests.yml
cat .github/workflows/gitleaks.yml
```
`NMSTests.swift` is substantial (2969 lines). CI runs it on every push/
PR with an explicit guard against a false-pass "0 tests" result
(`README.md:865-869`). `gitleaks.yml` scans full history
(`fetch-depth: 0`) on push, PR, and weekly, as claimed. `codeql.yml`
runs static analysis on PRs and weekly.

## Bottom line

No security or licensing red flags surfaced. Subprocess handling and
secret storage both check out against the README's own claims, and the
entitlements/permission strings match actual behavior. The one
actionable gap: `README.md`'s "Network activity and privacy" section
undercounts what leaves the machine by default — it should name
`SaaSStatusService`'s on-by-default third-party polling and
`ISPIdentityService`'s `rdap.org` lookup alongside the four items
already listed.
