# Runtime network audit — 2026-08-06

**Commit reviewed:** `3d2e1998b32cead0b129723bf6e868f0b3a08640`
**App instance audited:** a live, already-running Debug build
(`~/Library/Developer/Xcode/DerivedData/NMS-.../Build/Products/Debug/NMS.app`,
PID `16796`), not a fresh launch built for this audit.
**Performed by:** Claude (Sonnet 5), via Claude Code, at the repo
owner's request.
**Performed for:** the one gap both prior review docs name explicitly
— [2026-08-03-privacy-security-review.md](2026-08-03-privacy-security-review.md)
and [2026-08-06-trust-assessment.md](2026-08-06-trust-assessment.md)
are both static source reads and say so plainly: neither is "a real
runtime network audit (Little Snitch / Wireshark capture of actual
traffic while the app runs)." This is that audit.

## Read this section first: what this document is, and isn't

Same non-certification caveat as the other two review docs — no
accountable third party, no way to confirm this wasn't edited after
being generated, don't trust the byline, verify instead.

What's different from the other two: **this one is not reproducible
the way a source-code grep is.** A static review run twice against the
same commit returns identical output. A live capture run twice returns
different traffic, because it depends on what the app happens to be
doing at that exact moment — which SaaS-status poll cycle is mid-flight,
which connections are still warm, whether Wi-Fi conditions triggered a
recheck. Treat the *methodology* below as reproducible (anyone can run
these same commands against their own running instance); treat the
*specific findings* as a snapshot of one ~65-second window on one Mac,
not an exhaustive or repeatable enumeration.

This also did **not** cover a full poll cycle. `SaaSMonitoringViewModel`
polls every 300 seconds (`SaaSMonitoringViewModel.swift:90`); this
capture ran for roughly 65. Endpoints from the curated list that don't
appear in the Findings below were very likely just outside the
capture window, not confirmed absent — the source-level enumeration in
the two prior reviews remains the actual evidence for what the full
list is.

## Methodology

No Wireshark GUI was installed or needed — `tcpdump` and `nettop` cover
packet-level and per-process network accounting respectively, and
neither required `sudo`: this account is a member of the `access_bpf`
group, which macOS grants read/write on `/dev/bpf*` without root.

```
which tcpdump                          # /usr/sbin/tcpdump, ships with macOS
id -Gn                                 # includes access_bpf
ls -la /dev/bpf0                       # crw-rw---- root:access_bpf
pgrep -fl "NMS.app"                    # confirmed a running instance, PID 16796
```

1. An immediate connection snapshot via `lsof -i -a -p 16796 -n -P`.
2. A ~65-second live window via `nettop -p 16796 -x -J bytes_in,bytes_out`,
   bounded with a background job + `kill` rather than GNU `timeout`
   (not installed on this Mac by default).
3. Every observed remote IP identified via reverse DNS (`dig -x`) and
   cross-checked by forward-resolving every domain named in
   `SaaSStatusService.swift`, `ISPIdentityService.swift`, and the other
   WAN-reaching services, to rule out false attribution from shared
   CDN IP pools.
4. Where an IP didn't match any statically-known domain, correlated
   against the app's own local debug log
   (`~/Library/Logs/NMS/ui-state.log` — `UIStateLogger`, local-only,
   compiled out in Release, but present because this is a Debug build)
   and its actual stored preferences
   (`~/Library/Preferences/Thistle.NMS.plist`, read directly with
   `plistlib` since `defaults read` truncates long values for display).

## Findings

### Matched the documented list exactly

- **`api.ipify.org`** (`104.26.12.205:443`, TCP, established) — matches
  `PublicIPService`'s background-timer public-IP lookup exactly.
- **Apple's captive-portal infrastructure** (`17.253.5.140:80` /
  `17.253.17.206:80`, TCP, **plain HTTP**) — this is the one claim
  worth a live check on its own merits (README.md:710-714 says TLS
  would defeat the point of the check). Confirmed live, not just
  claimed: genuinely port 80, no TLS, in an actual captured connection.
