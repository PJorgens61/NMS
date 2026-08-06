# Privacy/security review — 2026-08-03

**Commit reviewed:** `eb32dfe021a50f21c6a36b86c8882afbe06a59d`
**Reviewed by:** Claude (Sonnet 5), via Claude Code, at the repo owner's request.
**Reviewed for:** whether the app's public privacy/security claims ("no
account, no cloud, no telemetry — everything NMS displays is read
directly from this Mac") hold up against the actual source.

## Read this section first: what this document is, and isn't

This is **not a certification**. There is no accountable third party
standing behind this document the way there is behind a real audit —
no firm you could sue, no formal methodology anyone signed off on, no
cryptographic signature proving it came from an AI model rather than
being hand-written and labeled otherwise. Anthropic does not offer a
verification service for model output, and there is no way for a
reader of this file to confirm it wasn't edited after being generated.
Don't treat the byline above as proof of anything.

What *is* verifiable: everything below is reproducible. Every claim
cites a specific command and its output, or a specific file and line
number, against the exact commit hash above. Don't trust the
conclusions — rerun the commands. That's the actual trust mechanism
here, not the fact that an AI wrote the summary.

This review is static and manual: reading source code and project
configuration. It is **not** a substitute for:
- A real runtime network audit (Little Snitch / Wireshark capture of
  actual traffic while the app runs) — this review did not run the app.
  **Partially addressed 2026-08-06**: see
  [2026-08-06-runtime-network-audit.md](2026-08-06-runtime-network-audit.md)
  — a live capture that caught one finding no static read could: a
  user-added SaaS site check downloading a full page body instead of
  just checking reachability. Partial because it covered one ~65-second
  window, not a full poll cycle.
- A human security audit with formal methodology.
- A legal copyright/license clearance review — "no copied code was
  visible during a source read" is not the same as a legal opinion.
- Static analysis tooling (this was manual `grep`/reading, not a
  scanner) — it can miss things a dedicated tool would catch.

## Methodology

All commands below were run from the repo root at the commit above.
Anyone can rerun them — with an AI assistant, with plain `grep`, or by
hand — and should get matching results.

## Findings

### License and dependencies

- `LICENSE` is the MIT License, copyright 2026 Paul Jorgensen.
  ```
  head -5 LICENSE
  ```
- Zero third-party Swift Package Manager dependencies: no
  `Package.swift`, no `Package.resolved`, and no
  `XCRemoteSwiftPackageReference`/`XCSwiftPackageProductDependency`
  entries in `NMS.xcodeproj/project.pbxproj`.
  ```
  find . -iname "Package.swift" -o -iname "Package.resolved"
  grep -c "XCRemoteSwiftPackageReference\|XCSwiftPackageProductDependency" NMS.xcodeproj/project.pbxproj
  ```
  This confirms the "no dependencies, not one third-party package"
  claim made in the app's own tooling section and on the website.

### Network behavior

Every hardcoded URL/host in the Swift source (`grep -rhoE
'https?://[a-zA-Z0-9./_-]+' NMS --include="*.swift"`), categorized:

- **Apple's own infrastructure:** `captive.apple.com` (standard
  captive-portal check), `speed.cloudflare.com/__up`/`__down` (the
  target Apple's own `networkQuality` binary uses for its bufferbloat
  test — not an NMS-chosen endpoint).
- **Public IP lookup:** `api.ipify.org`.
- **ISP identification:** `rdap.org/ip/` — public RDAP registry lookup,
  no user data sent beyond the IP being looked up.
- **SaaS status pages** (Slack, GitHub, Cloudflare, Atlassian/Trello,
  Google Cloud, OpenAI, Anthropic, Zendesk, Dropbox, Notion, Figma,
  DocuSign, Asana, HubSpot, Discord, Sonic): all public
  `status.<vendor>.com`-style incident-feed URLs, read-only GET
  requests against public JSON, no credentials or user data attached.
- **ISP outage-map links** (AT&T, Xfinity, MonkeyBrains): shown as
  "learn more"-style links, not fetched by the app itself.
- Two `example.com` references are a `TextField` placeholder string
  (`PreferencesView.swift:259`) and a fault-injection test fixture used
  only by the debug-only `FailureInjector.swift:290` tool — neither is
  live traffic.

No endpoint found sends device identifiers, IP addresses, network
names, or any other collected data *to* a third party — every request
above is either a read of public data or a lookup of the user's own
public IP for the user's own benefit (displayed back to them).

### No telemetry or analytics

```
grep -rniE "firebase|sentry|mixpanel|amplitude|crashlytics|segment\.io|bugsnag|appcenter" NMS --include="*.swift"
```
Zero matches. No crash-reporting or analytics SDK of any kind is
present in the source.

