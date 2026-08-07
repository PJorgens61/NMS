# 2026-08-06 — Factual code inventory

Produced by running the prompt in `INVENTORY-PROMPT.md` (a file supplied
outside this repo, at `~/Downloads/files/INVENTORY-PROMPT.md`) against
this codebase as of commit `dc96434`. Per that prompt's own framing:
this is a factual manifest only. It does not assess risk, does not
recommend anything, and does not judge whether existing documentation
(README.md, TRUST.md) is adequate — it only checks their claims against
code. Every README/TRUST.md statement quoted below is treated as a claim
to verify, not as a source of truth. A separate session, without this
repo's context, is expected to do the interpretation (feeding into
`LICENSING-AND-TERMS.md`).

Research for the five sections below was performed by four parallel
read-only agents, each instructed to cite `file:line` for every claim;
this document assembles their findings. Where a finding could not be
determined, that is stated explicitly along with what was checked,
rather than inferred from prose.

---

## 1. Outbound network endpoints

### Endpoint table

| Host | Source file:line / symbol | Protocol | Trigger | Cadence | Bytes/invocation | Data disclosed to host operator | Gated by |
|---|---|---|---|---|---|---|---|
| `api.ipify.org` | `NMS/Services/PublicIPService.swift:14,16-26` | HTTPS GET | Automatic | 300s timer (`PublicIPViewModel.swift:18`), plus at launch and on network/topology change (`NMSApp.swift:348`) | ~0 request / ~10-15B response | Source IP (inherent to any HTTP request — this is how the app learns its own public IP) | Unconditional |
| `captive.apple.com` | `NMS/Services/HTTPCheckService.swift:15,18-42` | HTTP (plain, deliberately not TLS) GET | Automatic | Same cadence as connectivity checks: 30s (`ConnectivityViewModel.swift:55`), accelerated to 5s while any critical check is failing (`:61,462,479-481`) | Bare GET / small fixed HTML | Source IP inherent; plain HTTP means the request is visible in cleartext on-path | Unconditional |
| Randomized `nms-check-<uuid>.apple.com` subdomain | `NMS/Services/DNSResolutionService.swift:50,75-106` | DNS (`getaddrinfo`, via system resolver — never resolves, by design) | Automatic | Same 30s/5s cadence, from `ConnectivityViewModel.runDNSCheck` (`:329-342`) | ~100-200B one query/response | Source IP visible to the configured DNS resolver (not to Apple, since it never resolves) | Unconditional |
| 19 SaaS status-page APIs (`slack-status.com`, `status.claude.com`, `status.openai.com`, `status.atlassian.com` ×2, `status.zendesk.com`, `www.zoomstatus.com`, `status.asana.com`, `www.notion-status.com`, `status.dropbox.com`, `discordstatus.com`, `www.githubstatus.com`, `www.cloudflarestatus.com`, `status.figma.com`, `status.hubspot.com`, `status.docusign.com`, `status.cloud.google.com`, `www.google.com`) | `NMS/Services/SaaSStatusService.swift:101-126,129-167` | HTTPS GET (JSON) | Automatic | 300s timer (`SaaSMonitoringViewModel.swift:90,138`) | Low single-digit KB each × 19 requests/round | Source IP inherent; plain unauthenticated GET, no other identifying data | `FeatureFlags.saasMonitoring` (`FeatureFlags.swift:98-101`) — **on by default**, the one documented exception to "everything off by default" |
| Arbitrary user-added site URLs | `NMS/ViewModels/SaaSMonitoringViewModel.swift:306-340` (reachability-only, via `SaaSStatusService`) | HTTPS/HTTP GET | Automatic once a user adds a site | Same 300s timer | Bare GET, status only | Source IP inherent | `saasMonitoring` on + `FeatureFlags.userAddedSaaSSites` non-empty (`FeatureFlags.swift:174-182`) |
| `rdap.org/ip/<publicIP>` (redirects to the actual regional RIR) | `NMS/Services/ISPIdentityService.swift:21-39` | HTTPS GET | **Automatic** — see README discrepancy below | Called at launch (`NMSApp.swift:172`), on topology change (`:343`), on public-IP change (`:465`) — no timer, no button | Few KB response | The Mac's own public IP is the lookup key — IP disclosure is the entire point of the call | Unconditional |
| `speed.cloudflare.com` (`__down`/`__up`) | `NMS/Services/NetworkQualityService.swift:54-57,106-118` | HTTPS GET (download) / POST (upload) | User-initiated — "Run Speed Test" (`NMS/Views/SpeedTestTile.swift:32-33`) | On demand only | 2MB probe, escalating to 25MB per direction if fast (`:33-34`) — up to ~50MB total | Source IP inherent; upload body is all-zero bytes (`:139`), no metadata | Unconditional; never automatic (file's own header comment) |
| Apple `networkQuality` test servers (host chosen internally by the OS tool, not by NMS) | `NMS/Services/AppleNetworkQualityService.swift:14,154-188,207-224` | HTTPS/TCP/TLS | `measure()`: user-initiated button (`AppleNetworkQualityTile.swift:22-23`). `measureQuick()`: user-initiated (`QuickCheckRow.swift:40`) **and** automatic on recognizing a previously-seen network (`NMSApp.swift:576-577`) | On demand for `measure()`; automatic `measureQuick()` fires once per network-recognition event | `measure()`: **1-2GB per direction**, confirmed live in the file's own comment (`:91-99`). `measureQuick()`: **~880MB** in 5s (`:190-206`) | Source IP inherent; verbose `-v` report captured but only shown locally, never sent anywhere | Manual paths unconditional. Automatic `measureQuick()`: `FeatureFlags.autoBaselineNetworkQuality` (`FeatureFlags.swift:266-268`) — **off by default** |
| `1.1.1.1` (Cloudflare resolver, via `dig`, bypassing the system resolver) | `NMS/Services/DDNSResolutionService.swift:50-51,63-101` | DNS | Automatic | Timer, interval = `FeatureFlags.ddnsCheckInterval`, default 300s, user-selectable to 60s (`DDNSViewModel.swift:107-114`; `FeatureFlags.swift:248-251`; `DDNSHostnamesSection.swift:60-63`) | ~100-200B per configured hostname | The user's own configured DDNS hostname is queried against `1.1.1.1`; source IP inherent | Non-empty `FeatureFlags.ddnsHostnames` (no dedicated on/off flag) **and** current network marked home (`DDNSViewModel.swift:171-174`) |
| User-configured DDNS hostnames (same `dig @1.1.1.1` call) | same file | DNS | same | same | same | same | same |
| `api.globalping.io/v1/measurements` | `NMS/Services/GlobalpingReverseTraceService.swift:40,115-140,164-193` | HTTPS POST + polling GET | User-initiated — "Path Discovery…" (`NMS/Views/DebugToolsView.swift:71-81,152-276`) | On demand; polls up to 6× at 2s (`:67-73`) | POST: small JSON. Response: tens of KB (up to `probeCount`=5 probes' full hop lists) | The Mac's own public IP is sent as the traceroute **target** to Globalping's unauthenticated API — Globalping and its third-party probe operators learn that IP and trace toward it | **DEBUG builds only** (`:3,316`; `DebugToolsView.swift:3,366`) |
| `api.hoiho.caida.org/lookups` | `NMS/Services/HoihoService.swift:28,80-100` | HTTPS POST | User-initiated, same Path Discovery flow (`DebugToolsView.swift:257`) | On demand, one bulk call per run | JSON array of deduplicated hop hostnames in the body / small JSON response | Router/ISP-infrastructure **hostnames** seen in that trace, sent to CAIDA — reveals which ISP/topology is being investigated, not directly the user's own identity | **DEBUG builds only** (`:3,102`), reached only from DEBUG-only `DebugToolsView` |
| User-configured FW server (no built-in default host) | `NMS/Services/FWClient.swift:83-99,101-134` | HTTPS POST/GET, Bearer-token authenticated (`:189`) | **Automatic** (scheduled + event-triggered) and user-initiated | Daily timer (`FirewallVisibilityViewModel.swift:40,81-86`); also on-demand button (`:121-144`) and on SNMP-detected router restart/software change (`:157-160`) | POST: list of up to 26 ports (`:50-56`) against the Mac's public IP; small JSON response | The server operator is asked to actively port-scan the user's public IP and/or reverse-traceroute to it — discloses open/closed ports plus the Bearer device token | `FeatureFlags.firewallVisibility` (`FeatureFlags.swift:77-79`) — **off by default**, plus configured server URL + Keychain token + current network marked home. **No `#if DEBUG` guard — reachable in Release** once configured |
| Same FW server, reverse-trace call | `NMS/Services/FWTraceService.swift:31-43`, delegates to `FWClient` | HTTPS POST/GET | User-initiated, same Path Discovery flow (`DebugToolsView.swift:176-180`) | On demand, polls up to 30× | Small JSON | Same as above, naming the Mac's public IP as `target` | **DEBUG builds only** (`:3,79`) **and** `firewallVisibility` + configured server/token |
| `1.1.1.1` (fixed traceroute/ping target) + every intermediate hop | `NMS/Services/ConnectivityService.swift:22-54`, `NMS/Services/TracerouteService.swift:24-92` (`ConnectivityViewModel.swift:70`, `TracerouteViewModel.swift:64`) | ICMP | Automatic | Ping: 30s/5s connectivity cadence. Traceroute: 600s (`TracerouteViewModel.swift:75`), plus re-run on reachability transitions | Standard small ICMP packets | Source IP inherent to ICMP, same as any manual ping/traceroute | Unconditional |
| Two dynamically-determined addresses (traceroute-hop candidates) | `NMS/Services/ScamperService.swift:134-166` (`scamper dealias -m ally`) | ICMP echo probes, via separately-installed `scamper` | User-initiated, same Path Discovery flow (`DebugToolsView.swift:216-233`) | On demand, once per candidate pair per run | Small ICMP probes | Source IP inherent; the two probed addresses are real internet hosts (typically ISP edge-router candidates) — no NMS metadata sent | **DEBUG builds only** (`:3,241`); additionally requires separately-installed `scamper` + a one-time root/setuid step (`:80-118`) |
| `cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js` | `NMS/Services/LocalDiagnosticServer.swift:799` | HTTPS, fetched by the user's browser, not the NMS process | Indirect — on page load of a generated diagnostic HTML page | Once per page load | Not determined (typically hundreds of KB–low MB for that library; not measured in code) | The browser's IP and a request for this JS file, standard CDN request — NMS itself never contacts jsdelivr | **DEBUG builds only** (`LocalDiagnosticServer.swift:4,882`) |

Not counted as an "outbound"/internet endpoint: `DeviceWebDetectionService.swift:82-98` makes HTTP(S) requests to **LAN-only** addresses (SNMP-discovered local devices), automatically as part of `SNMPViewModel`'s 60s poll (`SNMPViewModel.swift:104`), gated by `FeatureFlags.snmpDevices` (off by default). It never leaves the local network.

### Endpoints reached only indirectly

- **Traceroute intermediate hops** — every router between this Mac and `1.1.1.1` receives/responds to ICMP TTL-exceeded packets as a side effect; NMS never opens a connection to them.
- **Globalping's probe network** — NMS connects only to `api.globalping.io`; Globalping's own third-party-operated probe nodes worldwide then independently trace *toward the user's public IP* from vantage points NMS never contacts directly (filtered only by a `locations` string, default `["USA"]`, `GlobalpingReverseTraceServiceAssets/config.json` via `GlobalpingReverseTraceService.swift:52-56`).
- **FW server's own scan/trace of the user's public IP** — NMS connects only to the configured FW server; that server independently probes the user's own public IP from its own network location.
- **DNS root/TLD/authoritative servers** — both the randomized-subdomain probe and the DDNS `dig @1.1.1.1` lookups fan out from the queried resolver to authoritative infrastructure NMS never contacts directly.
- **rdap.org's redirect target** — `ISPIdentityService.swift:26` hits `rdap.org`, which redirects to whichever regional registry (ARIN/RIPE/APNIC/LACNIC/AFRINIC) holds the record; `URLSession` follows this automatically, so the effective destination varies by IP.

### Endpoints reachable only in DEBUG builds

`api.globalping.io`, `api.hoiho.caida.org`, the FW server *specifically via* the reverse-trace call (`FWTraceService`), arbitrary scamper-probed addresses, `cdn.jsdelivr.net` (browser-fetched from a DEBUG-only exported page). Note: the FW server's *scheduled/manual scan* path (`FWClient`/`FirewallVisibilityViewModel`) has **no** DEBUG guard and is reachable in Release once configured.

### Endpoints reachable only behind a feature flag that defaults OFF

- `FeatureFlags.firewallVisibility` (off) — all FW server traffic.
- `FeatureFlags.autoBaselineNetworkQuality` (off) — the automatic ~880MB `measureQuick()` firing; the manual button path is unconditional.
- `FeatureFlags.snmpDevices` (off) — gates the LAN-only web probing noted above (not an internet endpoint).
- **Exception**: `FeatureFlags.saasMonitoring` defaults **on** — the 19-host SaaS polling and user-added sites are reachable out of the box.
- DDNS resolution has no dedicated flag at all — gated purely by whether `ddnsHostnames` is non-empty.

### Comparison against README.md

README's "Network activity and privacy" section (`README.md:695-750`) states *"Six things reach beyond the local network, none of them silent"*, naming: `api.ipify.org`, `captive.apple.com`, the randomized DNS probe, SaaS Status monitoring, Speed Test/Network Quality, and ISP identification (`rdap.org`). It separately mentions ICMP ping/traceroute to `1.1.1.1`.

**1. Endpoints found in code but not described in README's network-activity section:**
- DDNS resolution to `1.1.1.1` and user-configured hostnames (`DDNSResolutionService.swift`) — no "DDNS" mention anywhere in README.
- Firewall Visibility / FW server traffic (`FWClient.swift`, `FirewallVisibilityViewModel.swift`, `FWTraceService.swift`) — no "Firewall" mention in README.
- Globalping (`api.globalping.io`) — no mention.
- Hoiho/CAIDA (`api.hoiho.caida.org`) — no mention.
- Scamper's ICMP probes to dynamically-determined internet hosts — scamper is mentioned only in README's License section (`:910`) as a licensing note, not as something that sends probes.
- `cdn.jsdelivr.net` — no mention.
- README's "Debug tooling (DEBUG builds only)" section (`:444-490`) describes UI-state logging, store dumps, and failure injection, but doesn't mention that Path Discovery and Firewall Visibility reach the internet at all.

**2. Endpoints README describes that could not be found in code:** none — every host README names in that section was located in code exactly as described.

**Additional discrepancies noted (factual, not judgment):**
- README states ISP identification is *"user-triggered only, when you ask NMS to identify the ISP behind your current public IP"* (`:732-735`). In code, `ISPIdentityViewModel.identify(ip:)` fires automatically at launch, on topology change, and on public-IP change (`NMSApp.swift:172,343,463-466`) — no button in `NMS/Views` calls it; the only view usages found are read-only display (`NetworkTile.swift:373,393,407`).
- README states Speed Test and Network Quality together *"move real data (up to ~50MB)"* (`:730-731`). Code shows Apple's `networkQuality` (`measure()`) moves **1-2GB per direction** (`AppleNetworkQualityService.swift:91-99`) and `measureQuick()` moves **~880MB** in 5s (`:190-206`) — both far above "~50MB." Only the Cloudflare path (`NetworkQualityService.swift`) matches "~50MB." The in-app tooltip is more accurate here: `AppleNetworkQualityTile.swift:43` reads "uses your data plan — often 1+ GB on a fast connection, ~30s."

---

## 2. Third-party code and licenses

### Swift Package Manager / CocoaPods / Carthage

- `grep -n "XCRemoteSwiftPackageReference\|XCSwiftPackageProductDependency\|repositoryURL"` over `project.pbxproj` → no matches. All three targets' `packageProductDependencies` arrays are explicitly empty (`project.pbxproj:112,135,158`).
- No `Package.resolved` anywhere in the repo (including `NMS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/`, which exists but is empty).
- No `Podfile*`/`Cartfile*`/`Pods/` anywhere.

**Zero SwiftPM/CocoaPods/Carthage dependencies declared anywhere in the project.**

### Vendored source

- `grep -rl "Copyright\|SPDX-License\|Licensed under\|All rights reserved"` across `NMS/`, `NMSTests/`, `NMSUITests/` → no matches; no Swift file carries an upstream copyright header.
- `ScamperService.swift` and `HoihoService.swift` contain no vendored code/binary — pure subprocess-invocation and pure `URLSession` client respectively.
- `NMS/Services/LocalDiagnosticServerAssets/` contains three small app-authored files (`topology-colors.json`, a 7-line `mermaid-init.js` config, `style.css`); the actual Mermaid.js library is not vendored — fetched at runtime from jsDelivr (`LocalDiagnosticServer.swift:799`).
- `NMS/Services/GlobalpingReverseTraceServiceAssets/` contains `config.json` and an app-authored README note — no vendored code.

**No vendored/upstream-copied source files found anywhere in the repo.**

### Linked frameworks

`project.pbxproj` has three `PBXFrameworksBuildPhase` entries (one per target), all with an empty `files = ();` array; there is no `PBXBuildFile` section at all. The project uses `PBXFileSystemSynchronizedRootGroup` (folder-reference sync), so frameworks are pulled in only via Swift `import`, never an explicit link entry.

Modules actually imported (`grep -rhn "^import "`): **Foundation, SwiftUI, AppKit, CoreGraphics, CoreLocation, CoreWLAN, Darwin, Network, Security, SwiftData, SystemConfiguration** (all Apple system frameworks), plus **Testing**/**XCTest** in the test targets only. No third-party framework is imported or linked.

### External binaries invoked as subprocesses

| Binary (exact path) | File:line | Ships with macOS? | Upstream license | Invocation shape |
|---|---|---|---|---|
| `/sbin/ping` | `ConnectivityService.swift:25-26` | Yes | Not determined (BSD userland tool, no bundled notice) | `Process` exec, `["-c","1","-t","<timeout>", host]` |
| `/sbin/ping` | `WiFiStressTestService.swift:70-71` | Yes | Not determined | `Process` exec, `["-i","<interval>","-c","<count>","-s","1472","-D", host]` |
| `/usr/sbin/traceroute` | `TracerouteService.swift:34-35` | Yes (ships setuid-root) | Not determined | `Process` exec, `["-m","<maxHops>","-n","-q","1","-w","<timeout>", host]` |
| `/usr/bin/dig` | `DDNSResolutionService.swift:50,68-70` | Yes | Not determined | `Process` exec, `["@1.1.1.1", hostname, "A", "+short", "+time=<n>", "+tries=1"]` |
| `/usr/sbin/ipconfig` | `DHCPLeaseService.swift:11,28` | Yes | Not determined | `Process` exec, `["getpacket", interface]` |
| `/usr/sbin/scutil` | `DHCPLeaseService.swift:163-164` | Yes | Not determined | `Process` exec, `["--renew", interface]` |
| `/usr/sbin/networksetup` | `EthernetLinkService.swift:16,40` | Yes | Not determined | `Process` exec, `["-getMedia", device]` |
| `/usr/sbin/arp` | `LANDiscoveryService.swift:14,30` | Yes | Not determined | `Process` exec, `["-n","-a"]` |
| `/usr/bin/snmpget` | `SNMPService.swift:25,79` | Yes (net-snmp, ships by default) | Not determined here (upstream net-snmp is BSD-style; no notice file in repo) | `Process` exec, `["-v2c","-c",community,"-t","1","-r","1","-Oqvt", ip] + oids` |
| `/usr/bin/lpstat` | `PrinterDiscoveryService.swift:19,51` | Yes (CUPS) | Not determined | `Process` exec, `["-v"]` |
| `/usr/bin/networkQuality` | `AppleNetworkQualityService.swift:14,236-237` | Yes (Apple first-party) | N/A — Apple | `Process` exec, args set dynamically |
| `scamper` (checked at `/opt/homebrew/bin/scamper`, `/usr/local/bin/scamper`) | `ScamperService.swift:39,143-146` | **No** — separately installed via Homebrew | **GPL-2.0-only** — stated in code comment (`:15`) and UI tooltip (`DebugToolsView.swift:133`) | `Process` exec only, `#if DEBUG`-gated; `["-O","json","-I","dealias -O inseq -m ally -p '-P icmp-echo' <A> <B>"]` |

No hardcoded `netstat`, `ifconfig`, `system_profiler`, or `rrdtool` invocations found anywhere in `NMS/Services/*.swift`. `rrdtool` is discussed in `DESIGN-NOTES.md` (`:1782-1884,3017-3029`) as a dependency considered and explicitly rejected — it is not invoked anywhere in the codebase.

**Linking/dlopen:** `grep -rn "dlopen"` across the repo → no matches. Every binary above is invoked exclusively via `Process` (confirmed by reading each call site: `executableURL =`, `arguments =`, `run()`, `waitUntilExit()`). None are dynamically loaded or linked in-process.

### Subprocess output copied into app output

- **Traceroute**: not embedded verbatim — `TracerouteService.parse()` (`:65-88`) extracts only structured fields via regex into `TracerouteHop`.
- **DHCP**: parsed into structured `DHCPLeaseInfo`. On parse-failure only, the capped raw stdout (4096-char cap via `UntrustedText.capped`, `UntrustedText.swift:15,23-26`) is written to the local debug log at `DHCPLeaseService.swift:70` — a diagnostic log, not a user-facing export.
- **SNMP**: `sysDescr`/`sysName` (single device-supplied fields, capped) are displayed directly in the UI: `SNMPDevicesTile.swift:109` renders `sysDescr` verbatim with no line limit, per its own comment ("a raw SNMP-provided string, no length guarantee ... wraps to as many lines as it needs instead of truncating").
- **Ping**: stdout is read but no downstream code path renders it raw; both callers convert to numeric latency values.
- **Path Discovery HTML export** (`LocalDiagnosticServer.exportReverseTraceHTML`, `:164-198`): built from structured/typed data (hop objects, geo hints, scamper verdicts), not raw subprocess text.
- **Scamper**: output is newline-delimited JSON decoded via `Decodable` (`:176-185`); only a boolean/nil verdict reaches callers — no raw text.

### LICENSE (repo root, verbatim)

Copyright line: `Copyright (c) 2026 Paul Jorgensen`

```
MIT License

Copyright (c) 2026 Paul Jorgensen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Other license/notice/attribution files

`find . -not -path '*/.git*' \( -iname "*license*" -o -iname "*notice*" -o -iname "COPYING*" \)` → only `./LICENSE`. No `NOTICE`, `COPYING`, or per-directory attribution file exists anywhere else, including under `NMS/Services/`, `docs/`, `script/`.

No standalone `Info.plist` exists (`GENERATE_INFOPLIST_FILE = YES`). `INFOPLIST_KEY_NSHumanReadableCopyright = ""` (empty) in both configs (`project.pbxproj:433,478`). `NMS/NMS.entitlements` contains only `keychain-access-groups` — no license reference.

### External APIs referenced (for cross-reference with §1; not code dependencies)

`api.globalping.io`, `api.hoiho.caida.org`, `api.ipify.org`, `cdn.jsdelivr.net`, `rdap.org`, `speed.cloudflare.com`, the 19 SaaS status hosts, and ISP marketing/status pages referenced elsewhere in code (`www.att.com`, `www.cox.com`, `www.monkeybrains.net`, `www.spectrum.net`, `www.xfinity.com`), plus `www.google.com` and `example.com`.

---

## 3. Data at rest

### SwiftData persisted models

Schema registered in `NMSApp.swift:796-810` (`makeModelContainer()`): 13 `@Model` classes — `NetworkSnapshot`, `DiscoveredDeviceRecord`, `ConnectivityCheckRecord`, `KnownNetwork`, `PublicIPRecord`, `DHCPLeaseRecord`, `NetworkQualityRecord`, `AppEventRecord`, `ProviderEdgeRecord`, `SNMPDeviceRecord`, `WiFiSampleRecord`, `WiFiStressTestRecord`, `FirewallScanRecord`.

**Not persisted** (plain structs in `NMS/Models/`, confirmed by grep for `@Model`): `ConnectionLayer`, `ConnectivityCheck`, `DHCPLeaseInfo`, `DiscoveredDevice`, `LatencySample`, `NetworkInterfaceInfo`, `NetworkQualityResult`, `PublicIPInfo`, `SNMPDevice`, `TracerouteHop`, `WiFiStressTestResult`.

**Store location**: `~/Library/Application Support/NMS/default.store` (+ `-wal`/`-shm` sidecars) (`NMSApp.swift:719-723`; `StoreSizeService.swift:17-27`). Overridable only in DEBUG via `UserDefaults` key `NMSStorePath` (`NMSApp.swift:725-729`, `#if DEBUG`); Release always uses the fixed path. If the on-disk store fails to open, the app falls back to an in-memory store for that session (`NMSApp.swift:781-793,811-826`).

| Model | Fields | Identifying fields | Retention rule | Store |
|---|---|---|---|---|
| `AppEventRecord` (`Models/AppEventRecord.swift:221-252`) | kind, message, occurredAt, networkFingerprint?, url? | networkFingerprint (router MAC + subnet); message can narrate public IP, SNMP `sysDescr`, hostnames | **Never age-pruned** (`SnapshotStore.swift:1020-1024`: grows without limit). Deleted per-network on explicit "Forget" (`:482-486`) | default.store |
| `ConnectivityCheckRecord` (`Models/ConnectivityCheckRecord.swift:8-37`) | label, target, success, latencyMs?, checkedAt, correlatedWithChange, systemLoad? | target (raw IP or hostname — router, public IP, SNMP device, printer); label (user's configured printer name) | Batch-deleted after 7 days (`SnapshotStore.swift:231,296,305`), pruned hourly at most (`:237,290-294`) | default.store |
| `DHCPLeaseRecord` (`Models/DHCPLeaseRecord.swift:12-50`) | interfaceName, serverIdentifier, assignedAddress, subnetMask?, broadcastAddress?, router?, dnsServers, domainName?, lease/t1/t2 seconds, transactionID, clientHardwareAddress?, observedAt/firstObservedAt, networkFingerprint? | clientHardwareAddress (this Mac's own MAC); assignedAddress/router/dnsServers/serverIdentifier (LAN IPs); domainName; networkFingerprint | Not age-pruned. Deleted per-network on "Forget" (`:487-491`) | default.store |
| `DiscoveredDeviceRecord` (`Models/DiscoveredDeviceRecord.swift:8-25`) | ipAddress, macAddress?, hostname?, interfaceName?, discoveredAt, snapshot relationship | ipAddress, macAddress, hostname of every LAN device seen | Fetch-then-delete after 7-day cutoff (batch-delete predicate no-ops for this relationship-holding model per doc comment, `:315-325`). Not touched by "Forget" (no networkFingerprint field) | default.store (cascades from NetworkSnapshot, `.cascade`, `Models/NetworkSnapshot.swift:19`) |
| `FirewallScanRecord` (`Models/FirewallScanRecord.swift:20-43`) | scannedAt, targetIPv4?, targetIPv6, results, networkFingerprint? | targetIPv4/v6 (this Mac's own public IP); networkFingerprint | Not age-pruned; **not** deleted by "Forget" despite carrying networkFingerprint (`SnapshotStore.swift:479-523`'s delete list omits it) | default.store |
| `KnownNetwork` (`Models/KnownNetwork.swift:18-97`) | fingerprint (unique), label?, firstSeenAt/lastSeenAt, timesSeen, confirmedEdgeHopNumber?, hasDecidedEdgeHop, isPublicForCapture, isHome | fingerprint = `"<routerMAC>\|<subnet>"` (`:101-103`) — router MAC stored in plaintext; label is free-text a user may type | Persists indefinitely; row + everything tagged with its fingerprint deleted only via explicit "Forget" (`KnownNetworksView.swift:139` → `SnapshotStore.swift:479-523`) | default.store |
| `NetworkQualityRecord` (`Models/NetworkQualityRecord.swift:9-65`) | download/uploadMbps?, testedAt, responsiveness RPM fields?, baseRTTMs?, bytesTransferred?, source, networkFingerprint? | networkFingerprint only | Never pruned ("a deliberate user action", `SnapshotStore.swift:258-267`); not touched by "Forget" | default.store |
| `ProviderEdgeRecord` (`Models/ProviderEdgeRecord.swift:23-67`) | address, hostname?, observedAt, networkFingerprint?, externallyCorroboratedAt?, pathDiscovery probe/corroborating counts? | address/hostname of ISP edge router; networkFingerprint | Never pruned; not touched by "Forget" | default.store |
| `PublicIPRecord` (`Models/PublicIPRecord.swift:8-17`) | ipAddress, observedAt | ipAddress — this Mac's own public/WAN IP history (directly geolocatable) | Never pruned; not touched by "Forget" (no networkFingerprint field) | default.store |
| `SNMPDeviceRecord` (`Models/SNMPDeviceRecord.swift:20-93`) | ipAddress, sysDescr, sysName?, uptimeTicks, community, firstSeenAt/lastSeenAt, networkFingerprint?, webURL?, hostname? | ipAddress/sysName/hostname of LAN infrastructure; networkFingerprint; community = plaintext SNMP read-community string (credential-adjacent, see §UserDefaults note) | Not age-pruned (upsert). Deleted per-network on "Forget" (`:492-496`); also a manual `deleteAllSNMPDevices()` (`:961-967`) and startup de-dupe (`:130-150`) | default.store |
| `WiFiSampleRecord` (`Models/WiFiSampleRecord.swift:10-56`) | sampledAt, ssid?, bssid?, rssi?, noise?, channelNumber?, channelBand?, phyRateMbps?, security?, networkFingerprint? | ssid (Wi-Fi network name); bssid (AP MAC address); networkFingerprint | Batch-deleted after 7 days (`:296,310`). Also deleted per-network on "Forget" (`:512-516` — a doc comment there notes 90 SSID/BSSID samples were found to survive "Forget" before this delete was added) | default.store |
| `WiFiStressTestRecord` (`Models/WiFiStressTestRecord.swift:9-51`) | streamCount, packetsSent/Received, packetLossPercent, min/avg/max/stddev RTTMs?, peak/avgCPUPercent?, packetsPerSecond, megabitsPerSecond, routerAddress, isWiFi, testedAt, networkFingerprint? | routerAddress (LAN IP); networkFingerprint | Never pruned ("a deliberate data point"); not touched by "Forget" | default.store |
| `NetworkSnapshot` (`Models/NetworkSnapshot.swift:9-32`) | interfaceName, displayName?, ipAddress?, subnetMask?, routerAddress?, dnsServer?, isWiFi, capturedAt, discoveredDevices (`.cascade`) | ipAddress (LAN IP), routerAddress, dnsServer | Never pruned directly; not touched by "Forget". Deleting one would cascade-delete its DiscoveredDeviceRecord children, but nothing currently deletes a NetworkSnapshot | default.store |

**Cross-cutting fact**: `networkFingerprint` on 8 of the 13 models — and as the primary key on `KnownNetwork` itself — is not a hash; per `KnownNetwork.makeFingerprint` (`:101-103`) it is the literal string `"<routerMAC>|<subnet>"`, i.e. a real router MAC address stored in plaintext.

### Disk writes outside the SwiftData store

| Writer | Path | Build | Notes |
|---|---|---|---|
| `UIStateLogger` (`Services/UIStateLogger.swift:231-233,281-287`) | `~/Library/Logs/NMS/ui-state.log` | `#if DEBUG` only (every method body, `:47-57,68-92,131-147`) | File's own doc comment (`:33-37`) states it logs SSIDs, public IP, and SNMP descriptors, and notes `~/Library/Logs/` is collected by `sysdiagnose`. Truncated at first write per launch, unbuffered write |
| `LocalDiagnosticServer.exportReverseTraceHTML` (`Services/LocalDiagnosticServer.swift:164-198`) | `script/diagnostic-exports/path-discovery[-<slug>]-<timestamp>.html` | Entire file `#if DEBUG` (`:4,882`) | Contains Path Discovery results: hop addresses/hostnames, network name, geo hints. Also served over a loopback-only (`127.0.0.1`) `NWListener` HTTP server with a random per-launch path token (`:221-238,341-381`), `#if DEBUG` |
| `NMSApp.storeURL()` (`NMSApp.swift:734-737`) | Creates the store's parent directory only | Both builds | Not itself a data writer |

The bug-report/screenshot/state-dump export path referenced by `script/list-bug-reports.sh` (expecting `AppEventRecord.kind == "bugReportCaptured"`, screenshots under `~/Library/Logs/NMS/screenshots/`, state-dumps under `~/Library/Logs/NMS/state-dumps/`) **does not exist in the current codebase** — `AppEventKind` has no such case, and `ScreenshotService.swift`, `ScreenshotViewModel.swift`, `BugReportExportService.swift`, `DebugArtifactRetention.swift`, `StoreInspector.swift` were all deleted in commit `4e4e83a` ("Rebuild NMS as a traditional single-window app, drop the popover"). `script/list-bug-reports.sh` is stale relative to the current app.

**Dev-tooling scripts** (not shipped in the app bundle) that write real network data to disk, for completeness: `script/export-diagnostic.sh:147-165` (writes `script/diagnostic-exports/diagnostic-<timestamp>.json` from the real store via `sqlite3`; script's own header states it "contains real identifiers ... Do not post or share this file publicly"); `script/save-fixture.sh:38-48` (copies the real store into `script/fixtures/populated.store`, gitignored per its header — "real personal network data ... this repo is public"); `script/capture-doc-scenarios.sh:27-29` (screenshots to gitignored `script/doc-captures/`, containing "the real DNS server IP from this network").

### Keychain

Single usage site: `Services/FWKeychain.swift`.
- **Stored**: FW's device Bearer token (a string, `setToken(_:)`, `:69-81`) — a credential for `github.com/PJorgens61/FW`, an internet-hosted companion service (`:4-11`).
- **Under**: `kSecClassGenericPassword`, service `"Thistle.NMS.fw-device-token"`, account `"device-token"`, `kSecAttrSynchronizable: true` (iCloud-Keychain-synced) (`:41-51`).
- **Entitlement**: `keychain-access-groups = $(AppIdentifierPrefix)Thistle.NMS` (`NMS/NMS.entitlements`).
- **Call sites**: `token()` read in `FirewallVisibilityViewModel.swift:134`, `DebugToolsView.swift:177`, `FirewallVisibilityServerSection.swift:43`; `setToken(_:)` written from `FirewallVisibilityServerSection.swift:49` (a Preferences text field); `deleteToken()` defined (`:86-90`) but no call site found.
- No other `kSecClass`/`SecItem` usage anywhere else in the tree.

### UserDefaults

Backing store `~/Library/Preferences/Thistle.NMS.plist`, `UserDefaults.standard` (no custom suite).

**Feature flags/preferences** (`FeatureFlags.swift:34-44`): `FeatureSNMPDevices`, `FeatureSaaSMonitoring`, `FeatureSaaSEnabledServices` (`[String]`), `FeatureUserAddedSaaSSites` (JSON of `{url,nickname}`, `:163-187`), `FeatureDDNSHostnames` (JSON of `{hostname}`, `:194-218`), `FeatureDDNSCheckInterval`, `FeatureAutoBaselineNetworkQuality`, `FeatureTooltipHighlights`, `FeatureTooltipTechnicalDetail`, `FeatureFirewallVisibility`, `FeatureFirewallServerURL` (plain string, explicitly documented as "not a secret," `:220-222`).

**Other keys**: `"WiFiStressTestHasConfirmed"` (`WiFiStressTestViewModel.swift:45-47`); `"DHCPRenewHasConfirmed"` (`DHCPLeaseViewModel.swift:41-43`) — one-time confirmation flags. `"NMS.snmpCommunities"` (`[String]`) and legacy `"NMS.snmpCommunity"` (`SNMPViewModel.swift:92,96,162,317`) — **read-only SNMP community strings**, i.e. LAN access credentials, stored in plaintext preferences by explicit documented design choice ("LAN read-community strings with essentially no blast radius," `SNMPViewModel.swift:29-34`; `FWKeychain.swift:6-8`) rather than Keychain. `"NMSStorePath"` (`NMSApp.swift:727`) — DEBUG-only store-path override, a filesystem path.

**Debug-only overrides** (`FailureInjector.swift`, all `#if DEBUG`): `NMSInjectFailures`, `NMSInjectSaaSOutage`, `NMSInjectDDNSStale`, `NMSInjectInterfaceDown`, `NMSInjectDHCPLinkLocal`, `NMSInjectDHCPRenewalOverdue`, `NMSInjectSNMPRestart`/`NMSInjectSNMPSoftwareChange`, `NMSPollSpeedup`.

**Flagged as credential/token-shaped** (factual note, not judgment): `NMS.snmpCommunities`/`NMS.snmpCommunity` are functionally access credentials for LAN devices, stored in plain UserDefaults rather than Keychain. `FeatureFirewallServerURL` is plain configuration, not a credential — the actual FW auth token lives in Keychain (above), not UserDefaults. No other UserDefaults key was found to be token/secret-shaped.

---

## 4. Build and distribution facts

### Non-default build settings (`NMS.xcodeproj/project.pbxproj`)

No blank-template diff was available, so every setting is listed as written; boilerplate `CLANG_WARN_*`/`GCC_WARN_*` blocks present identically in both configs are called out as such rather than itemized.

**Project level (config list `1DDFCF063011D12A0069C74C`):**

| Setting | Debug | Release |
|---|---|---|
| `GCC_PREPROCESSOR_DEFINITIONS` | `("DEBUG=1","$(inherited)")` (L339-342) | not present |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `"DEBUG $(inherited)"` (L355) | not present |
| `DEVELOPMENT_TEAM` | `5H2JL9T7SJ` (L331) | `5H2JL9T7SJ` (L395) |
| `MACOSX_DEPLOYMENT_TARGET` | `15.7` (L350) | `15.7` (L408) |
| `SDKROOT` | `macosx` (L354) | `macosx` (L411) |
| `ONLY_ACTIVE_ARCH` | `YES` (L353) | not present (release.sh forces `NO` at archive time regardless, `:85`) |
| `ENABLE_TESTABILITY` | `YES` (L333) | not present |
| `GCC_OPTIMIZATION_LEVEL` / `SWIFT_OPTIMIZATION_LEVEL` | `0` / `-Onone` (L338/356) | not present |
| `COPY_PHASE_STRIP` | `NO` (L329) | `NO` (L393) |
| `DEBUG_INFORMATION_FORMAT` | `dwarf` (L330) | `dwarf-with-dsym` (L394) |
| `GCC_DYNAMIC_NO_PIC` | `NO` (L336) | not present |
| `MTL_ENABLE_DEBUG_INFO` | `INCLUDE_SOURCE` (L351) | `NO` (L409) |
| `ENABLE_NS_ASSERTIONS` | not present | `NO` (L396) |
| `SWIFT_COMPILATION_MODE` | not present | `wholemodule` (L412) |
| `ENABLE_USER_SCRIPT_SANDBOXING` | `YES` (L334) | `YES` (L398) — overridden to `NO` at target level (below) |
| `LOCALIZATION_PREFERS_STRING_CATALOGS` | `YES` (L349) | `YES` (L407) |

The remaining ~25 `CLANG_WARN_*`/`GCC_WARN_*`/`MTL_FAST_MATH`/`ENABLE_STRICT_OBJC_MSGSEND` keys (L299-349 Debug / L363-407 Release) are Xcode-generated boilerplate, identical in both configs.

**Target `NMS`** (config list `1DDFCF2E3011D12C0069C74C`, Debug L416-460 / Release L461-505, values identical between configs unless noted):

`CODE_SIGN_ENTITLEMENTS = NMS/NMS.entitlements` (L421/466) · `CODE_SIGN_STYLE = Automatic` (L422/467) · `DEVELOPMENT_TEAM = 5H2JL9T7SJ` (L425/470) · `ENABLE_APP_SANDBOX = NO` (L426/471) · `ENABLE_HARDENED_RUNTIME = YES` (L427/472) · `ENABLE_PREVIEWS = YES` (L428/473) · `ENABLE_USER_SCRIPT_SANDBOXING = NO` (L429/474, overrides project-level `YES`) · `ENABLE_USER_SELECTED_FILES = readonly` (L430/475) · `GENERATE_INFOPLIST_FILE = YES` (L431/476) · `INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities"` (L432/477) · `INFOPLIST_KEY_NSHumanReadableCopyright = ""` (L433/478) · the three `INFOPLIST_KEY_NS*UsageDescription` keys (L434-436/479-481, quoted in full in §5) · `LD_RUNPATH_SEARCH_PATHS` incl. `@executable_path/../Frameworks` (L437-440/482-485) · `LIBRARY_SEARCH_PATHS = $(SRCROOT)/NMS/{Models,Services,ViewModels,Views}` (L441-446/486-491) · `MACOSX_DEPLOYMENT_TARGET = 14.0` (L447/492 — differs from project-level `15.7`) · `MARKETING_VERSION = 1.0` (L448/493), `CURRENT_PROJECT_VERSION = 1` (L424/469) · `PRODUCT_BUNDLE_IDENTIFIER = Thistle.NMS` (L449/494) · `REGISTER_APP_GROUPS = YES` (L451/496, though no app-group entitlement is actually present — see §Entitlements) · `SWIFT_APPROACHABLE_CONCURRENCY = YES` (L453/498) · `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (L454/499) · `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` (L456/501) · `SWIFT_VERSION = 5.0` (L457/502).

No `OTHER_SWIFT_FLAGS`, `OTHER_LDFLAGS`, `OTHER_CFLAGS`, `PROVISIONING_PROFILE*`, or `CODE_SIGN_IDENTITY` appear anywhere in the file (confirmed by full-file read and grep).

**`NMSTests`** (config list `1DDFCF313011D12C0069C74C`): `BUNDLE_LOADER`/`TEST_HOST` point at the built `NMS.app` (L509/528, L535/554); `MACOSX_DEPLOYMENT_TARGET = 15.7` (L519/545 — the project-level value, not the app target's `14.0`); `PRODUCT_BUNDLE_IDENTIFIER = Thistle.NMSTests` (L521/547). **`NMSUITests`** (config list `1DDFCF343011D12C0069C74C`): `TEST_TARGET_NAME = NMS` (L578/602); no `MACOSX_DEPLOYMENT_TARGET` set at this level (falls through to project-level `15.7`).

A `PBXShellScriptBuildPhase` named "Stamp build info" (L236-255) runs on every build (both configs) and writes `NMSGitHash`/`NMSGitSubject`/`NMSGitDirty` into the built Info.plist via `plutil -replace`, reading `git rev-parse --short HEAD`, `git log -1 --format=%s`, `git status --porcelain` (L254).

No `.xcconfig` file exists anywhere in the repo (`find . -iname "*.xcconfig"` → none).

### Entitlements (`NMS/NMS.entitlements`, full contents)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)Thistle.NMS</string>
	</array>
</dict>
</plist>
```

One entitlement, `keychain-access-groups`. No sandbox entitlement, no hardened-runtime exceptions, and no app-group entitlement — despite `REGISTER_APP_GROUPS = YES` and `ENABLE_APP_SANDBOX = NO` both being set in build settings.

### Info.plist usage-description strings (verbatim)

No physical Info.plist exists; these are synthesized from `INFOPLIST_KEY_*` (identical text in both configs):

- `NSLocalNetworkUsageDescription` (`:434,479`): *"NMS reads your Mac's ARP table to list local devices and polls them via SNMP (using configured community strings) to discover and monitor routers, switches, and other network infrastructure."*
- `NSLocationUsageDescription` (`:435,480`): *"NMS reads the current Wi-Fi network name (SSID) to label and recognize networks. macOS treats Wi-Fi network names as location-sensitive information."*
- `NSLocationWhenInUseUsageDescription` (`:436,481`): same text as above.

No `NSBluetoothAlwaysUsageDescription`, `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSContactsUsageDescription`, or any other `NS*UsageDescription` key exists. No custom in-app rationale text precedes `CLLocationManager.requestWhenInUseAuthorization()` (`LocationAuthorizationService.swift:61`) — only the system prompt appears.

### DEBUG-only code / Release exclusion mechanism

Mechanism: `SWIFT_ACTIVE_COMPILATION_CONDITIONS` contains `DEBUG` only in the project-level Debug config (`:355`), absent from Release (`:360-415`) — confirmed as a true compiler conditional (Swift never compiles the guarded code into Release, not merely dead-code elimination after the fact).

Every `#if DEBUG` occurrence in the tree was read in full and classified. **Result: zero instances of a `#if DEBUG` guard that was actually a runtime check disguised as a compile-time one** — every occurrence is a genuine compiler conditional. Whole-file `#if DEBUG` wraps: `FWTraceService.swift` (`:3-79`), `GlobalpingReverseTraceService.swift` (`:3-316`), `HoihoService.swift` (`:3-102`), `LocalDiagnosticServer.swift` (`:4-882`), `ScamperService.swift` (`:3-241`), `TopologyBuilder.swift` (`:3-474`), `DebugToolsView.swift` (`:3-366`). Partial guards: `NMSApp.swift` (`:30-33,639-652,725-732`), `FailureInjector.swift` (16 accessor sites, each paired with an inert `#else` default), `SubprocessTracer.swift` (`:38-88`), `UIStateLogger.swift` (`:48-320`), `ConnectivityViewModel.swift:768-780`, `SNMPViewModel.swift:751-757`, `TracerouteViewModel.swift:258-350`, `ContentView.swift:286-298`, `FieldTestFrameReporter.swift:37-60`, `PathToInternetTile.swift:70-177`. No `#if !DEBUG` or `#if targetEnvironment` occurrences exist anywhere.

Notable adjacent-but-distinct construct: `FeatureFlags.swift` (whole file) is deliberately **not** `#if DEBUG`-gated — its own doc comment (`:7-13`) states this is intentional ("these need to work in whatever build a tester actually runs, not just a debug build"), backed by plain `UserDefaults` reads. This is the app's documented mechanism for runtime-conditional behavior that ships in Release, distinct from true compile-time DEBUG exclusion.

### `script/release.sh` (143 lines, read in full)

**Builds**: a universal (arm64 + x86_64) Release archive via `xcodebuild archive` (`:78-86`: `-configuration Release`, `-destination 'generic/platform=macOS'`, `ARCHS="arm64 x86_64"`, `ONLY_ACTIVE_ARCH=NO`), gated on `script/test-max.sh` passing first (`:68-69`, `set -euo pipefail`, `:24`).

**Artifacts**: `NMS.xcarchive` (`:30,78-86`); an exported signed `.app` at `$BUILD_DIR/export/NMS.app` (`:31-33,104-109`) via `-exportArchive` with a generated `ExportOptions.plist` (`:88-102`, `method=developer-id`, `signingStyle=automatic`); a zip at `$BUILD_DIR/NMS.zip` via `ditto -c -k --keepParent` (`:119`, chosen over `zip` to preserve symlinks/xattrs per `:115`), rebuilt a second time after stapling (`:126-127`) since the notarization-submission zip lacks the stapled ticket.

**Signing**: resolves a "Developer ID Application" identity from the login keychain via `security find-identity -v -p codesigning` if `TEAM_ID` isn't already set (`:44-53`); actual signing happens implicitly inside `xcodebuild`/`-exportArchive` under `CODE_SIGN_STYLE=Automatic`/`signingStyle=automatic` — the script itself never calls `codesign --sign` directly, only `codesign --verify` afterward (`:134`).

**Notarization**: preflights a notarytool keychain profile (`:57-60`, default name `NMS-notary`, `:27`); submits via `xcrun notarytool submit "$ZIP" --keychain-profile ... --wait` (`:120`); staples via `xcrun stapler staple "$APP"` (`:125`), then rebuilds the zip.

**Post-build verification**: `lipo -info` (both arches present, `:112`); `codesign --verify --deep --strict --verbose=2` (`:134`); `spctl -a -vvv -t install` (Gatekeeper simulation, `:137`); `xcrun stapler validate` (`:140`).

**Credentials**: the script states no credential is stored in the repo (`:19-20`) — notarization auth is expected to already exist as a named keychain profile, and code signing relies on a certificate already in the invoking user's login keychain.

---

## 5. User-facing disclosure

### System permission prompts

See §4 — the three `INFOPLIST_KEY_NS*UsageDescription` strings, quoted verbatim there.

### Preferences window (`NMS/Views/PreferencesView.swift`)

| Item | Exact text | Location |
|---|---|---|
| Section caption | "Off by default for a fresh install — everything below is opt-in." | `:64` |
| SNMP Devices | "Active SNMP network probing against whatever LAN this Mac is on. Only turn this on if you're comfortable with that on your own network." | `:68,70` |
| SaaS Monitoring | "Periodically checks the public status pages of Slack, Claude, ChatGPT, Jira/Confluence, Zendesk, Zoom, Trello, Asana, Notion, Dropbox, Discord, GitHub, Cloudflare, Figma, HubSpot, Docusign, Google Cloud, and Google Workspace. Reaches out to those services directly, not just your own network." | `:75,77` |
| Firewall Visibility | "Requests scans from FW, a separate internet-hosted companion service, to test what's actually reachable on this connection's public IP from outside. Reaches out to that server directly, not just your own network — and being on is also the consent for the scheduled and SNMP-triggered scans this runs automatically, not just the manual button." | `:95,97` |
| Auto-Baseline Network Quality | "Runs Network Health's ~5 second networkQuality check automatically when you reconnect to a network you've already seen before, so the status dot has a real color instead of staying gray until you press it yourself. This is a genuine responsiveness test under load, not a ping — it uses your data plan, same as pressing the button manually. Never runs on the very first time this Mac sees a network." | `:110,112` |
| Tooltip Highlights | "Colors any row's label blue and underlines it when hovering shows more detail — otherwise a tooltip gives no visual sign it's there at all. Turn off to compare against plain labels." | `:117,119` |
| Tooltip Detail | "Whether tooltips include the extra mechanism-level detail (which command runs, which resolver, what's in or out of scope) on top of the plain explanation." | `:129-135` |
| DDNS Hostnames | "Watches a hostname you rely on for inbound access (a VPN endpoint, a port-forwarded service) and logs it if it stops matching this Mac's public IP — a sign your DDNS client has stopped updating." | `:144,146` |

### Related preferences sections

- **SaaS service picker** (`SaaSServicePickerSection.swift:35-53`): "Services to monitor"; per-service toggles use the service's own name.
- **User-added sites** (`UserAddedSitesSection.swift:26-65`): "Checked for plain reachability only — not a real status page, just \"did it answer.\""; tooltip: "A plain HTTP reachability probe, not a real vendor status page, so it can't distinguish \"down\" from \"blocked on this network.\"" (technical clause, shown by default since `tooltipTechnicalDetail` defaults on).
- **Firewall server settings** (`FirewallVisibilityServerSection.swift:22-37`): "Saves this token to the Keychain — never stored in plain preferences." / "Device token saved to Keychain."
- **DDNS hostnames section** (`DDNSHostnamesSection.swift:46-62`): technical tooltip — "Resolved via dig against Cloudflare's public resolver (1.1.1.1), bypassing this Mac's local DNS cache."
- **Known Networks** (`KnownNetworksView.swift:38-147`): "DDNS hostname checks (Preferences → DDNS Hostnames) only run and report while connected to whichever network is marked home"; "Deletes this network and every event, DHCP lease, SNMP device, and Wi-Fi reading recorded on it."

### Debug Tools window (`DebugToolsView.swift`, `#if DEBUG` only — not present in shipped Release UI)

- Path Discovery: "Runs a reverse traceroute from several external vantage points back toward this Mac's own public IP, via the free Globalping service, and opens the result as a local web page. Also checks whether any vantage point corroborates the confirmed ISP edge router." (`:76,79-80`, technical clause names `api.globalping.io`, unauthenticated).
- Scamper: "Scamper is a free, separately-installed tool (not part of NMS) that gives a rigorous second opinion on whether two addresses are really the same router." / technical: "GPL-2.0-licensed, invoked as a subprocess only — never bundled or linked, so it never changes NMS's own license. Needs a one-time setuid step Homebrew doesn't set automatically..." (`:132-133`).

### Inline text at network-scanning trigger points

| Feature | Text | Location |
|---|---|---|
| SNMP "Scan" button | "Clears the SNMP device list and sweeps the subnet again." / technical: "Current subnet only, not off-subnet devices." | `SNMPDevicesTile.swift:44,47-48` |
| Firewall "Scan Now" button | "Tests what's actually reachable on this connection's public IP from outside — a real check from beyond your router, not a local guess." / technical: "Requests a scan from FW (an internet-hosted companion service), then polls for the result. Only runs while the current network is marked home." | `FirewallVisibilityTile.swift:24,27-28` |
| Local Stress Test | Hint: "Fires many concurrent ping streams at the local router for about 1-2 seconds to check for packet loss under load. Generates real network traffic." Confirmation alert: "Run Local Stress Test?" / "This will generate real network traffic for about 1-2 seconds — continue?" | `LocalStressTestTile.swift:44,46,51,58` |
| Path to Internet "Trace Now" | "Runs a traceroute to find the path to the internet" | `PathToInternetTile.swift:24,26` |
| Apple networkQuality "Run Test" | "Runs Apple's own network quality test: throughput plus responsiveness under load. Uses your data plan and takes about 30 seconds." Caption: "uses your data plan — often 1+ GB on a fast connection, ~30s" | `AppleNetworkQualityTile.swift:27,29,43` |
| Speed Test "Run Speed Test" | "Measures download and upload throughput using Cloudflare's public speed-test endpoint. Uses your data plan, up to roughly 50MB total, less on a slow connection." Caption: "up to ~50MB per run" | `SpeedTestTile.swift:37,39,41` |
| DHCP "Renew" | Hint: "Forces a fresh DHCP negotiation on this Mac's active interface. Briefly disrupts the connection and may prompt for an administrator password." Confirmation alert: "Renew DHCP Lease?" / "This forces a fresh DHCP negotiation on this Mac's active interface, briefly disrupting the connection, and may prompt for an administrator password — continue?" | `DHCPHistoryTile.swift:43,46,52,59` |

Note on the technical-detail mechanism (`TileHelpers.swift:199-201`): the rendered tooltip is the base string alone when `tooltipTechnicalDetail` is off, or `"\(base) \(technical)"` when on — that flag **defaults on** (`FeatureFlags.swift:130-133`), so a fresh install sees the combined (longer) text by default.

### Features reaching a network the user may not own — disclosure-at-trigger-point audit

| Feature | Reaches | Disclosure at the enable/trigger point? |
|---|---|---|
| SNMP Devices (flag enable) | Active SNMP probing of "whatever LAN this Mac is on" | **Yes** — `PreferencesView.swift:70` (quoted above) |
| SNMP "Scan" button (per-run) | Same, on demand | Yes, but narrower — `SNMPDevicesTile.swift:44,47-48` describes scope, doesn't repeat the "your own network" caution from the Preferences toggle |
| **LAN Discovery** (ARP-table read feeding SNMP/topology, `LANDiscoveryViewModel.scan()`) | The LAN of whatever network the Mac is currently on | **No explanatory string found** — there is no button/checkbox/UI trigger at all; it runs automatically and unconditionally at launch (`NMSApp.swift:161`) and on every topology change (`:344`), independent of any feature flag. Checked `ContentView.swift` (comment at `:220-228` acknowledges "LAN Devices has no section of its own" and the scan still runs with no UI), `LANDiscoveryViewModel.swift`, `NMSApp.swift` |
| Firewall Visibility (flag enable) | An internet-hosted companion server that itself probes the user's public IP from outside | **Yes** — `PreferencesView.swift:97` (quoted above) |
| Firewall "Scan Now" (per-run) | Same, on demand | **Yes** — `FirewallVisibilityTile.swift:27-28` |
| Local Stress Test | Floods the local router with concurrent pings | **Yes** — hint plus a modal confirmation alert |
| SaaS Monitoring (flag; **on by default**) | Multiple named third-party status pages, periodically | **Yes**, text exists (`PreferencesView.swift:77`) — but the reach-out itself is not opt-in by default since the flag defaults on |
| Auto-Baseline Network Quality (flag) | Real Apple `networkQuality` test (data-plan cost) automatically on reconnecting to *any* previously-seen network | **Yes** in the UI (`PreferencesView.swift:112`) — note the code comment at `FeatureFlags.swift:262-263` additionally characterizes this as possibly running on "someone else's guest Wi-Fi or a metered hotspot," language that does **not** appear in the UI string itself |
| Path Discovery (Debug Tools, DEBUG-only) | Globalping's public probe network, plus FW server if configured | **Yes** — `DebugToolsView.swift:76,79-80` |
| **Printer discovery** (`PrinterDiscoveryService`, feeds `ConnectivityViewModel.refreshConfiguredPrinters()`) | Pings printers already configured in System Settings, on whichever network is current | **No explanatory string found** — no UI trigger at all; runs automatically on every topology change (`NMSApp.swift:371`). Checked all of `NMS/Views/*.swift` (no match for "rinter" in any View file) and `ConnectivityViewModel.swift:149` |

---

## Not determined

- Upstream license for `ping`, `traceroute`, `dig`, `ipconfig`, `scutil`, `networksetup`, `arp`, `snmpget`, `lpstat` — these ship with macOS as BSD-userland/net-snmp/CUPS tools respectively, but no bundled notice file or in-repo statement pins a specific license text for any of them; only `scamper`'s GPL-2.0 status is explicitly documented in code/UI.
- Exact byte size of `mermaid@11/dist/mermaid.min.js` as fetched from `cdn.jsdelivr.net` — not measured anywhere in the codebase; the request is made by the user's browser, not the NMS process, when a DEBUG-only diagnostic page is opened.