- **`www.notion-status.com`** (`76.76.21.98:443`, TCP, two connections)
  — one of the curated SaaS Status entries
  (`SaaSStatusService.swift:109`). Fronted by Vercel
  (`cname.vercel-dns.com`), confirmed by forward-resolving the domain
  and matching the IP exactly, not just "some Vercel IP."

### Found live, not visible to a source-only read

- **`108.139.2.90:443`, UDP (QUIC/HTTP3), AWS CloudFront** — 337,680
  bytes received, already fully transferred before this capture
  started (byte counters were identical at the start and end of the
  65-second window — no live transfer observed, just an idle,
  already-loaded connection). This IP matched none of the ~20
  documented WAN domains when each was forward-resolved individually.

  Traced via `ui-state.log`'s `fieldTest.frame.saasStatus.row.*` event
  kinds, which listed a row named **"Amazon"** — not present anywhere
  in `SaaSStatusService.swift`'s hardcoded `monitoredServices` list.
  Reading `Thistle.NMS.plist` directly confirmed why: `Amazon` is a
  **user-added site** (`FeatureFlags.userAddedSaaSSites`,
  `FeatureUserAddedSaaSSites` in `UserDefaults`) — `{"url":
  "https://www.amazon.com", "nickname": "Amazon"}` — added by hand via
  Preferences at some point before this audit, not shipped or
  suggested by the app.

  This isn't a privacy problem — it's a URL the machine's own user
  typed in, no credentials involved, and `FeatureFlags.swift`'s own
  comments already document this exact mechanism as "checked for plain
  reachability rather than a real vendor status page." But it
  surfaced a real behavioral gap in what the docs say about that
  mechanism's *cost*, not its *destination*:

  `checkUserAddedSites` (`SaaSMonitoringViewModel.swift:306`) reuses
  `SaaSStatusService.checkStatus` via the `.reachabilityOnly` shape.
  That path (`SaaSStatusService.swift:129-149`) issues a plain `GET`
  — `URLRequest(url:)` defaults to `GET`, nothing overrides it to
  `HEAD` — via `URLSession.shared.data(for:)`, which downloads the
  **entire response body** before the `.reachabilityOnly` branch
  discards it unread and keeps only the status code. For a JSON status
  endpoint (the curated list) that's a few KB either way. For a real
  webpage like `amazon.com`'s homepage, that's the 337KB observed here
  — real bandwidth, spent every 5-minute poll cycle, for a check that
  only ever looks at the HTTP status code. `SaaSMonitoring` is on by
  default (`FeatureFlags.swift`'s `saasMonitoring` exception), so this
  runs unattended for anyone who has added even one heavy site.

### Also observed, expected and consistent with configuration

- Live SNMP LAN polling (`SNMPViewModel.devices` log entries — router,
  switch, two APs, a printer) — consistent with `FeatureSNMPDevices`
  being explicitly enabled on this Mac (off by default; this machine
  has it on). LAN-only, as documented — no WAN traffic observed
  attributable to SNMP.

## Suggested next step

`checkUserAddedSites`'s reachability check could use `HEAD` instead of
`GET` (or set `URLSession`'s response-body handling to discard early)
— same signal (status code), without downloading a page body nobody
reads. Worth a small fix given `saasMonitoring` defaults on and this
runs unattended every 5 minutes.

Separately: this audit covered one ~65-second window. A capture
spanning a full 300-second poll cycle (or several) would let the
curated-list findings from the static reviews be confirmed the same
live way the captive-portal and ipify findings were here — not done in
this pass.

**Closed 2026-08-06**: see
[2026-08-06-expanded-trust-prompt-run.md](2026-08-06-expanded-trust-prompt-run.md)
— a later spot-check caught a full SaaS Status poll round live
(~15 simultaneous connections, each matched by reverse DNS against
this doc's own forward-resolved IPs), confirming the curated-list
destinations the same live way this doc confirmed ipify/captive.apple.com.