### Shell-out safety

The app shells out to standard macOS system binaries only:
`/sbin/ping`, `/usr/sbin/arp`, `/usr/sbin/traceroute`, `/usr/bin/dig`,
`/usr/bin/snmpget`, `/usr/sbin/ipconfig`, `/usr/sbin/networksetup`,
`/usr/bin/lpstat`, `/usr/bin/networkQuality` (Apple's own tool).

```
grep -rhoE '"/usr/[a-zA-Z/]+"|"/sbin/[a-zA-Z/]+"' NMS/Services --include="*.swift" | sort -u
```

All invocations use `Process()` with an argument array
(`process.arguments = [...]`), not a shell interpreter — there is no
`/bin/sh -c` or `/bin/bash -c` string-concatenation pattern anywhere in
`NMS/Services`, which is the actual command-injection risk pattern.
The `-c` flags that do appear (e.g. `ConnectivityService.swift:26`,
`SNMPService.swift:79`) are `ping`'s count flag and `snmpget`'s
community-string flag, respectively — command-line arguments, not
shell metacharacters.

### App Sandbox: explicitly disabled

`ENABLE_APP_SANDBOX = NO` in `NMS.xcodeproj/project.pbxproj` (both
Debug and Release configurations), and no `.entitlements` file exists
in the repo. **This is a real, worth-knowing fact, not a bug**: the
app needs to shell out to `ping`/`arp`/`traceroute`/`snmpget` and read
raw ARP/DHCP data, which the App Sandbox restricts. But it does mean
NMS runs with the same filesystem/network access as any other
unsandboxed Mac app you grant permission to run — worth stating
plainly rather than letting "open source" imply "sandboxed" by
association.

### Local Stress Test: scoped and gated

`WiFiStressTestService.runBurst(host:...)` takes a `host` parameter,
but it's only ever called
(`ContentView+Window.swift:104,121`) with
`viewModel.currentInterface?.routerAddress` — the Mac's own
auto-detected default gateway, not free-form user input, and not
reachable at all unless `wifiStressTest.hasConfirmedBefore` is true,
which requires the user to pass through a confirmation dialog first
(`ContentView+Window.swift:98-107`). It cannot be pointed at an
arbitrary external host through the UI as shipped.

### LAN discovery: passive, not active scanning

`LANDiscoveryService.swift` reads the kernel's existing ARP cache
(`arp -a`) rather than actively probing the subnet with its own
packets — per the file's own header comment, "no special entitlements
needed, and it's near-instant." It surfaces devices the OS already
knows about; it doesn't send traffic to discover new ones.

### SNMP community strings: not Keychain-stored, and that's deliberate

`SNMPViewModel.swift:34` has an explicit comment: community strings
are "deliberately not treated as Keychain-grade secrets." This is
worth surfacing rather than treating as a gap — SNMP community strings
default to widely-known values (`public`/`private`) industry-wide and
aren't credentials in the way a password is, so storing them in
`UserDefaults` rather than Keychain is a reasoned tradeoff, not an
oversight.

### Google Cloud sign-in: not present in this build

The app has an in-progress feature (tracked separately, not part of
this commit) to add "Sign in with Google" for GCP service-health
monitoring, gated on the repo owner registering an OAuth client with
Google — a manual step not yet done. Confirmed via source search:
```
grep -rln "GoogleCloud\|OAuth\|ASWebAuthenticationSession" NMS --include="*.swift"
```
returns zero matches at this commit. **This review's "no account, no
cloud" findings apply only up to this commit** — once that feature
ships, it will introduce a real OAuth network flow and Keychain usage
that a future review needs to cover specifically (what scopes are
requested, what's stored, what's transmitted).

## Suggested next step

If this is meant to become a recurring part of the release process
(one review per tagged release, tied to that release's exact commit),
it should be turned into a checklist/script that re-runs these same
greps automatically and flags anything that doesn't match the previous
review — rather than a fresh manual pass each time. Not built yet;
this file is the first instance of the process, written to make that
follow-up easy to scope.

**Implemented 2026-08-06**: `script/privacy-security-check.sh` re-runs
every check above (plus a few more, added for the 2026-08-06 trust
assessment — see `docs/reviews/2026-08-06-trust-assessment.md`) and
diffs the output against `script/privacy-security-baseline.txt`, the
snapshot from that review. Run it with no arguments before a release;
a clean diff means nothing privacy/security-relevant changed since the
last reviewed commit, and any diff is exactly the delta worth a fresh
look. `--update-baseline` records new output as the baseline once a
review has actually confirmed it's fine.
