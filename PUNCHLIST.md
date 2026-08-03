# Punchlist

Open items, tracked here so they survive between sessions. Not a spec —
see `DESIGN-NOTES.md` for the reasoning behind anything non-obvious.
Actual defects live in `BUGS.md` instead — this file is ideas, testing
tasks, and decisions. Check items off or delete them as they land; add
new ones as they come up.

## Open

- [ ] **Fold the Ethernet Speed/Duplex tile into the Info tile's Network
  row, instead of its own separate section.** Currently
  `ContentView+Window.swift`'s `ethernetLinkSection` is its own small
  window-only box (`scrollBox(.ethernetLink)`, two rows: Speed, Duplex)
  rendered below Info alongside the Wi-Fi/Ethernet sections — mutually
  exclusive with `wifiSection` the same way. Move Speed/Duplex to live
  with Info's own "Network" row instead (`ContentView.swift`'s
  `infoContent`, `row("Network", networkDisplay(info))`), the way the
  Wi-Fi tile's Signal/Channel/PHY Rate already sit apart from Info's
  Network row today (BSSID especially) — worth deciding during
  implementation whether that same precedent argues for leaving
  Ethernet's own detail where it is instead of moving it, since this
  request cuts the other way from that existing split.

- [ ] **Info tile: move the DDNS row above the ISP row.** Currently
  `ContentView.swift`'s `infoContent` puts `ddnsRow` after
  `networkIdentityStatus`, below the inner VStack that ends with the ISP
  row (Network/IP Address/Router/DNS Server/Public IP/ISP) — so on
  screen DDNS renders last, after ISP. Move it to sit right after
  "Public IP" and before "ISP" instead.

- [ ] **Switch to Swift 6 language mode? Raised directly, not yet
  decided.** Checked the project settings directly rather than
  assuming: currently `SWIFT_VERSION = 5.0`, but already manually
  opted into most of the individual upcoming features Swift 6 mode
  bundles as a group — `DisableOutwardActorInference`,
  `InferSendableFromCaptures`, `GlobalActorIsolatedTypesUsability`,
  `MemberImportVisibility`, `InferIsolatedConformances`,
  `NonisolatedNonsendingByDefault`, plus `-default-isolation=MainActor`
  — a deliberate, incremental path rather than an oversight.

  Flipping `SWIFT_VERSION` to 6 outright turns on strict, whole-program
  data-race safety checking, which is a real, separate undertaking in a
  codebase this size — 15+ view models, several background `Timer`s,
  subprocess-shelling services (`SNMPService`, `DDNSResolutionService`,
  `ConnectivityService`), and cross-view-model wiring
  (`NMSApp.wireDependencies`) that's never been checked under strict
  concurrency before. Expect a real batch of new errors to work through,
  not a clean flip. Deliberately not bundled into the single-window-app
  rebuild that was in progress when this was raised — a good candidate
  for its own dedicated pass once that settles, not something to
  compound into an already-large change.

- [x] ~~Rebuild the UI from scratch in "simpler" SwiftUI, to stop the
  recurring breakage?~~ **Done — rebuilt as a traditional single-window
  app.** Investigated before rewriting: the breakage wasn't accidental
  complexity, it was three separate `MenuBarExtra(.window)` platform
  gaps (no pure-SwiftUI fix for bounce-free chaining scroll, `.help()`
  rendering nothing, and safe screenshotting) each papered over with its
  own AppKit bridge (`NoBounceScrollView`, `ToolTip.swift`,
  `ImageRenderer`-based capture) — and each bridge accumulating its own
  interop bugs (`Grid` clipping, SNMP Devices clipping, the Events-list
  ghosting) as the app grew. Rather than keep patching bridges, dropped
  the popover entirely for a `.regular`-policy single window: that alone
  made `.help()` work natively (deleted `ToolTip.swift`), made a real
  window-scoped screen capture safe (deleted the whole Screenshot/Bug
  Report feature — redundant with `Cmd+Shift+4` on a real window
  anyway), and removed the reason `NoBounceScrollView` existed (deleted
  it for a plain `ScrollView`, with `.frame(maxHeight: .infinity)` to
  stop the window floor-clamping to full content height). The `Grid`
  clipping bug did not reoccur once `NoBounceScrollView` was gone,
  confirming it was an AppKit-bridge quirk, not a `Grid` bug. Also added
  `ContentView+Preview.swift`'s `#Preview` support (the project had none
  before) so future tile layout changes don't need a full
  build-relaunch-screenshot cycle to check.

- [ ] **`README.md` (and the `gh-pages` website) still describe NMS as
  living "quietly in your menu bar," a `MenuBarExtra` popover with a
  status icon.** All stale since the single-window rebuild above —
  there's no menu bar icon or popover anymore, just a Dock icon and a
  normal window. Flagged directly during that rebuild and deliberately
  left out of scope for it: that change was about the app itself, this
  is a copy/docs pass across `README.md`'s "The popover" section, its
  install instructions ("click the menu bar icon"), its source-tree
  comments (`NMSApp.swift # ... menu bar scene`), and the website's own
  framing.

- [ ] **Review the internal tooling for observing this app's own UI — can
  Claude get a better view of what actually gets *rendered*, not just
  what data changed?** Raised directly, after two real bugs this
  session that `UIStateLogger` (the existing debug-only log of every
  `@Published` write, see that type's own doc comment) couldn't have
  caught even in principle: the `Grid`/`NoBounceScrollView` column-
  misalignment bug and the `appKitToolTip` overlay silently swallowing
  every `Link` click. In both cases the underlying view-model data was
  completely correct the whole time — only the actual on-screen
  rendering (or hit-testing) was wrong, so a log of what was *written*
  showed nothing unusual. Confirming either one needed a real
  screenshot, and confirming the click-swallowing bug specifically
  needed the user to click a real button, since no automation caught it.

  **Second, related friction, also worth fixing regardless of the first:
  driving/inspecting the live UI via `osascript`/System Events was
  unreliable for a large stretch of this session** — `entire contents of
  window` tree-walks repeatedly returned zero elements even after
  quitting/relaunching/repositioning, `menu bar 2`'s items reported no
  `name` (workable, but only once found by trial), and
  `CLAUDE.md` already documents two separate sharp edges here (button
  lookup by name not working reliably, sheets not appearing in their
  presenting window's `entire contents`). Whether this is a genuine
  `System Events`/SwiftUI-AX-bridging gap, an entitlements/permission
  issue specific to this environment, or something else isn't
  understood yet — worth actually diagnosing before building more
  tooling on a foundation that might itself be the flaky part.

  **One concrete idea, not yet decided**: since the app itself already
  has native AppKit access to its own `NSApp.windows`/view hierarchy —
  no `System Events`/Accessibility permission dance required, unlike an
  *external* process automating it — a debug-only feature could have
  NMS dump its own window/view tree (frames, `AXIdentifier`s, and each
  `Text`'s actual rendered string) to a plain file on demand, the same
  "append to a file Claude can just read" shape `UIStateLogger` and
  `SubprocessTracer` already use. That would directly answer "what does
  the screen actually say right now" without a screenshot, without
  `osascript`, and without the reliability problems above — genuinely
  the rendered content, not a proxy for it. Untested whether SwiftUI
  exposes enough of its own layout tree for this to work through pure
  AppKit APIs, or whether it would need something more invasive
  (`ImageRenderer` plus OCR, say) — a real feasibility question, not a
  decided design.

- [ ] **Review all of this app's polling mechanisms — can they be
  improved or unified?** Raised directly, noticed while building
  `DDNSViewModel` as the *n*th view model to hand-roll the same
  `Timer`/`activate()`/`deactivate()`/`observeFeatureFlagChanges()`
  shape (`SNMPViewModel`, `SaaSMonitoringViewModel`, `PublicIPViewModel`,
  `TracerouteViewModel`, `DDNSViewModel` itself, `ConnectivityViewModel`'s
  own check loop) — each copy is a near-identical `NSObjectProtocol`
  `UserDefaults.didChangeNotification` observer plus a
  `Timer.scheduledTimer` wrapped in `FailureInjector.acceleratedInterval`,
  with small, real per-view-model differences (some gated by a boolean
  flag, some by a non-empty list, some always-on with no gate at all;
  intervals range from `ConnectivityViewModel`'s fast poll up through
  `TracerouteViewModel`'s 10-minute retrace).
  
  **Not yet decided whether unifying is actually worth it** — a shared
  "polling controller" type could cut real duplication, but every
  existing view model's activate/deactivate logic carries its own
  specific reasoning in its doc comments (documented directly, not
  incidental), and a generic abstraction risks flattening those into
  something less legible than five separate, well-commented copies.
  Also raised alongside this: whether check intervals should be more
  consistently user-configurable — `DDNSViewModel` just became the
  first view model with a user-facing interval preference
  (`FeatureFlags.ddnsCheckInterval`, "users with critical inbound
  services might want to poll aggressively"), where every other
  interval here is still a fixed constant. Worth a real audit pass
  before deciding either way, not a snap judgment.

- [ ] **A local-only HTTP server, serving pages to the Mac's own default
  browser — raised directly, connecting two separate needs.** First:
  Apple networkQuality's verbose report currently shows as raw
  monospace text in a native sheet
  (`AppleNetworkQualityVerboseView`) — a real HTML page could format it
  properly (the tool's own section structure — Capacity/Latency/
  Protocols/Transport-layer info — maps naturally onto real headings
  and tables). Second, and the more important connection: the network-
  diagram idea elsewhere in this file already flagged a real, unresolved
  privacy problem — rendering via `mermaid.ink` means this network's
  actual topology (MACs, hostnames, IPs) leaves the device to a third
  party. **A local HTTP server resolves that outright, not just
  mitigates it**: serve a self-contained HTML page with Mermaid's own
  JS bundled locally (not loaded from a CDN — that would just relocate
  the external-dependency problem from image-rendering to script-
  loading) and render the diagram client-side, in the browser, from
  data that never left this Mac. Same resolution shape already used
  once this session, for a different third-party-in-the-loop concern
  (the external firewall-checker idea's self-hosting answer).

  **Real constraints worth being explicit about before building**:
  - **Loopback-only, always** — `127.0.0.1`, never `0.0.0.0`. Binding
    to every interface would make locally-generated pages (containing
    real topology/diagnostic data) reachable from other devices on the
    LAN, the exact opposite of the privacy win this exists for.
  - **No third-party dependency for the server itself** — this app's
    own stated position (the website's swift-programmers section: "No
    dependencies. None. Not one third-party package") rules out
    reaching for a package like Vapor/Swifter. `Network.framework`'s
    `NWListener` plus hand-written minimal HTTP/1.1 responses is
    realistic for serving a handful of static/generated pages — this
    isn't a general-purpose web framework's job.
  - **On-demand lifecycle, not always-running** — start the listener
    only when a page is about to be shown, stop it once the browser has
    loaded it (or after a short idle window), rather than keeping a
    server socket open for the app's entire lifetime for a feature used
    occasionally. Smaller attack surface, matches how every other real-
    cost feature in this app is on-demand-only (Speed Test, Apple
    networkQuality, now the popover quick check) rather than a
    persistent background service.
  - **Ephemeral port, not a fixed one** — avoids ever conflicting with
    something else already listening locally, and a random per-launch
    path/token (defense in depth on top of the loopback binding) means
    another local process can't casually guess the URL either.

  Not yet decided: whether this becomes a small shared internal
  service both features route through, or two independent one-off
  implementations — worth deciding once the diagram feature is
  actually being built, not speculatively now.

- [x] ~~Website: mention bufferbloat detection (via macOS's built-in
  `networkQuality`) in the homelab section.~~ **Shipped** (`gh-pages`
  `83fcaa4`): a new homelab feat-list bullet — "Runs Apple's own
  networkQuality test on demand to catch bufferbloat... know it's the
  network, not your aim" — a different pitch than the swift-programmers
  section's existing `networkQuality` bullet (that one sells "implements
  a real IETF standard" for developer credibility; this one sells the
  outcome).

  **A gaming-specific angle was considered and explicitly rejected as
  its own hop-section, resolved directly**: competitive gamers
  overwhelmingly play on Windows, not macOS, and a dedicated pitch for
  an audience that mostly can't run the product isn't worth building —
  "that's their problem, not this app's." Real nuance kept, though:
  NMS doesn't need the *gamer* to be the Mac user, just a Mac somewhere
  on the same home network (someone working on a MacBook while gaming
  happens on a separate Windows rig/console down the hall still shares
  one connection) — so gaming shipped as one concrete example inside
  the bufferbloat bullet itself, not as its own section, and the
  shipped copy states it plainly rather than hedging about the
  Windows/macOS split.

- [ ] **A local Wi-Fi stress test: many concurrent MTU-sized ping
  streams to the local router for ~1 second, plus TCP/UDP ideas for
  testing further out.** Raised directly, motivated by validating the
  local Wi-Fi specifically *before* trusting any test that crosses the
  internet — several test networks used this session had slow DSL,
  where an internet-facing test can't tell you whether a problem is
  local or upstream. Small networks in particular have no one
  monitoring them, so a self-triggered local check has real value on
  its own. The local router is already a known address with no new
  discovery work (`traceroute` hop 1 / `NetworkIdentityViewModel`'s
  recognized gateway).

  **Concurrency, not flood mode, is the actual mechanism — resolved
  directly over the course of this discussion.** The first instinct
  (`ping -f`, true kernel flood mode) is a dead end: it requires root,
  which this app doesn't have and shouldn't ask for. The real design
  is **N independent concurrent streams, each just repeated `ping -c 1
  -s 1472 -D`** (`-s 1472` for a full 1500-byte MTU after the 28-byte
  IP+ICMP header, `-D` so an oversized packet fails loudly instead of
  silently fragmenting) — each stream fires its next packet the
  instant its own previous reply lands, independent of every other
  stream, for a fixed ~1 second window. No `-f`, no elevated
  privileges, at any concurrency.

  **Why concurrency is what makes this work at all**: a single ping
  stream is fundamentally round-trip-time-bound, not bandwidth-bound —
  at a typical ~2ms local RTT, one stream tops out around 500 packets/
  sec, which at MTU size is only ~6 Mbps, nowhere near enough to
  stress a real Wi-Fi link. N independent concurrent streams multiply
  that roughly linearly (~20 streams ≈ 120 Mbps) since each is its own
  independent request/reply chain — the only reason this approach can
  generate meaningful load at all. There's no fixed load-percentage
  target here (raised and then explicitly dropped as a requirement) —
  the point is generating *real, sustained* load for about a second
  and seeing how the link responds, not hitting a specific number.

  **What this can and can't actually reveal — worth being precise
  about, prompted by a comparison to classic T-1 BERT (bit-error-rate)
  testing with specialized bit patterns.** This is a real, useful, but
  *different* mechanism, not the same technique: BERT uses deliberately
  chosen worst-case bit patterns (all-1s, alternating, pseudorandom) to
  stress specific physical-layer failure modes; `ping`'s payload is
  just an incrementing byte pattern, not a designed stress pattern. It
  doesn't replicate BERT. What concurrent MTU-sized load genuinely does
  expose that small pings don't: packet loss/corruption specifically
  under sustained large-frame load — a marginal Wi-Fi signal often
  handles small packets fine while dropping or retransmitting large
  ones once the link is loaded, a real and different failure mode from
  what one small ping can show.

  **Chased down directly: is there an 802.11-specific "best" ping
  payload bit pattern the way BERT has one for T-1? No — and the
  reason is a genuine, checked-not-assumed answer, not a shrug.**
  Every 802.11 payload passes through a mandatory PLCP scrambler (a
  length-127 PRBS, polynomial x⁷+x⁴+1) that XORs every payload bit with
  a pseudo-random sequence before it ever reaches the PHY/modulation
  stage — the standard's own built-in equivalent of what BERT patterns
  manually engineer for unscrambled serial lines. Whatever content
  `ping` puts in its payload gets whitened into essentially the same
  statistical bit distribution before transmission regardless, so
  payload-content tuning is a dead end at this layer; there's no lever
  available for the app to pull here. Independent confirmation from
  the other direction: ["Are All Bits
  Equal?"](https://ieeexplore.ieee.org/document/6361252/) (IEEE
  Trans. Networking, also on
  [ResearchGate](https://www.researchgate.net/publication/260353749_Are_All_Bits_Equal-Experimental_Study_of_IEEE_80211_Communication_Bit_Errors))
  found 802.11 bit errors correlate with *position within the frame*
  (a roughly linear relationship, plus some hardware-dependent
  patterns), not with bit value — consistent with the scrambler already
  washing out content-dependent effects. This actually validates the
  design above rather than changing it: MTU-sized packets matter
  because they're larger and spend longer on air (more exposure to a
  fade or interference burst mid-transmission), not because of what's
  in them — size and volume are the real, available knobs, which is
  exactly what concurrent MTU-sized streams already target.

  **Two practical limits to design around, not just build past**:
  1. **Process-spawn overhead becomes the real ceiling at high
     concurrency.** Each stream is a real subprocess
     (`Process()`/fork+exec, the same mechanism `ConnectivityService`
     already uses) — above some concurrency count, the test starts
     measuring this Mac's own process-spawn rate instead of the Wi-Fi
     link. 20-30 concurrent streams for ~1 second is almost certainly
     fine; hundreds probably isn't. Needs an empirical check on real
     hardware before picking a default.
  2. **Still worth a clear "this generates real traffic" framing**,
     even bounded to ~1 second and root-free — this app's first
     feature whose whole point is deliberately loading the network
     rather than quietly observing it, the same category of "needs an
     explicit yes" already flagged for the external-firewall-checker
     idea further down, just at a much smaller/safer scale (1 second,
     LAN-only, no elevated privileges) than a sustained flood would be.

  **What the test should actually report**: aggregate sent/received
  counts across every stream (loss %) and RTT distribution (min/avg/
  max, maybe stddev) during the burst — that's the real diagnostic
  payoff, not just confirmation that load was generated.

  **TCP/UDP, for testing further out than the local hop — separate
  from the local Wi-Fi test above, and less developed.** TCP/UDP echo
  (RFC 862/863) is confirmed dead on modern equipment — raised
  directly ("I think that idea is no longer supported"), matches this
  app's own existing HTTP-based approach elsewhere. What actually works
  instead:
  - **TCP**: no echo needed — open a real connection to something
    guaranteed to answer and push/pull a bulk transfer, timed. This is
    exactly `NetworkQualityService`'s existing probe/full-transfer
    shape, just pointed at a LAN target (a router's admin HTTPS port,
    confirmed reachable via the same web-detection work
    `DeviceWebDetectionService` already does) rather than Cloudflare's
    endpoint.
  - **UDP**: trivial to send, but proves only "can send," not
    "arrived" — no built-in delivery confirmation, so measuring loss
    needs a cooperating receiver. Nothing on a stock router does this;
    the external firewall/ACL checker idea further down is the one
    already-sketched mechanism that could, repurposed for load/loss
    measurement instead of port-reachability.

  **Still not decided**: whether the TCP/UDP half ships standalone or
  waits on the external-checker project (for UDP's receive-side
  requirement specifically) — a scoping question raised and not yet
  answered. Doesn't block the local Wi-Fi ping-stress test above, which
  stands on its own with no external dependency.

- [x] ~~Give Apple's `networkQuality` its own tile, separate from
  Speed Test.~~ **Shipped** (`4eb6f81`): a dedicated "Apple
  networkQuality" tile with its own run history, real byte-transfer
  reporting, a "View Full Report" verbose-output sheet, and a
  popover-only 5-second quick check with a green/yellow/red verdict.
  Also added to the website's homelab section (`gh-pages` `e1dfcb9`,
  copy refined further in `4361a25`) — "Runs Apple's own networkQuality
  test on demand to catch bufferbloat... Know if it's the network, not
  your aim."

- [ ] **Learn how major ISPs actually architect customer deployments —
  broader and more proactive than just tracking hop patterns we've
  personally observed.** Raised directly, as a generalization of the
  per-ISP hop-pattern idea below: rather than only recognizing a
  pattern *after* NMS has personally seen it (this session's own
  `10.1.10.1` finding, twice), research how each major ISP's residential
  deployment actually works — DOCSIS vs. fiber vs. DSL vs. fixed
  wireless, whether and for which tiers CGNAT is used, typical private-
  addressing conventions for the ISP's own gateway/management hop,
  whether business-class connections on the same ISP look structurally
  different from residential. Tonight's Comcast finding is exactly the
  kind of evidence this idea would generalize from: not just "this one
  address," but "this is how Comcast residential DOCSIS deployments are
  shaped," which could then be checked against — and recognized on the
  first encounter with a new ISP, not just the second.

  **Why this is a different, complementary idea, not a duplicate of the
  one below**: the per-ISP hop-pattern item is reactive and narrow — it
  only helps once this app (or this installation) has directly seen a
  specific address/hostname before. This is proactive and structural —
  understanding *why* an ISP's network looks the way it does (DOCSIS
  gateways needing a private management hop, whether a given ISP's
  residential tier uses CGNAT at all, fiber deployments potentially
  having zero private hops at all) means recognizing the *shape*, not
  just a memorized address. The same research discipline this session
  already used for the Comcast finding — direct web search, then
  cross-checking against a real live trace rather than trusting either
  alone — is exactly the method this would need, just aimed at the
  handful of major ISPs (Comcast, Charter/Spectrum, Cox, AT&T, Verizon,
  T-Mobile/Starlink home internet, ...) rather than one address on one
  ISP.

  **Where this would plug in, same two places as the narrower idea**:
  sharpening `multipleNATLayersDetected`'s message with real confidence
  instead of today's necessarily hedged wording, and as a stronger
  prior for the RDAP-organization-walk auto-configuration idea — once
  RDAP names the ISP, knowing that ISP's *typical* deployment shape
  gives the walk something concrete to check the real trace against,
  rather than reasoning from the trace alone. Also relevant to
  corporate-mode's ISP-detection-logic concern: recognizing "this
  matches a known residential ISP deployment shape" is itself a signal
  that this probably *isn't* a corporate network, independent of
  whether the user has manually flagged it as one.

  **Web search is a real, already-proven research method for this, not
  a hopeful assumption** — it's exactly how tonight's Comcast finding
  got externally corroborated (forum threads independently describing
  `10.1.10.1` in the same role), not something untested being proposed
  fresh here. **Specifically enthusiast/prosumer forums, raised
  directly as the right kind of source** — official ISP documentation
  has no reason to ever publish this level of internal addressing
  detail, but people running their own router/firewall behind ISP-
  provided equipment (OPNsense, pfSense, Netgate, SNBForums, Xfinity/
  Comcast community forums, Reddit's networking communities) document
  exactly this kind of quirk as a matter of course, which is precisely
  where tonight's three corroborating sources came from.

  **A real complication, raised directly, that changes the shape of
  this from "one expected pattern per ISP" to "known patterns per ISP,
  layered by generation": networks live forever, so multiple
  generations of an ISP's own infrastructure are simultaneously in
  service, not sequentially replaced.** An ISP rolling out DOCSIS 4.0 or
  a new CPE model doesn't retroactively upgrade every existing
  customer's equipment — a connection installed years ago can still be
  running an older generation's addressing conventions, coexisting
  right now with brand-new installations on the current generation.
  Seeing an unfamiliar or "outdated"-looking pattern on a given ISP
  doesn't mean the ISP was misidentified or the data is stale — it may
  just be an older, still-legitimate deployment generation. Any real
  version of this needs to track *which* generations are known for a
  given ISP, not assume a single current shape, the same way this
  session's own two Comcast data points (an off-site network, a coffee shop) happened to
  agree only because they were probably provisioned close together in
  time — that agreement isn't guaranteed to hold against an older or
  newer installation on the same ISP.

  Not proposing to build anything yet — this is a research idea, and a
  substantial one (a handful of major ISPs' real architectures, across
  multiple generations each, not one address), worth scoping before
  committing to it.

- [ ] **Track known per-ISP hop patterns to speed up/sharpen
  recognition on future connections, instead of re-deriving everything
  from scratch on every trace.** Raised directly, prompted by exactly
  the finding right above: `10.1.10.1`/`docsis-gateway.hsd1.ca.comcast.net`
  showed up as hop 2 on two real, physically different Comcast
  connections this session (an off-site network, then a coffee shop). Recognizing
  that pattern on sight — "this specific address/hostname shape is
  Comcast's own DOCSIS infrastructure, not a customer's extra router" —
  would let `multipleNATLayersDetected` say something more specific and
  confident than today's necessarily hedged "could be an extra router
  of yours, or your ISP's — can't tell which from this alone," at least
  for ISPs/patterns already known.

  **Two different shapes this could take, real tradeoff between them**:
  - **A small, static, curated table shipped with the app** — same
    precedent as `SaaSStatusService.monitoredServices`: a hardcoded
    list, built from real findings (this session's two Comcast data
    points would be the first real entries), each one verified against
    an actual connection before being added, not guessed. Works
    immediately, even the first time a user's ever on that ISP —
    but only as current and complete as whatever's been manually
    curated, and needs updating as ISPs change their own infrastructure.
  - **Local, per-installation learning** — since this Mac's own
    `SnapshotStore` already tracks history across networks
    (`KnownNetwork`, `ProviderEdgeRecord`), it could notice "I've seen
    this exact hop address paired with this RDAP organization before,
    on a different network" without any curated list at all. Zero
    maintenance, but only helps after *this* installation has already
    encountered the pattern once itself — no help on a brand-new ISP or
    a fresh install, unlike the curated table.

  Not mutually exclusive — the curated table could ship a useful
  starting set for common ISPs, while local learning fills in whatever
  isn't already known. Both plug into the same two places: sharpening
  `multipleNATLayersDetected`'s message text for recognized patterns,
  and as a confidence signal for the RDAP-organization-walk
  auto-configuration idea elsewhere in this file — recognizing "this
  hop is known ISP infrastructure" is a real, independent data point
  when deciding whether an org-name change actually marks the ISP edge.
  Not proposing to build either shape yet — this is still just the
  idea, prompted by real, repeated evidence that at least one such
  pattern (Comcast's) is stable enough across locations to be worth
  recognizing at all.

- [ ] **A short-name/brand mapping layer for RDAP registrant names,
  separate from the existing status-page table.** Raised directly:
  RDAP returns real legal-entity strings (`"Comcast Cable
  Communications, LLC"`, `"Sonic.net, LLC"`), not the brand a customer
  actually recognizes — and one brand can resolve to *several* different
  legal names depending on subsidiary/historical acquisition, not just
  one. Already confirmed, not hypothetical: `ISPIdentityService
  .statusPages`'s own doc comment records that Astound Broadband (the
  current brand for what used to be marketed as RCN, Grande, and Wave
  in different regions) turned up three distinct real ARIN registrant
  names — `"Astound Broadband LLC"`, `"RCN Corporation"`, and bare
  `"RCN"` — depending on which legacy entity's allocation a given
  customer's address falls under. See `DESIGN-NOTES.md`'s new "How NMS
  uses RDAP" section for the full reasoning and how this connects to
  the RDAP-organization-walk idea elsewhere in this file.

  **Shape**: a many-legal-names-to-one-brand table
  (`[String: String]`, same type as `statusPages` but a different
  mapping — several keys can point to the same display value), checked
  in independently from whether that brand also has a linkable status
  page. `ISPIdentityViewModel.organizationName` would display the
  mapped brand when a match exists, falling back to the raw RDAP name
  otherwise — same "don't guess, only show what's confirmed" posture
  `statusPages` already uses, not a heuristic name-shortener. Same
  build discipline too: one real, verified entity name added at a
  time (Astound's three are the first real seed), not a speculative
  table covering every ISP up front.

  **Not just cosmetic** — this also feeds the RDAP-organization-walk
  idea directly: if the walk is comparing "does this hop's org match my
  own ISP's" using raw legal names, two different legal names for the
  *same* real brand (Astound's three, or any similar case not yet
  found) would incorrectly read as a mismatch. Resolving both names to
  the same brand before comparing is a real accuracy improvement for
  that walk, not just a display nicety for the Info tile.

  **How to actually build this, checked directly rather than assumed**:
  general web search reliably finds the *acquisition history* (Wikipedia,
  SEC filings, press releases, industry M&A trackers) — confirmed live:
  a quick search correctly surfaced Charter/Time Warner Cable/Bright
  House's merger history, and turned up real, current 2026 activity
  (Verizon completing its Frontier acquisition Jan 20, 2026 and its
  Starry acquisition Jan 30, 2026; Cable One agreeing to acquire the
  rest of Mega Broadband Investments/Vyve Broadband) — evidence the
  subsidiary landscape keeps moving, not a one-time list to compile.
  **But search can't substitute for the direct RDAP/ARIN query** to
  confirm which exact legal-entity string(s) a given subsidiary's IP
  allocations actually resolve to today — that step already has a
  working precedent in this exact codebase (`statusPages`'s own doc
  comment: "checked live via ARIN's org search," which is how Astound's
  three names were actually found, not searched for). The realistic
  build process: use web search to find *candidate* subsidiary/
  acquisition names worth checking, then verify each one's real RDAP
  registrant string(s) directly before adding it — same two-step
  shape as the per-ISP hop-pattern idea's own "web search, then
  cross-check against a real live trace" method above, just aimed at
  ARIN/RDAP instead of a live traceroute.

- [ ] **A "Corporate" mode feature flag — avoids probes that could trip
  a security alarm on an actively managed network, and separately
  changes the ISP-detection logic.** Raised directly. Two distinct
  concerns bundled under one flag, worth naming separately since one is
  about courtesy/safety and the other about correctness:

  1. **Avoiding probes that look like reconnaissance to a monitored
     network's own security tooling.** `FeatureFlags.snmpDevices`
     already gates SNMP scanning off by default for a related but
     narrower reason — its own doc comment says a friend testing on
     their own network "hasn't necessarily reviewed or approved NMS
     probing their devices." That's a *consent* framing; this is a
     *detection* one, and covers more surface than just SNMP:
     - `SNMPViewModel.candidateAddresses()`'s subnet sweep plus
       community-string guessing (`public`, `thistle`, ...) against
       every candidate address is close to a textbook SNMP-sweep/
       credential-guessing signature — exactly what a corporate SOC's
       IDS/IPS watches for, regardless of whether the SNMP feature flag
       itself is otherwise wanted on.
     - `DeviceWebDetectionService`'s per-device port probing (HTTPS,
       then HTTP, then HTTPS on `4343`) across every discovered device
       is a small port scan, same category of concern.
     - The neighboring "use SNMP against the router/switch to discover
       devices on large subnets" idea, and the already-existing
       fallback behavior on a subnet too large to sweep host-by-host,
       both assume active sweeping is fine by default — worth
       reviewing once this flag exists, since "too large to sweep
       automatically" and "shouldn't sweep automatically here" are
       different reasons to hold back that happen to produce the same
       restraint.
     - Traceroute/ICMP pings are lower risk — common, expected
       diagnostic traffic most network security tooling doesn't alert
       on — probably fine to leave as-is even in this mode, but worth
       confirming rather than assuming once the flag is real.
  2. **The ISP-detection logic needs to behave differently on a
     corporate network, not just probe less.** Already documented
     elsewhere in this file (the RDAP-organization-walk idea): the
     naive "first non-RFC1918 hop" heuristic misidentifies a corporate
     network's own border router as the ISP edge, and a traditional
     corporate WAN using real public IP addresses internally breaks the
     heuristic even more fundamentally. A "Corporate" flag is the
     natural place to hang that different behavior on directly — e.g.
     suppressing the naive auto-guess entirely, defaulting to the
     RDAP-walk's tier-3 "explain what was found, ask" behavior instead
     of ever auto-configuring, or relabeling "ISP" to something like
     "Network Operator" once the identified organization is at least as
     likely to be the company's own transit provider (or the company
     itself, if it holds its own address space) as a consumer ISP.

  Following `FeatureFlags`' own established convention: off by default,
  opt-in — a home user never needs this, so it should cost nothing
  until someone who actually knows they're on a monitored corporate
  network turns it on.

  **Refined, raised directly: not one monolithic on/off switch —
  selectable, per-probe-category toggles**, since the probes named
  above don't all carry the same risk, and someone who knows their own
  network's monitoring posture may want to keep some on. E.g. a network
  with a permissive security team might tolerate traceroute/ICMP and
  even SNMP polling of manually-added devices, while still wanting the
  subnet-wide sweep and community-string guessing off — a single
  all-or-nothing flag can't express that. Concrete candidate toggles,
  each mapping to one of the specific probes already named above:
  - Subnet-wide SNMP sweep (`SNMPViewModel.candidateAddresses()`'s
    address enumeration)
  - SNMP community-string guessing/polling itself, independent of the
    sweep — lets someone manually add specific known-safe devices
    without ever auto-discovering the rest of the subnet
  - Per-device web-detection port probing (`DeviceWebDetectionService`)
  - ISP-edge auto-guessing / the RDAP-organization-walk, once built
    (a correctness toggle more than a safety one, but still fits the
    same "give explicit control back" shape)

  This already has a direct precedent in this exact codebase to follow
  rather than invent fresh: `FeatureFlags.saasMonitoring` (one master
  on/off) paired with `saasEnabledServices` (which specific services,
  once the master is on) — same two-tier shape, master flag plus a
  finer per-item selection, just applied to probe categories instead of
  monitored SaaS vendors.

  **Also now scopes a question from the AI-assisted-troubleshooting
  design discussion elsewhere in this file**: if AI intents ever grow
  past read-only (triggering a fresh check, a re-scan, anything that
  generates its own network traffic), "Corporate" mode's per-category
  toggles are the natural place to gate what an AI backend is allowed
  to *ask* NMS to do, too — not just what NMS already does on its own.
  An AI assistant re-triggering an SNMP sweep on someone's behalf on a
  monitored network is exactly the same risk this whole item exists to
  avoid, just with a different trigger.

- [ ] **Determine how many hops separate this Mac from where its public
  IP actually becomes real — is the NAT happening right at the local
  router, or much farther away (typical of CGNAT or a corporate WAN)?**
  Raised directly, from a real, live case this session already
  produced by accident, not a hypothetical: at an off-site network, Path to
  Internet's own trace shows hop 3 (`203.0.113.20`) as the first
  public address — matching `multipleNATLayersDetected`'s "Multiple
  layers (2 hops)" finding — but that address is **not the same** as
  this connection's actual detected Public IP (`203.0.113.10`,
  confirmed independently via both `PublicIPViewModel` and a direct
  RDAP lookup this session). Two different real numbers, both genuine,
  both public.

  **Why that gap matters, and why it's a different question than the
  one already answered**: `leadingNonInternetHopCount`/
  `multipleNATLayersDetected` (`TracerouteViewModel.swift`) already
  answers "how many RFC1918/CGNAT-range hops precede the first public
  address" — a question about *address classification* per hop. This
  is a different question: *does any hop's address literally match the
  externally-detected Public IP*, and if so, at which hop? A traceroute
  hop's address is that router's own interface answering the ICMP probe
  — for a NAT device, that's its own management/WAN address, not
  necessarily the translated source address it stamps onto outbound
  packets, which on real carrier-grade NAT gear is commonly a *different*
  address on a shared pool entirely. The off-site network's trace is exactly this
  case: hop 3 is genuinely public and genuinely the first non-private
  hop, but it's a different address from the one the rest of the
  internet actually sees this connection as — meaning the real
  translation point is invisible to traceroute, farther out than
  anything reached, even though only "2 hops" of private addressing
  were counted.

  **Confirmed a second time, at a different real location (a coffee
  shop), same ISP — this is a recognized, recurring Comcast
  pattern, not a one-off**: hop 2 there was `10.1.10.1`, hostname
  `docsis-gateway.hsd1.ca.comcast.net` — the *exact same private address*
  as the off-site network's hop 2, a completely different physical connection. That's
  real evidence Comcast reuses `10.1.10.1` as a standardized internal
  label for the DOCSIS gateway's management interface across many
  subscriber connections, not a shared customer-facing NAT pool — while
  the actual public IP one hop further out differed between the two
  locations (`203.0.113.30` at the cafe vs. `203.0.113.20` at
  the off-site network), confirming each connection still gets its own distinct
  public identity. Worth noting directly: `10.1.10.1` itself is an
  ordinary RFC1918 address, not in the CGNAT-reserved range
  (`100.64.0.0/10`) `IPClassifier.isCGNAT` checks for — so this
  correctly stays the hedged "could be an extra router of yours, or
  your ISP's" message today, not the confirmed-CGNAT one, which is the
  right call given what these two real traces actually show.

  **Externally corroborated, not just this app's own two observations**:
  a web search turned up multiple independent, unrelated sources
  describing `10.1.10.1` as Comcast's standard internal DOCSIS gateway/
  modem management address — including an OPNsense forum thread titled
  literally
  ["Comcast Business 10.1.10.1"](https://forum.opnsense.org/index.php?topic=6878.0),
  plus a [Netgate forum thread](https://forum.netgate.com/topic/187471/comcast-static-ip-30-setup-help-needed)
  and a [Cisco Community thread](https://community.cisco.com/t5/small-business-security/isa570w-static-route-to-comcast-gateway-modem/td-p/2285824)
  discussing the same address in the same role. This is a widely
  recognized convention among people who run their own router behind
  Comcast equipment, not a coincidence specific to these two real
  connections — real, independent grounding for the per-ISP
  hop-pattern-tracking idea elsewhere in this file, beyond just this
  session's own two data points.

  **Both pieces of data this needs already exist in the app,
  unconnected**: `TracerouteViewModel.hops` (each hop's address) and
  `PublicIPViewModel.currentIP` (the independently-fetched real public
  identity). A cheap first version: check whether any hop's address
  equals `publicIP.currentIP` — a match at hop 2 says "the NAT is right
  here, adjacent, simple single-NAT home setup"; no match at all, even
  after reaching a genuinely public hop, says "the real NAT boundary is
  further out than this trace can see" — itself a meaningful, distinct
  finding from "multiple private hops," as the off-site network's case demonstrates
  live.

  **Directly relevant to two other open items in this file**: the
  RDAP-organization-walk idea (auto-confirming the ISP Edge Router hop)
  would benefit from knowing this distinction rather than just walking
  org-name changes blind, and the "user depending on inbound
  connections (VPN/DNAT)" persona item cares about exactly this fact —
  a hidden, far-away CGNAT boundary breaks inbound port-forwarding
  regardless of any local router configuration, which is precisely what
  "how many hops until the public IP becomes real" would surface
  directly instead of leaving inferred from a private-hop count alone.

  **A more authoritative alternative, raised directly, when SNMP is
  available**: rather than inferring the NAT boundary from traceroute
  and an external Public IP lookup, ask the local router directly —
  its own upstream/WAN interface address (`ipAddrTable`) says outright
  whether *it* is already holding the real public IP, and its route
  table's next hop (`ipRouteTable`) points straight at the next device
  toward the ISP edge, no ICMP/traceroute inference needed. **Corporate
  WANs will be more complicated** (multiple routes, tunnels, possibly
  more than one exit point) — flagged directly as the harder case this
  wouldn't cleanly generalize to. Real-world availability check, not
  assumed: this depends entirely on item 8 below ("Cross-check the
  router's own interfaces/routes via SNMP"), which just found a genuine
  split — the home router answers standard IP-MIB SNMP fine, but
  the off-site network's ASUS RT-AC68P answers none at all (stock ASUS firmware has
  no SNMP support whatsoever, confirmed via web search, not just the
  live timeout). So this authoritative path is real *when available*,
  but traceroute-plus-Public-IP-correlation is still the only
  universally-applicable version — it needs nothing from the router
  itself.

- [ ] **Idea: build Mermaid network diagrams from the SNMP-discovered
  topology, rendered via an external link rather than in-app.** Raised
  directly, right after this session's own live SNMP verification (see
  the neighboring "Use SNMP against the router/switch itself..." item
  above) produced exactly the data a diagram needs: this network's real
  router→switch→{ap1, ap2, printer, ...}→client topology, cross-
  validated across the router's ARP table and two devices' bridge
  forwarding tables in the same session.

  **Scope, raised directly and worth being explicit about: this covers
  every IP-active device the ARP/FDB walk finds, not just SNMP-
  responsive ones.** SNMP is the *discovery mechanism* (asking the
  router/switch/AP what they already know), not a filter on what
  appears as a node. Concretely, of the ~15 devices this session's real
  walk found, only 4 (router, switch, ap1, ap2) answer SNMP themselves
  — the rest (the printer, a likely Raspberry Pi, several unlabeled
  hosts) are ordinary clients that only show up because the SNMP-
  capable infrastructure reports them in its own tables.

  **A real data-model gap this scope question exposed, correcting an
  overclaim above: "the data already exists" is true only for this
  session's ad hoc `snmpwalk` output, not for anything the app itself
  currently models.** Checked `SNMPDeviceRecord.swift` directly — it
  stores `ipAddress`/`sysDescr`/`sysName`/`uptimeTicks`/`community`/
  `webURL`/`hostname` and timestamps, nothing about which port or
  parent device a MAC was learned from. `SNMPViewModel` today produces
  a flat list of SNMP-responsive devices, not a topology graph. Every
  port/VLAN/parent relationship used to build this session's tables
  and diagrams came from raw SNMP responses parsed by hand, not from
  anything persisted or modeled by the app — building the actual
  topology mapping (which MAC is attached via which port of which
  device) is new data-model work, not just wiring an existing list into
  a Mermaid template.

  **Idea, raised directly, that both resolves the scope question above
  and the URL-length scaling concern below: make it hierarchical.** A
  top layer covering just SNMP-responsive infrastructure (router,
  switch, ap1, ap2 — exactly `SNMPViewModel`'s existing device list,
  needing none of the new topology modeling above), with each
  infrastructure node linking to its own lower-layer diagram (that
  device's attached clients) rather than one flat diagram for the whole
  network. Confirmed live, not assumed, that this is technically real
  and not just plausible-sounding: Mermaid's `click NodeID "URL"`
  directive survives into `mermaid.ink`'s SVG output as a genuine
  `<a xlink:href="...">` wrapping that node's SVG group — verified by
  building a real top-layer diagram, fetching its rendered SVG, and
  finding the actual anchor tag pointing at a second (lower-layer)
  mermaid.ink URL. Opened as a real document (this app's existing
  `NSWorkspace.open` pattern navigates the browser directly to the URL,
  not an `<img>` embed), that link is genuinely clickable — no in-app
  code needed for the drill-down itself, just generating each layer's
  URL and one `click` line per infrastructure node pointing at the
  next. Also means each generated link only ever needs to encode one
  layer's worth of devices, not the whole network at once — the same
  fix in different words as the URL-length concern below.

  **Rendering, not data, is the real question — and it doesn't need
  what it first looked like it would.** This app has zero `WKWebView`
  usage today (checked), so rendering Mermaid *inline* in the popover
  or window would be genuinely new infrastructure. But an external
  link sidesteps that entirely, and this app already has the exact
  mechanism for it: `Link`/`NSWorkspace.open` via `externalLinkIcon`,
  the same pattern already used for the Local Router link, the ISP
  status page, and SNMP device web-detection
  (`ContentView+Window.swift`). Opening a diagram link in the system
  default browser needs no new UI infrastructure at all.

  **Verified live, not assumed, that a working link is actually
  possible**: `mermaid.ink` accepts a diagram's raw text as **plain
  URL-safe base64** — no pako/zlib compression needed — at both
  `/img/<base64>` (returns a JPEG) and `/svg/<base64>` (returns an
  SVG). Confirmed by building a real 6-node flowchart (`Router →
  Switch → AP1/AP2/Printer`, `AP1 → ClientA`, using placeholder labels,
  not this network's real MACs — see the privacy note below for why),
  base64-encoding it, and fetching both endpoints: both returned HTTP
  200, and the returned SVG's actual node/edge markup was read back and
  confirmed correct, not just the status code. Because the response is
  a raw image (`image/svg+xml`/`image/jpeg`), not an HTML page
  embedding one, any browser — including opening the link via this
  app's existing `NSWorkspace.open` pattern — displays it directly with
  no plugin or JS involved. Trivial to generate from Swift:
  `Data(mermaidText.utf8).base64EncodedString()` with the usual
  `+/=` → `-_`/none URL-safe substitution — no external library needed.

  A second option exists but is meaningfully more work and wasn't
  verified this session: `mermaid.live` (the interactive editor, as
  opposed to mermaid.ink's direct image) uses a different URL format —
  a pako/zlib-deflate-compressed, base64'd JSON payload
  (`#pako:...`) — which would need Swift's `Compression` framework
  (zlib is available there) rather than a one-liner. Worth checking
  whether the simpler, already-confirmed mermaid.ink link is good
  enough before ever building that.

  **A real privacy consideration, not hypothetical — tied to precedent
  already in this codebase**: `mermaid.ink` is a third-party service. A
  diagram link built from real discovered data would carry this
  network's actual device identifiers (MACs, hostnames, IPs) to an
  external server — the same category of concern that already made the
  iMac session pull two real-network screenshots from this repo's own
  GitHub history this session (see issue #6's 2026-08-02 comment). Any
  such link should be an explicit, visible user action ("Generate
  diagram link" button, never auto-embedded or silently pre-fetched)
  with it clear the data is leaving the device — not silently-on the
  way e.g. `DeviceWebDetectionService`'s outbound probes already are,
  since those stay LAN-local and this wouldn't.

  **Scaling limit, untested**: URLs have practical length ceilings
  (~8000 characters is the usual safe bound across browsers/servers),
  and base64 costs ~33% overhead on top of the raw diagram text. Fine
  for a small home network's dozen-ish devices (this session's real
  topology test included), untested at whatever scale
  `SubnetCalculator.maxSweepHosts`/`subnetTooLargeToScan` already draws
  a line at for SNMP sweeping itself. The hierarchical design above is
  exactly the fix if this turns out to matter in practice — each
  layer's link only ever encodes that layer's own devices, not the
  whole network at once.

  Not proposing to build yet — this is confirmation the mermaid.ink
  route specifically is viable (verified live), narrower and simpler
  than the original vaguer "some external Mermaid tool" idea.

  **Follow-up: actually mapped every non-SNMP device to its real
  upstream device (Switch/ap1/ap2), not just flattened under Router —
  and confirmed two things worth recording.** Neither AP implements
  `dot1dBasePortIfIndex` (checked, unsupported), but each AP's non-zero
  `dot1qTpFdbPort` values matched its own `ifDescr` directly (`2`=
  `eth1`, `50`=`radio0_ssid_id0`, `51`=`radio0_ssid_id1`,
  `71`=`radio1_ssid_id1` — real interfaces), while port `0` — which
  nearly every MAC showed, including the router's own — has no matching
  `ifDescr` entry at all, the same "shared port = uplink visibility,
  not attachment" shape as the switch's Gi3. Trusting only non-zero
  ports produced a genuine validation: the iPhone showed ambiguous port
  `0` on ap1 but a confident radio port (`50`) on ap2 — it's actually
  associated with ap2, and only visible to ap1 via the shared backbone.
  Cross-checking both APs, not trusting either in isolation, is what
  caught this — matches this file's own house style of verifying
  rather than trusting a single source.

  **The remaining ambiguity (three-plus MACs sharing one switch port,
  Gi6) is confirmed real, not hypothetical — this network has two
  desktop Ethernet switches that don't speak SNMP at all.** An
  unmanaged switch is a genuine, permanent blind spot for this whole
  approach: it never answers an SNMP poll, never gets its own node, and
  every device behind it just appears to share whatever managed port
  it's plugged into — indistinguishable, from SNMP alone, from several
  devices that happen to have been learned on the same port over time.
  Worth stating plainly for any real implementation: "attached to
  Switch port Gi6" is as confident as this method gets when a port
  hosts multiple MACs; "directly, individually wired to Gi6" is not
  something SNMP alone can confirm, and sometimes (confirmed on this
  network) it's flatly false.

- [ ] **Track VLAN ID ↔ IP subnet mapping as part of the discovered
  topology.** Raised directly, after repeatedly needing to reason about
  which VLAN a device or subnet belonged to this session
  (`ipNetToMediaTable`'s `ifIndex` 21 vs. 22 split, the APs'
  VLAN-tagged FDB context groups) with no structured way to track it —
  every pass re-derived it by hand.

  **Real mappings found this session, cross-validated across
  independent sources, not asserted from one table alone:**
  - **VLAN 1 ("default") = `10.0.0.0/24`** — this network's main LAN.
  - **VLAN 102 = `10.0.102.0/24`, and has a real name: "ThistleGuest"**
    — confirmed via the switch's `dot1qVlanStaticTable`
    (`1.3.6.1.2.1.17.7.1.4.3.1.1.102`), i.e. the guest network.
    Cross-validated three independent ways: the router's
    `ipNetToMediaTable` `ifIndex 22` entries, ap1's `dot1qTpFdbTable`
    VLAN-102 context group (same MACs, same IPs), and now the switch's
    own VLAN name table — three sources agreeing, not one assumed.
  - **VLAN 4088 ("Auto-VoIP") and 4089 ("Auto-Video")** — defined on
    the switch (a standard NETGEAR auto-VLAN feature for LLDP-MED-
    detected devices), but no IP address in any table this session
    fell in either — possibly QoS-tagging-only VLANs with no distinct
    subnet of their own, genuinely unconfirmed either way.
  - **VLAN 3333 — subnet unknown.** Seen only as a tag in ap1/ap2's own
    FDB self-entries, absent from the switch's static VLAN table
    entirely, and no IP address observed in it anywhere this session —
    possibly AP-to-AP mesh/backhaul traffic invisible to the switch,
    not resolved.
  - The router's `ifIndex 6` (`192.184.x`) is a different case
    entirely, not a VLAN — the WAN-side neighbor table.

  **Sources found this session, most to least reliable:**
  1. `dot1qVlanStaticTable` (`1.3.6.1.2.1.17.7.1.4.3`) — canonical, ID
     *and* human name in one place. Confirmed on the switch; **not
     supported on the router** (checked — different vendor/OS, no
     Q-BRIDGE-MIB at all).
  2. The router's own interface-naming convention (`ifDescr`:
     `eth0.102`, `br-lan_102`) — works where (1) doesn't, but is a
     vendor naming convention, not a standard MIB table.
  3. Cross-referencing `ipNetToMediaIfIndex` groupings against either
     of the above.

  **Data-model gap, checked directly**: zero VLAN concept exists
  anywhere in this app today — `grep -rl vlan NMS/` turns up exactly
  three doc-comment mentions (`KnownNetwork.swift`,
  `SubnetCalculator.swift`, `SNMPViewModel.swift`), all prose
  explaining why per-network fingerprinting needs more than router MAC
  alone, none of them an actual `vlanID` field or a VLAN↔subnet table.
  Directly relevant to the Mermaid-diagram work above: an accurate
  topology already needed VLAN-awareness to explain the router's
  `ifIndex` split, and the mapped non-SNMP-device diagram above only
  works because this session tracked VLAN grouping by hand, in one
  chat, with nothing persisting it afterward. Not proposing a specific
  data model yet — flagging the need and the real, verified sources a
  future implementation would build from.

- [ ] **The Events list will grow long over time; someone chasing a
  real problem needs to isolate genuine changes — especially a
  configuration change on some other local system (a router, a
  server) — from ordinary reachability noise.** Raised directly, with
  that specific motivating scenario: a flaky Wi-Fi network can log
  dozens of up/down blips a day in the same flat, chronological
  `eventList`/`eventRows` (`ContentView+Window.swift`) that also
  carries the handful of entries per week that actually matter for
  root-causing something — no grouping, no filter, nothing beyond
  message text and red/green/neutral color (`eventColor`) to tell them
  apart today.

  **Concrete example use case, also raised directly: a field
  technician using NMS to discover rogue configuration changes** —
  someone else's DHCP settings, router, or SNMP-managed device getting
  reconfigured without authorization, on a network the technician is
  responsible for but doesn't sit on all day. A "changes only" filter
  is exactly the tool for that: skim past routine up/down noise
  straight to "what got reconfigured."

  **One real limitation this persona exposes that the general
  "someone chasing a problem" framing above doesn't**: every
  change-detecting event in this app, `multipleNATLayersDetected`
  included, is deliberately suppressed on the very first trace/check
  each session — `logAddressingChangeIfNeeded`
  (`TracerouteViewModel.swift`) has nothing to compare against yet, by
  design, so it doesn't fire "you're double-NAT'd" as if it just
  happened when it's simply where the network already was (confirmed
  in code, `lastKnownExtraNATState`'s doc comment). That's correct for
  routine monitoring but means a technician arriving cold to a site
  NMS has never run against gets **no Events-log signal for a rogue
  change that already happened before they walked in** — there's
  nothing to diff against yet. What already works cold, and doesn't
  need this filter at all: current-*state* views that don't depend on
  history — the live SNMP Devices list, the live Path to Internet hop
  list (an unexpected extra hop is visible by just looking, whether or
  not an event ever logged it), current DHCP lease info. The filter
  this item proposes helps with changes happening *during* a
  monitoring window — leave NMS running through a site visit or a
  longer engagement and see what changes while watching — not a
  retroactive audit of changes that predate that window starting.

  Worth distinguishing from the already-decided "decide against
  folding DHCP History into Events" above: that item was about folding
  DHCP History's *per-lease detail* into Events' one-line row shape,
  rejected because the two serve different granularity. This is about
  the one-line Events *entries* every subsystem already produces
  today, and which of them represent a real change worth isolating.

  **Walking every `AppEventKind` case against "did something's
  configuration actually change" turned up a cross-cutting split, not
  a per-subsystem one** — filtering by subsystem (DHCP / SNMP /
  Connectivity) would misfile things, since e.g. `dhcpLeaseChanged` and
  `dhcpFellBackToLinkLocal` are both "DHCP" but only one is a
  configuration signal:
  - **A setting genuinely changed on another system** —
    `dhcpLeaseChanged` (the DHCP server, typically the router, handed
    back a materially different lease: new server, address, or
    timing — the router's own DHCP config changing) and
    `snmpDeviceSoftwareChanged` (an SNMP device's `sysDescr` changed,
    meaning its firmware/software did — literally "someone
    reconfigured or updated a device"). The two clearest members.
  - **Ambiguous — ISP or local, and the app already documents that it
    can't tell** — `multipleNATLayersDetected` (an extra NAT hop
    appearing/vanishing could be a router you added, or the ISP
    switching you onto CGNAT; traceroute alone can't distinguish, per
    that kind's own doc comment) and `publicIPChanged` (usually just
    an ISP lease renewal, not a change on your side, but not always
    distinguishable from one). `snmpDeviceRestarted` actually leans
    *away* from config-driven — it's logged specifically when nothing
    else explains the restart, and a real firmware push almost always
    shows up as `snmpDeviceSoftwareChanged` instead, since the version
    string changes too.
  - **This Mac's own attachment changing, not another system's
    config** — `interfaceChanged` (Ethernet↔Wi-Fi) and
    `wifiNetworkChanged` (roamed SSIDs): real changes, but of this
    machine's environment, not something a router or server operator
    did.
  - **Not configuration changes at all — reachability flipping, the
    actual noise to suppress** — every up/down pair:
    `interfaceDown/Up`, `router-/internet-/dns-/http-/peRouter-/
    infrastructure-/publicIP-Unreachable/Reachable`,
    `dhcpFellBackToLinkLocal/dhcpAddressRestored`,
    `dhcpRenewalOverdue/Recovered`, `saasServiceDown/Recovered`.
  - **Not network-related, or not a change** — `screenshotCaptured`/
    `bugReportCaptured` (user-triggered) and `subnetTooLargeToScan`
    (one-time fact, no delta, no recovery pair, so nothing to compare
    against anyway).

  **What the triage above actually is: a second axis on `AppEventKind`,
  the same shape as `polarity` but orthogonal to it** — `polarity`
  answers "is this good, bad, or neutral news"; this answers "is this
  routine up/down state, or a genuine change to something's
  configuration/identity." A straight binary would overclaim, though —
  `snmpDeviceRestarted`/`multipleNATLayersDetected`/`publicIPChanged`
  are real changes but of *ambiguous* cause (device config, or just a
  power blip / ISP-side renewal — the app already can't tell), so
  forcing them into either "reachability" or "configuration" would
  assert certainty the underlying data doesn't have. Sketched as a
  third case rather than force-fit, mirroring `polarity`'s own
  `enum`-plus-`switch` shape in `AppEventRecord.swift`:
  ```swift
  enum ChangeCategory {
      case reachability      // up/down pairs: interfaceDown/Up,
                              // router-/internet-/dns-/http-/peRouter-/
                              // infrastructure-/publicIP-Unreachable/
                              // Reachable, dhcpFellBackToLinkLocal/
                              // dhcpAddressRestored, dhcpRenewalOverdue/
                              // Recovered, saasServiceDown/Recovered
      case configurationChange // dhcpLeaseChanged, snmpDeviceSoftwareChanged
      case ambiguousChange   // multipleNATLayersDetected, publicIPChanged,
                              // ispOrganizationChanged, snmpDeviceRestarted,
                              // interfaceChanged, wifiNetworkChanged
      case notApplicable     // screenshotCaptured, bugReportCaptured,
                              // subnetTooLargeToScan
  }
  ```
  A "Changes only" filter would then mean
  `category != .reachability && category != .notApplicable` — showing
  `configurationChange` and `ambiguousChange` together (both are real
  changes worth seeing when chasing a problem) while still being honest
  elsewhere in the UI (icon, grouping, whatever ships) that only
  `configurationChange` members carry real confidence about the cause.

  Two directions, not mutually exclusive, now that the split is
  concrete:
  - **Filter the single list** — a toggle/picker over `ChangeCategory`
    (not a per-subsystem one) scoped to `eventRows`. Keeps one source
    of truth, one row shape, and the cross-subsystem correlation this
    list is good for — a router power-cycle showing as a DHCP renewal,
    an SNMP restart, and an interface flap all landing within seconds
    of each other, exactly the "Events is a shared cross-subsystem
    list" case the DHCP-into-Events decision already argued for
    keeping merged.
  - **A dedicated log** for just the configuration-change members —
    closer to how DHCP History and the SNMP Devices list already work
    as their own sections, but would fragment the one place that
    currently shows "what changed, in order, across every subsystem" —
    the same argument that kept DHCP History's detail *out* of Events
    applies in reverse here: splitting these events *out* loses the
    cross-subsystem ordering that makes the correlation case above
    possible.

  No strong signal yet on which real networks actually produce enough
  configuration-change volume to make this worth building — worth
  watching real Events lists (this network's included) before
  choosing. A network logging one of these a week doesn't need a
  filter; one logging several a day probably does.

- [ ] **A user depending on inbound connections (a self-hosted VPN
  server, a port-forwarded/DNAT'd service) needs different signal than
  the default persona — and NMS currently has zero visibility into
  actual inbound reachability at all.** Raised directly, continuing
  the Events-filtering item above with a specific persona in mind.
  Two of the events already discussed there matter far more to this
  persona than their current treatment reflects, plus there's a real
  gap neither event touches:
  1. **`publicIPChanged`** (`PublicIPViewModel`, 5-minute cadence)
     already fires on every WAN address change — but for this persona
     it isn't neutral information, it's the single most actionable
     event in the whole log: any inbound rule pointing at the old
     address (a DNAT/port-forward entry, a VPN client's saved
     endpoint, anyone else's bookmark to the old IP) silently breaks
     the moment it fires, unless dynamic DNS sits in front of it.
     Today `AppEventKind.publicIPChanged` has `.neutral` polarity
     (`AppEventRecord.swift`) — a reasonable default (most users don't
     track their own WAN IP), but undersells it badly for this one.
  2. **`multipleNATLayersDetected`/CGNAT**
     (`TracerouteViewModel.leadingNonInternetHopCount`) already fires
     when an extra NAT layer appears. `DESIGN-NOTES.md`'s AI-assisted-
     troubleshooting sketch already names the real consequence
     directly — "doesn't explain an outage, explains a standing
     limitation: port forwarding won't work as expected" — but that
     reasoning currently lives only inside an unbuilt troubleshooting-
     advice feature, not surfaced anywhere as urgent to this persona
     today.
  3. **Actual inbound reachability has no signal at all, and nothing
     else in this app can lean on one.** Every existing check
     (`ConnectivityViewModel`'s Router/Internet/DNS/HTTP/ISP-Edge-
     Router pings, the SaaS status pages) is outbound-initiated from
     this Mac — none of them confirm the world can still reach *in*.
     Even with a stable public IP and no CGNAT, NMS has no way to know
     whether the router's own port-forward/DNAT rule is still
     correctly configured (that lives in the router's own rule table,
     invisible to standard SNMP MIBs) or whether an ISP-side firewall
     silently started blocking the port. Confirming a forwarded port
     is actually reachable would need a genuinely external vantage
     point — a "can the internet see me" probe against some public
     checking service — a different kind of dependency than anything
     else this app currently calls out to.

  Not proposing to build any of this yet. (1) and (2) already have the
  underlying data and mechanism; what's missing is a way to tell NMS
  "I depend on inbound access" so it can treat those two differently
  for that user (no such preference exists today — checked
  `PreferencesView.swift`/`FeatureFlags.swift`, nothing there
  distinguishes this persona). (3) is a real gap with no existing
  mechanism to build on, unlike (1) and (2).

- [x] ~~Add GitHub to the SaaS monitoring list.~~ **Built.** Confirmed
  live via `curl` first (`www.githubstatus.com`, standard `.statuspage`
  shape, healthy at verification time), then added as a plain
  `MonitoredService` entry. `PreferencesView.swift`'s description text
  updated to include it.

- [x] ~~Add Cloudflare, Figma, HubSpot, and Docusign to the SaaS
  monitoring list.~~ **Built.** All four confirmed live via `curl` first
  and added as plain `.statuspage`-shaped `MonitoredService` entries —
  zero new parsing code:
  - Cloudflare: `https://www.cloudflarestatus.com/api/v2/summary.json`
    (confirmed live *during* a real "Minor Service Outage" — not just
    the healthy path)
  - Figma: `https://status.figma.com/api/v2/summary.json`
  - HubSpot: `https://status.hubspot.com/api/v2/summary.json`
  - Docusign: `https://status.docusign.com/api/v2/summary.json`

  Also updated `PreferencesView.swift`'s "Periodically checks the
  public status pages of..." description text to include all four.

  **Three other obvious candidates checked and found not to be
  drop-ins — don't re-attempt these the same way:**
  - **Stripe** (`status.stripe.com`) doesn't serve
    `/api/v2/summary.json` at all (404) — different shape or path,
    not confirmed.
  - **Okta** (`status.okta.com`) returns an HTML redirect page at that
    path, not JSON.
  - **Salesforce** (`status.salesforce.com`) explicitly blocks it:
    `{"error":"Direct API access not allowed"}` — a locked-down custom
    Trust site, not Statuspage.
  - **Intercom**'s old `intercomstatus.com` domain 301s to
    `finstatus.com` entirely (a status-page-vendor migration) — the
    old API path is just gone; whatever the new one is wasn't checked.

- [ ] **The in-app Screenshot/Bug Report capture doesn't render the same
  layout the live app uses — raised directly ("the screenshots don't
  seem to work... i can do manual screenshots faster"), and just caused
  a real diagnostic miss.** Found while fixing the "snmp needs more
  space for text" report (`NMS-2026-08-01-165919.png`, see `BUGS.md`):
  the attached screenshot showed the Switch device's `sysDescr` wrapping
  correctly across two lines — because `capture(_:)`/`captureBugReport(_:)`
  render `scrollableContent` with `isCapturingScreenshot = true`, which
  makes every `scrollBox`-boxed section (Events, SNMP Devices, DHCP
  History, Speed Test, traceroute hops) skip `NoBounceScrollView`
  entirely and render as a plain, unclipped `VStack` instead (see
  `scrollBox`'s own doc comment — this was deliberate, to work around
  `ImageRenderer` not rendering `NSViewRepresentable`/`ScrollView`
  content off-screen at all). The live window, going through the real
  `NoBounceScrollView`/`NSHostingView`, was actually truncating that
  same text to one line with a "…" — confirmed only by scrolling the
  real running app and comparing screenshots by hand, not by anything
  in the report itself. So the capture path's whole design (unclip
  everything so `ImageRenderer` has something to draw) makes it
  structurally unable to reproduce a layout bug that only exists
  *inside* the boxes it's deliberately avoiding — exactly the failure
  mode that prompted this report to begin with. Nothing built yet;
  worth a real pass on what a screenshot tool that can actually show
  `NoBounceScrollView` content would need (a different capture
  mechanism entirely, e.g. `screencapture`-driven against the real
  `NSWindow` rather than `ImageRenderer` against a modified copy of the
  view tree), weighed against just leaning on manual `screencapture` /
  the OS's own screenshot shortcut instead of maintaining this one.

- [x] ~~SNMP device web-detection prefers HTTP over HTTPS — a real
  security tradeoff, flagged directly, not yet reconsidered.~~
  **Fixed** by doing the "actually checking" option this item's own
  text called out, rather than a fixed protocol preference either way.
  `DeviceWebDetectionService.detectWebURL` now tries HTTPS *twice*: once
  with real, unmodified certificate validation (`strictSession` — no
  delegate override, so it accepts exactly what a real browser would
  accept without a warning) before HTTP, and once with the existing
  lenient trust-all session after HTTP, as a last resort ahead of the
  Aruba `4343` port. A device with a genuinely valid, modern cert now
  gets its encrypted link automatically; a device with a self-signed or
  outdated-TLS cert (confirmed live: this network's own printer) falls
  through to HTTP exactly as before, since `strictSession` correctly
  fails there the same way a real browser would. Verified against the
  real network end-to-end (not just built): relaunched the app and
  confirmed via `ui-state.log` that the printer and every other real
  device on this network still resolve to their working `http://` URL,
  with the strict-HTTPS path now genuinely exercised (and correctly
  failing) ahead of it rather than skipped. No user-facing preference
  added — this was the "just make the code correct" fix, not a decision
  that needed exposing as a setting.

  **Known, accepted verification gap, stated directly**: every device
  on this network lacks a browser-trusted certificate, confirmed live
  (all five — router, switch, both APs, printer — fell through to
  HTTP). That exercises and confirms the *failure* branch of
  `strictSession` correctly, but the "a device genuinely has a valid
  cert, so HTTPS wins automatically" branch this fix exists for has
  never actually succeeded against real hardware, on this network or
  any other checked so far. The logic is straightforward enough to
  trust by inspection (it's exactly what `URLSession` does by default
  with no delegate override, the same validation any ordinary networking
  client performs), but "trusted by inspection" and "confirmed working"
  are different claims — this is the former only, same honesty this
  file already applies to Printer Alerts' own never-triggered true
  positive.

- [ ] **Use SNMP against the router/switch itself to discover devices on
  subnets too large to sweep, instead of a raw IP sweep.** Follows
  directly from the just-shipped fix restricting
  `SNMPViewModel.candidateAddresses()` to strictly the current subnet
  (see DESIGN-NOTES.md's "A router serving two VLANs..."): above
  `SubnetCalculator.maxSweepHosts` (1024 hosts, e.g. a `/21` or larger —
  or the real `/8` case raised directly this session), the app now
  correctly refuses to brute-force every address and falls back to just
  the gateway, logging `.subnetTooLargeToScan` so it isn't silent. But
  the router/switch that runs that subnet already knows every device on
  it, via its own ARP table and/or switch forwarding table — asking it
  directly would restore real discovery on a large subnet without ever
  touching every host address one at a time.

  Two standard SNMP tables would do this, if the hardware actually
  supports them:
  - `ipNetToMediaTable` (`1.3.6.1.2.1.4.22`, RFC 1213) — the router's own
    ARP cache: IP ↔ MAC pairs for everything it's talked to on that
    subnet. Directly gives candidate addresses without sweeping.
  - `dot1qTpFdbTable` (Q-BRIDGE-MIB, `1.3.6.1.2.1.17.7.1.2`) — a
    managed switch's CAM/forwarding table, MAC-keyed rather than
    IP-keyed, so it'd need combining with the router's ARP table (or a
    fresh sweep of just the resulting small candidate set) to get to IP
    addresses worth polling for `sysDescr`/`sysName`/uptime.

  **Verified against this network's real router (`Alta Route10`) and
  switch (`GC108P`), unlike the printer and router-route-table
  neighbors — both tables came back genuinely populated, not a dead
  end:**
  ```bash
  snmpget  -v2c -c public  -t 2 -r 1 10.0.0.1 1.3.6.1.2.1.1.1.0        # sysDescr, sanity check
  snmpwalk -v2c -c public  -t 2 -r 1 10.0.0.1 1.3.6.1.2.1.4.22         # ipNetToMediaTable
  snmpwalk -v2c -c thistle -t 2 -r 1 10.0.0.8 1.3.6.1.2.1.17.7.1.2     # dot1qTpFdbTable
  ```
  Also confirmed ap1 (`10.0.0.17`, Aruba AOS-8) answers `sysDescr` over
  `public` alongside the router — all three respond to this app's own
  already-configured `NMS.snmpCommunities` (`public`, `thistle`), no
  new credentials needed. The switch specifically only answered under
  `thistle`, not `public` — real confirmation that trying multiple
  configured communities per device (`SNMPViewModel`'s existing
  behavior) is load-bearing here, not defensive-only.

  Router's `ipNetToMediaTable` returned real IP↔MAC pairs for the
  switch, both APs, the printer, and several more addresses not
  otherwise known to the app yet. Switch's `dot1qTpFdbTable` returned a
  real MAC-keyed forwarding table, several entries matching MACs
  already seen via the router's ARP walk (confirming the two tables
  agree with each other) plus additional MACs the ARP table alone
  didn't have.

  **A real mistake made and corrected while sketching a topology
  diagram from this data, worth recording since it's a general
  `dot1qTpFdbTable` trap, not a one-off**: both APs' MACs
  (`e8:10:98:ca:a9:22`/`e8:10:98:ca:9f:66`) showed up in the switch's
  FDB sharing the exact same port number as the router's own MAC
  (`bc:b9:23:81:a6:d4`) — first read, wrongly, as "the switch has three
  devices attached to port 3." Corrected directly: both APs actually
  connect straight to the router now (they used to be switch-attached,
  per the person who actually wired this network — not something
  derivable from the SNMP data alone). A shared port number in a
  bridge forwarding table means "traffic from this MAC was last seen
  arriving via this port," which for anything not *directly* attached
  is just wherever the uplink happens to be — the router's own MAC
  landing on the same port as the APs was the tell, in hindsight.
  **Re-verified properly rather than left as a guess**: walked
  `dot1dBasePortIfIndex` (`1.3.6.1.2.1.17.1.4.1.2`) and `ifDescr`
  (`1.3.6.1.2.1.2.2.1.2`) on the switch to confirm port 3 is a genuine
  single physical port (`GigabitEthernet3`), not a LAG or the CPU
  port that would have told a different story — on this switch the
  base-port-to-`ifIndex` mapping is a clean 1:1, but that's a property
  of this hardware, not something to assume elsewhere. **The
  generalizable lesson**: a `dot1qTpFdbPort` value is a
  `dot1dBasePort` index, not a physical port label — reading it as
  device-to-port attachment without walking
  `dot1dBasePortIfIndex`→`ifDescr`/`ifName` first is exactly the kind
  of naive read that produced the wrong diagram here. Directly relevant
  to the Mermaid-diagram idea elsewhere in this file: any real
  implementation needs this same disambiguation, and even then a
  shared port is evidence of "reached via here," not proof of what's
  actually plugged into that port — this network's own real answer
  came from the person who wired it, not from SNMP alone.

  **One real finding this verification surfaced, not just "does it
  work": the router's ARP table is not scoped to the LAN subnet, and
  the previously-flagged off-subnet risk is real, not hypothetical.**
  The walk returned entries under three different `ipNetToMediaIfIndex`
  values — `21` for ordinary `10.0.0.x` LAN addresses (what
  `candidateAddresses()` wants), but also `6` for a handful of
  `192.184.x` *public* addresses (almost certainly the WAN-side
  neighbor table, all three sharing one MAC — consistent with a single
  upstream device) and `22` for a *third*, entirely different private
  range (`10.0.102.x`) — some other VLAN or interface this router also
  knows about. Naively consuming the whole table would pull in both.
  Confirms, with real data rather than a hypothetical, that any
  implementation must filter by `ifIndex` (or cross-check each
  resolved address against the current subnet, the same way
  `rebuildDeviceList` already filters everything else) rather than
  trusting the table wholesale — not a new conclusion, but no longer a
  guess about whether this matters on real hardware.

  **Directly tested the real open question this raises: does asking
  the router/switch find every device a direct poll would? No — and
  the gap runs in both directions, confirmed live within minutes of
  each other, not a theoretical concern.** Force-populated a fresh ARP
  entry for every responsive host by pinging all 254 addresses in this
  `/24` directly, then compared against the router's `ipNetToMediaTable`
  read earlier in this same session:
  - **SNMP discovery missed a live device the direct sweep found**:
    `10.0.0.141` (`c4:e9:84:5a:5e:3e`) answered the ping sweep but was
    completely absent from the router's ARP table snapshot — the
    router simply hadn't cached it yet, presumably no recent
    router-bound traffic from that device.
  - **The direct sweep missed a device SNMP discovery already had**:
    `10.0.0.144` ("iphone.local," present in the router's ARP table
    from earlier) didn't answer 3 direct ping retries just now —
    almost certainly Wi-Fi power-save on a sleeping/idle phone not
    responding to ICMP, not a real absence.
  - One apparent third case ruled out as noise, not a gap: `10.0.0.16`
    answered the sweep but resolved to ap1's own MAC
    (`e8:10:98:ca:a9:22`) — the AP answering a second address, not an
    undiscovered device.

  **The underlying cause, raised directly and confirmed rather than
  assumed: this is inherently time-varying, not a fixed accuracy gap
  to close once.** A router's ARP cache reflects *recent traffic*, not
  *present existence* — it both lags a device that just went quiet
  after being briefly active (aging out) and lags one that just became
  active after being quiet (not yet cached). A direct ICMP sweep has
  the opposite failure mode: it reflects *this instant's willingness to
  answer ping*, which sleeping laptops and power-saving phones
  routinely decline regardless of whether they're genuinely on the
  network. Neither method's snapshot is "more current" than the
  other's in general — they're wrong about different, overlapping sets
  of devices at any given moment, and a device can move between "known
  to one, not the other" within the same short session, exactly as
  demonstrated above.

  Still not built — this only completes the "worth building at all"
  verification. Open questions before code: the `ifIndex`-scoping rule
  above, how `dot1qTpFdbTable`'s MAC-keyed entries actually get
  combined with `ipNetToMediaTable`'s IP-keyed ones (a MAC seen on the
  switch but absent from the router's ARP table — e.g. a device that's
  been silent long enough for the router to age it out — would need
  its own resolution path, not just a join), and now also: given
  neither source is complete on its own, does `candidateAddresses()`
  treat SNMP-derived candidates as a cheap *head start* worth combining
  with a direct sweep where one's still affordable, or as a *full
  replacement* only for the large-subnet case where a sweep already
  isn't happening anyway (the case this item originally set out to
  solve)? The two have different honesty requirements — a replacement
  needs to be labeled as a snapshot, possibly stale in either
  direction, not presented as equivalent to a fresh sweep.

- [ ] **macOS notifications for sustained outages? Raised, not yet
  designed.** The idea: push a system notification (not just the
  popover/Events log, which only get seen if someone's already
  looking) for a real, sustained problem. Biggest risk identified up
  front: this network is demonstrably flap-prone (dozens of "became
  unreachable/reachable again" Events-log entries in a few minutes of
  ordinary testing this session) — naively notifying on every
  Events-log entry would be noisy enough to train someone to ignore it
  fast. The useful version would almost certainly need to reuse
  `ConnectivityViewModel`'s existing sustained-vs-transient filtering
  (`isWithinTopologyChangeWindow`/`shouldSuppressAsLocalInterference`)
  rather than hooking raw event logging, and probably scope to just
  `OverallStatus.critical` (router/internet/DNS/HTTP actually down),
  not SNMP restarts or printer blips. Nothing designed or built yet —
  needs its own real pass before starting.

- [x] ~~Rename "Expert Mode"'s internal Swift symbols to match its
  UI name.~~ **Done.** `NMSApp.comparisonWindowContent` →
  `expertModeWindowContent`; `ContentView.isInWindow` →
  `isExpertModeWindow`; the `Window(..., id: "nms-window")` scene
  identifier and every `openWindow`/`openWindowInFront` call site →
  `"expert-mode-window"`. Every affected doc comment across
  `NMSApp.swift`, `ContentView.swift`, `ContentView+Window.swift`, and
  `NoBounceScrollView.swift` updated to say "Expert Mode window" instead
  of "comparison window." Purely cosmetic — confirmed nothing
  user-facing changed by relaunching the real app and reading
  `ui-state.log`'s own `MenuBarLabel.autoOpenWindow` line, which
  resolved the renamed scene identifier correctly:
  `expert-mode-window → expert-mode-window`. Old occurrences left alone
  in `BUGS.md`/`DESIGN-NOTES.md` — those are historical narration
  (one directly quotes a real past log line), not current-state claims.

- [x] ~~Network Health's Router row: add a web link too.~~ **Built**,
  alongside ISP identification below: `ConnectionLayer` gained an
  optional `url`, set on the Local Router layer to `http://<routerAddress>`.
  Resolved the open question directly — always show the link once the
  address is known, no "detect a web server first" probe, letting a
  failed click-through be the browser's own fallback. That probe's
  self-signed-cert complexity stays scoped to the still-open SNMP
  Devices item below, not shared with this simpler case.

- [x] ~~ISP identification: worth an event message for the edge cases
  found while building it?~~ **Built** the one candidate that was worth
  it (below); the rest deliberately stayed silent. Raised directly after
  shipping RDAP-based ISP identification
  (`ISPIdentityService`/`ISPIdentityViewModel`). Looked at each
  candidate edge case; most don't actually have anything observable to
  log:
  - **A corporate network/proxy blocking the `rdap.org` lookup** — the
    failure is silently swallowed today (`identify(ip:)`'s `try?`), same
    "a parsing/fetch gap should be recoverable, not crash" posture
    `SaaSStatusService`'s own catch branch already has. An event here
    would mean logging *every* transient lookup failure, which this
    codebase deliberately doesn't do elsewhere either (SaaS's `.unknown`
    catch branch doesn't log an event; `WiFiSSIDViewModel` logs nothing
    when Location authorization is simply denied) — the honest answer
    is probably "no event," but flagged here rather than assumed.
  - **The Local Router/ISP status-page link failing to actually load**
    — genuinely unobservable: once `Link`/`NSWorkspace.open` hands off
    to the default browser, this app has no way to know whether that
    page loaded, 404'd, or the device wasn't there at all.
  - **The pre-existing ISP Edge Router hop-detection never confirming a
    hop on a complex multi-hop corporate WAN** — already has its own
    graceful `.unknown`/"Not confirmed" state (`connectionLayersLowToHigh`),
    not something new this feature introduced.
  The one candidate that actually was worth it: logging when the
  identified organization *changes* (mirroring `PublicIPViewModel`'s own
  `publicIPChanged` event) — a real, observable transition, unlike the
  cases above. **Built**: `AppEventKind.ispOrganizationChanged`
  (neutral polarity, no recovery pair, same shape as `publicIPChanged`)
  logged from `ISPIdentityViewModel.identify(ip:)` — guarded so neither
  the first-ever identification each session nor the one right after a
  network change (`reset()` clears the baseline) counts as a "change."
  Needed `ISPIdentityViewModel` to gain a `SnapshotStore` dependency it
  didn't have before (previously "identification for display only, no
  events to log" — now it logs exactly one).

- [x] ~~SNMP Devices: detect a web server on the device, add a link if
  found.~~ **Built** (`DeviceWebDetectionService`). Both open questions
  resolved directly: probes once at first discovery only (not every
  poll — a device's web UI toggling later within the same session won't
  be picked up until the address is forgotten by a full rescan), and
  "detected" means a real HTTP response on a candidate port, not a bare
  TCP connect. Tries HTTPS, then HTTP, then HTTPS on port `4343` — this
  network's own real Aruba APs use that non-standard admin port; see
  `DESIGN-NOTES.md`'s "SNMP device web-detection" entry for the finding
  and why it isn't generalized into a vendor-pattern registry yet. Same
  self-signed-cert handling this item had already resolved (a dedicated
  `URLSession` with a trust-all delegate, never `URLSession.shared`).
  Reuses `externalLinkIcon`, the same helper built for the Local
  Router/ISP links.

  Also fixed a related gap found while testing this: `SNMPViewModel`
  only ever discovered devices via the popover's manual "Scan" button —
  a first-time user enabling the feature saw an empty list forever
  unless they found and clicked it. `activate()` now sweeps
  automatically the one time there's nothing rehydrated from history,
  accepting the one-time launch-time-contention risk that comment
  already documented (see that function) rather than the ongoing "every
  launch" version of that risk. The button stays — nothing else
  triggers a fresh sweep, so it's still the only way to find a device
  added to the LAN after that first discovery.

- [ ] **SaaS fault injection: already built, but three real gaps found
  while checking.** Asked "how to test SaaS services that rarely fail,
  can we inject faults" — turns out `FailureInjector.applySaaSChanges`
  already does exactly this (`defaults write
  ~/Library/Preferences/Thistle.NMS.plist NMSInjectSaaSOutage -array
  Slack`, DEBUG-only, `[injected]`-tagged, real fetch still runs
  underneath). Confirmed working, not new. What's actually missing:
  1. **Not in README's "Experimental features" list.** That section's
     "Failure injection" bullet names connectivity/interface-down/DHCP/
     SNMP explicitly but not SaaS — someone reading just the README
     wouldn't know this exists. Add a line.
  2. **`script/scenarios.sh` doesn't cover it either** — that script's
     own description says "connectivity, DHCP, and SNMP," 11 checks;
     SaaS outage injection has no automated scenario test at all today.
  3. **Only simulates `.major`** — `applySaaSChanges` hardcodes
     `.major` for every forced service (confirmed reading the code);
     there's no way to inject `.minor` or `.critical` specifically, so
     the UI's handling of the full indicator range (if it differs at
     all beyond color) can't actually be tested or demoed today, only
     the "is something wrong at all" case.

- [x] ~~Network Health's "Network" row: Wi-Fi signal sparkline, or plain
  "Ethernet."~~ **Built.** The wiring gap this item flagged
  (`connectionHealthSection`'s sparkline slot was typed for
  `latencyHistory`, not RSSI) resolved with the small special case
  already anticipated: `layer.id == "network"` when `info.isWiFi` now
  reads `wifiSSID.recentSamples` instead, same values/reversal
  `wifiSection`'s own Signal row already uses. Final spec, requested
  directly: "Name" + "Ethernet" (`networkDisplay(_:)`, unchanged) or a
  sparkline + "Wi-Fi" — the network's name is dropped from this row on
  Wi-Fi specifically (the Info tile's own row still shows it), not
  appended alongside the sparkline as first drafted here.

- [ ] **Shrink SNMP Devices' box height.** `SectionLayout.boxHeight(on:)`:
  `200` → `150` (requested directly, down 25%). That 200 is explicitly
  taller than its neighbors "because `sysDescr` wraps instead of
  truncating and needs the extra room" (that type's own comment) —
  worth a live check that a real wrapped `sysDescr` (the switch's is
  the longest seen so far, two lines) still reads fully at 150 before
  landing on it, not just trusting the arithmetic. (The matching
  Printer Alerts half of this item is moot — that tile was removed
  entirely; see "Decide whether to keep the printer alerts feature.")

- [ ] **Blocked on the user: GCP OAuth client setup for "Sign in with
  Google" (Personalized Service Health).** Everything else for this
  feature (code, API research — see `DESIGN-NOTES.md`'s "Google Cloud,
  interactive Sign in with Google variant") is ready to build; this is
  the one piece only the account owner can do. Exact steps:
  1. Pick or create a GCP project:
     `gcloud projects create nms-service-health --name="NMS Service Health"`
     (an existing project works fine too).
  2. Enable the API: `gcloud services enable servicehealth.googleapis.com
     --project=YOUR_PROJECT_ID`
  3. Grant yourself the viewer role on whichever project(s) NMS should
     monitor: `gcloud projects add-iam-policy-binding YOUR_PROJECT_ID
     --member="user:your-email@example.com" --role="roles/servicehealth.viewer"`
  4. Console → APIs & Services → OAuth consent screen: User type
     **External** (or Internal if this project is under a Workspace
     org); add scope `https://www.googleapis.com/auth/servicehealth.readonly`;
     add your own email as a test user; leave publishing status as
     **Testing** for now.
  5. Console → APIs & Services → Credentials → Create Credentials →
     OAuth client ID → Application type **Desktop app** → copy the
     **Client ID** (`...apps.googleusercontent.com`) — safe to hand to
     Claude/embed in the app; PKCE secures the flow, not secrecy of
     this value.
  - **Real caveat, checked directly**: while the consent screen stays
    in **Testing**, Google expires refresh tokens after exactly 7 days
    regardless of activity — a weekly forced re-sign-in. Moving
    publishing status to **Production** avoids that (indefinite
    refresh tokens); for a single personal-use client this is usually
    just a checkbox, not a full verification review, but which bucket
    `servicehealth.readonly` falls into (verification-required or not)
    hasn't been confirmed. Try Production first; Testing + weekly
    re-consent is a real, non-fatal fallback if it demands review.

- [x] ~~Add Wi-Fi signal strength to Network Health.~~ **Built**, via the
  "Network" row item above. Both open questions resolved in practice
  rather than by a separate up-front decision: the sparkline shows as a
  plain, uncolored data row (no new RSSI-degraded threshold introduced —
  the row's existing green/gray status still comes from whether a
  network name/label resolved, unchanged), and it *does* now appear on
  the popover, since Network Health is one of the two tiles that was
  never subject to the audience-split's window-only scoping to begin
  with — not a reopening of that decision, just this row using the
  exemption Network Health already had.

- [x] ~~Add Google Workspace and Google Cloud to SaaS monitoring.~~
  **Built.** Both added to `SaaSStatusService.monitoredServices` with a
  new `.googleIncidents` `Shape` (a rolling incident-history array, not
  a Statuspage-style current-status summary — see the parser's own doc
  comment for how "currently healthy" is derived from it, and the real
  judgment call in the severity mapping). Verified live end-to-end, not
  just via `curl`: enabled `FeatureSaaSMonitoring`, ran a real check,
  both reported `.none` / "All Systems Operational" with correct
  status-page URLs — including Google Workspace's, which needed a small
  explicit override (`MonitoredService.dashboardPath`) since its
  `incidents.json` lives under `www.google.com`, a host that isn't
  itself a status page the way every other entry's endpoint host is.

- [ ] **Add AWS to SaaS monitoring — needs a scoping decision first.**
  `https://status.aws.amazon.com/rss/<service>-<region>.rss` (RSS,
  re-confirmed live, `ec2-us-east-1` tested) is real but per-service-
  per-region, not one aggregate feed the way Google Cloud/Workspace are
  — there's no single "AWS" entry to add without first deciding which
  service/region slugs actually matter (e.g. just this house's actual
  AWS usage, or a fixed starter set like EC2 us-east-1). Also a new
  `Shape` case needed (RSS/XML parsing, unlike every existing entry).

- [ ] **Microsoft 365 needs a decision before it can be added at all.**
  No public, unauthenticated endpoint exists — `DESIGN-NOTES.md` already
  confirmed `401` on the real API (Microsoft Graph Service
  Communications) without an OAuth app registration. Options, same
  three as Workday/ADP's existing gap: skip it, fall back to a plain
  reachability check against a Microsoft 365 domain (weaker signal,
  same shape as the Workday/ADP fallback already designed), or treat it
  as the first candidate for the separate tenant-auth project in
  `DESIGN-NOTES.md`. No pull toward one yet.

- [ ] **iCloud needs a scoping decision too — it isn't one service.**
  Raised directly. Apple's system status feed
  (`https://www.apple.com/support/systemstatus/data/system_status_en_US.js`)
  is real, live, and unauthenticated — confirmed against a real
  *resolved* incident (Apple Cash, 07/31/2026), whose event shape is
  `{"messageId", "statusType", "message", "datePosted", "startDate",
  "endDate", "epochStartDate", "epochEndDate", "usersAffected",
  "affectedServices", "eventStatus": "resolved"}`. Two real problems,
  neither a drop-in the way Cloudflare/Figma/HubSpot/Docusign were:
  - **Completely different shape** from every existing entry: one flat
    list of ~78 named Apple services, each carrying its own `events`
    array (empty when healthy), not a Statuspage `status.indicator`
    summary. Would need a new `Shape` case — structurally closer to
    the existing `.googleIncidents` parser (a rolling incident list,
    "healthy" is the absence of one) than to `.statuspage`.
  - **"iCloud" is 13 separate entries on this feed**, not one: iCloud
    Account & Sign In, Backup, Bookmarks & Tabs, Calendar, Contacts,
    Drive, Keychain, Mail, Notes, Private Relay, Reminders, Storage
    Upgrades, Web Apps (iCloud.com), plus iWork for iCloud. Needs a
    decision — track one representative sub-service (which one?), or
    aggregate all 13 into a single rolled-up "iCloud" status (red if
    *any* has an active event).

  Also unconfirmed: the *active* (not-yet-resolved) event shape — only
  a resolved one has been observed live, so whether `endDate`/
  `eventStatus` reliably distinguish "still ongoing" isn't verified yet.
  Worth checking the next time any of these 78 services has a real,
  ongoing issue before writing the parser.

- [x] ~~README.md has fallen behind real, shipped behavior — needs a
  refresh pass.~~ **Done.** All items found in the original audit fixed:
  the popover's actual current shape (Network Health + Info + footer
  only — the "2×2 grid"/"Events, full width" description was stale on
  two independent counts, predating this session in one case), the
  Network row's new Wi-Fi sparkline, the Path to Internet tile's new
  "NAT" row, a full SaaS Status writeup (new section, new TOC entry, new
  Experimental Features entry for `FeatureSaaSMonitoring` — including
  the `FeatureSaaSEnabledServices` new-service gotcha found live this
  session), Info's per-network-scoping list, Events' multi-line
  wrapping and link icon, and the stale NMSUITests appearance-toggle
  paragraph. Test counts corrected (105 unit, 3 UI). Also gave Wi-Fi and
  Printer Alerts their own `###` subsections to match DHCP
  History/SNMP Devices/SaaS Status, and found (via a script checking
  every `NMS/**/*.swift` filename against the README) that Project
  Layout was missing seven real files entirely —
  `BugReportExportService`, `BlockingWork`, `DebugArtifactRetention`,
  `DeviceWebDetectionService`, `ISPIdentityService`/`ISPIdentityViewModel`,
  `SaaSMonitoringViewModel`, and `SaaSStatusService` itself — all added.

- [x] ~~Let users add their own website(s) to monitor, via
  Preferences.~~ **Built.** The three open questions this item raised
  all got resolved during implementation, not left open:
  - New `Shape.reachabilityOnly` case — reuses `checkStatus`'s existing
    fetch entirely (no new HTTP code), just handled before the shared
    `== 200` guard since it accepts any 2xx and needs no body parsing:
    `.none`/"Reachable" on success, `.unknown` on anything else (via
    the caller's existing catch branch, unchanged).
  - Storage: `FeatureFlags.UserAddedSaaSSite` (`Codable`, `url` +
    `nickname`), JSON-encoded into `UserDefaults` `Data` under
    `FeatureUserAddedSaaSSites` — the `[String: String]`-or-`Codable`-array
    question resolved as the latter.
  - **Visually distinct, not folded into the curated list** — a new
    `SaaSMonitoringViewModel.userAddedStatuses`, checked by its own
    `checkUserAddedSites()` on the same timer cadence but *never*
    logging Events transitions the way `apply()` does for the curated
    list. That's not an oversight, it's the point: per DESIGN-NOTES.md's
    "Does this vary by network?", a plain reachability check is
    genuinely network-dependent (a restrictive network can fail it with
    nothing wrong at the site), so logging a down/recovered pair here
    could misreport "blocked on this network" as "this site went down
    and came back" once roaming elsewhere. Rendered in the live UI as a
    separate "Your Own Sites" group below the curated rows, same
    reasoning.
  - Preferences UI: a real add ( nickname + URL, `http`/`https`-validated
    before the button enables) / remove list, separate from the curated
    checkboxes above it.

  **Honest gap: the add/remove UI itself wasn't click-verified live** —
  `System Events`' `entire contents` walk was unreliable this session
  (see `CLAUDE.md`) and repeated retries didn't resolve it. Build is
  clean, the full test suite passes, and the actual check *logic*
  (`FeatureFlags` storage round-trip, `SaaSStatusService.checkStatus`'s
  `.reachabilityOnly` path, `SaaSMonitoringViewModel
  .checkUserAddedSites`) was traced by hand rather than guessed at, but
  a real click-through of the Preferences form itself is still worth
  doing manually before fully trusting it.

- [ ] **Popover should roll up non-green SaaS statuses.** SaaS monitoring
  is window-only per `SectionLayout`'s audience split (popover = "can I
  work, what's restricted"), so a real outage (e.g. Slack red) is
  currently invisible unless someone opens the window. Would fit the
  popover's existing "can I work" framing without reopening the
  deliberate cut against `OverallStatus`/menu-bar color integration
  (see the SaaS monitoring plan's Context section): this would be its
  own independent popover signal, not a change to what the menu-bar
  color means.

  **Concrete shape proposed directly**: a small, fixed-height (2 lines)
  box, shown only when at least one monitored service isn't `.none` —
  problems only, not a full status list, so it costs zero popover space
  when everything's healthy (same "earn its keep" principle
  `SectionLayout.scrollThreshold`'s doc comment already states for
  every other box in this app). At exactly 2 lines it can show at most
  2 problem services before needing to scroll or truncate — worth
  deciding which once there's a real case with 3+ simultaneous
  degradations to test against (today's monitored set has never shown
  more than one at a time). Other open questions: does each line carry
  severity (worst indicator per service) or just the name; does a line
  link/scroll to the window's SaaS section when clicked; does it appear
  at all when the feature flag is off (no, matching every other
  conditional section).

- [ ] **Do we need a "dark mode" for the app?** Raised directly, not yet
  investigated. Worth checking what actually happens today first —
  `MenuBarExtra(.window)` and the plain `Window` scenes may already pick
  up the system appearance for free via standard SwiftUI/AppKit
  materials, or specific colors here (the status dots, `Sparkline`'s
  hardcoded `.secondary`/`.red`, the orange debug-override banner, the
  yellow bug-report tint) may not adapt correctly against a dark
  background. Needs a real check in dark mode before deciding whether
  there's anything to build at all.

- [x] ~~Path to Internet's Provider Edge History may not be worth
  showing on a single-homed network.~~ **Removed the display.** The
  caveat that kept this open (removing it "reopens" the Path to
  Internet/Speed Test tile-height mismatch) stopped being true once both
  tiles moved to one shared `ContentView.tileHeight` — matching height no
  longer depends on either tile's actual content. With that gone, the
  real data made the call easy: on this single-homed network, the address
  changed twice in 3 real `ProviderEdgeRecord` rows over ~35 hours, and
  one of those two "changes" was a flap-and-revert 3 seconds apart —
  thin, noisy signal, not a diagnostic worth a permanent list. The
  underlying mechanism stays (`SnapshotStore.recordProviderEdgeIfChanged`,
  `ProviderEdgeRecord`): `TracerouteViewModel.monitoredHopAddress` still
  depends on `latestProviderEdge()` to survive an outage without
  dropping to "Not checked," and hostname enrichment still patches the
  latest row. Only the UI (`ContentView+Window.swift`'s edge-history rows
  and divider) and the display-only plumbing that fed it
  (`TracerouteViewModel.edgeHistory`, `reloadEdgeHistory()`,
  `SnapshotStore.fetchProviderEdgeHistory`) are gone.

- [x] ~~Confirm Printer Alerts' new fixed-height box actually fits 2
  printers live.~~ **Moot — the Printer Alerts tile was removed
  entirely.** See "Decide whether to keep the printer alerts feature."
  This box-fit question no longer applies to anything that exists.

- [x] ~~`BuildInfoService`'s hardcoded repo path breaks when more than
  one checkout exists on a machine.~~ **Done — took the third option
  (`4104b24`).** The item below already framed the choice: keep the
  hardcoded path, derive it from the running binary, or "dropping the
  design's original assumption and adding the build-time Run Script
  stamp the doc comment already considered and passed on." The stamp
  won, after the same class of bug recurred in a much more expensive
  form.

  What forced it: a binary built 2026-07-29 12:26 ran for two days
  reporting `dead27c+dirty`, a commit made well after it, across
  several bug reports. Same silent-staleness mechanism as the
  two-checkouts case originally recorded here, but this time it also
  hid a High-severity data bug — that stale binary predated `e2f9ba2`'s
  schema change, so it was the only reason the store still opened, and
  the misreported hash is what made the resulting failure look
  impossible for as long as it did. See `BUGS.md`, "The persistent
  store fails to open."

  A "Stamp build info" run-script phase now writes the hash, subject
  and dirty flag into the built `Info.plist`, and `BuildInfoService`
  reads those instead of running `git` at launch. A stamp can't drift:
  it's written by the build that produced the binary, or it's absent
  (and absent stays graceful — `nil`, shown as "unknown"). Verified by
  committing without rebuilding: the unrebuilt binary kept reporting
  its own older hash instead of the new `HEAD`, which is exactly what
  the old code got wrong. Also fixes the original two-checkouts case
  for free — the stamp depends on no path at all — and drops a process
  spawn at launch.

  **One tradeoff worth knowing**: this needs
  `ENABLE_USER_SCRIPT_SANDBOXING = NO`, scoped to the NMS app target
  only (project default and both test targets stay `YES`). Confirmed
  necessary rather than assumed, by reading the generated `.sb`
  profile: it denies `file-read*` across all of `SRCROOT` including
  `.git`, granting only individually declared input files — and
  `git status --porcelain` can't work that way, since it stats the
  entire worktree.

- [x] ~~Remove SNMP Devices from the popover; keep it window-only.~~
  **Done.** `ContentView`'s SNMP Devices block now reads
  `if FeatureFlags.snmpDevices && isInWindow`, same pattern as Wi-Fi/
  DHCP History/Printer Alerts. README's popover and "Open in Window"
  sections updated to match (also caught DHCP History and Printer
  Alerts already being window-only but not yet reflected in the
  "Open in Window" section's own text, and the popover's content list
  still listing DHCP History as if it were still there — both fixed in
  the same pass, plus the Bug Report button, missing from the footer
  description). Build clean, 64/64 tests, relaunched without issue.

- [ ] **Is the plain Screenshot button still needed now that Bug Report
  exists?** Real question, but the two aren't redundant — checked what
  each actually does. Screenshot (`ScreenshotViewModel.capture`) is a
  single no-prompt action: grabs the image, logs `screenshotCaptured`,
  done. Bug Report (`captureBugReport`) is a strict *superset* of that
  same screenshot mechanism, plus a state dump, plus a comment/severity
  — but its own doc comment is explicit this was a deliberate design
  choice, not an oversight: "Deliberately a separate button from
  Screenshot above, not a prompt bolted onto it — that one's whole
  value is staying a fast, no-prompt capture. This one exists
  specifically to stop and ask 'what are you seeing.'"

  Submitting Bug Report with an empty comment *would* work as a
  Screenshot replacement functionally (the code already handles an
  empty comment gracefully — `"(none)"`), but costs two extra clicks
  (open the prompt, confirm with nothing typed) and always writes a
  state-dump file even when nobody needed one. This session's own
  history argues for keeping both: several screenshots handed over
  mid-session this exact week were all the fast, no-prompt button,
  precisely because typing a comment first would have been friction
  for "just look at this."

  Leaning toward **keep both** — but it's your workflow being optimized
  here, not a technical necessity either way.

- [x] ~~"Open in Window" shouldn't appear once you're already in the
  window.~~ **Done.** Gate is now
  `if FeatureFlags.comparisonWindow && !isInWindow`, the inverse of the
  `isInWindow && ...` pattern every window-only section already uses.
  Build clean, 64/64 tests, relaunched without issue. Not yet confirmed
  by eye that the button actually disappears from the window's own
  footer — no Accessibility permission to click through it from here.

- [x] ~~Add a length cap to untrusted network-derived text before it's
  persisted.~~ **Built** (`UntrustedText.swift`). Found during a
  security review requested ahead of letting friends try the app. SNMP
  `sysDescr`/`sysName` (`SNMPService.probe`) and DHCP option strings
  (`DHCPLeaseService.parse`) are genuinely untrusted — they come from
  whatever a device on the LAN chooses to send back — and neither had a
  length limit before being stored in SwiftData and rendered in a
  `Text` view. Not exploitable (every string only ever reaches plain
  `Text(String)`, never `Text(markdown:)` or `AttributedString(markdown:)`,
  so there's no rendering-injection path regardless of size), but a
  misbehaving or malicious device could still bloat the store or slow a
  render with an oversized response. Fixed with a shared 4096-character
  cap applied at the parsing boundary in both services — SNMP caps
  `sysDescr`/`sysName` individually; DHCP caps every option value
  uniformly as it's parsed, covering `domain_name` (the one currently
  read downstream) and any option added later, not just today's known
  case. The rest of the review came back clean: every subprocess call
  uses `Process`'s array-form arguments (no shell, no injection
  surface), no `String(format:)` call anywhere uses untrusted content
  as the format string itself, and the ARP-parsing regex is simple and
  anchored (no ReDoS risk).

- [x] ~~Split by audience: popover for business users (summary only),
  the real window for IT users (everything).~~ **Done (`4104b24`+).**
  Resolved the open questions below with a direct answer: "summary"
  means Network Health plus Info — status plus which network you're on,
  nothing else. Path to Internet, Speed Test, and Events all moved to
  window-only (`SectionLayout.surfaces`), joining Wi-Fi/SNMP Devices/
  DHCP History/Printer Alerts, which were already there. The popover's
  scroll-box budget (`SectionLayout.popoverBoxTotal`) is now pinned to
  exactly `0` by a test — any box-bearing section landing back on the
  popover fails the build.

  "Open in Window" stays the only full-detail surface — no
  expand/collapse path was added to the popover itself, since the whole
  point was moving detail *out*, not adding a second way to reach it
  from the same place. Confirmed live via accessibility-driven AppleScript
  (a fresh capability this session — see below): the split renders
  correctly and 560pt still looks right for two tiles, no dead space on
  the right edge.

  That same check surfaced a real, immediate follow-up, in two rounds.
  **Round 1**: Network Health (7 rows) and Info (5-6 rows) no longer
  shared a column with a second tile absorbing the height difference, so
  their borders visibly mismatched. A same-day Bug Report caught it
  within minutes ("can we align the two tiles?"). First fix used a
  `GeometryReader`/`PreferenceKey`/`@State` round-trip and looked correct
  when checked via a live `screencapture` of the real popover — but a
  *second* same-day Bug Report on the same two tiles ("bottom edge of
  tiles not aligned") turned out to be right: `ScreenshotService.capture`
  renders via `ImageRenderer` once, synchronously, with no run-loop turn
  for that state round-trip to land before the image is captured, so
  every actual Bug Report/Screenshot still showed the unsynced heights.
  Confirmed by measuring the captured PNG's border pixels directly, not
  by eye — the same class of `ImageRenderer` quirk already documented
  three times on `ScreenshotService`, now a fourth.

  **Round 2**: replaced the state-based sync with a `Grid`/`GridRow`
  for just Network Health and Info — `Grid` synchronizes cell heights in
  one deterministic layout pass, no state round-trip, no window for a
  single-shot renderer to miss. Measuring again showed the *same* gap
  persisting, which turned up a second, real SwiftUI subtlety: `Grid`
  synchronizes each cell's layout *slot* to the row's tallest cell, but a
  shorter cell's own drawn background/border doesn't stretch to fill that
  slot unless the cell explicitly opts in with `maxHeight: .infinity`.
  Added a `fillHeight` parameter to `ContentView.tile(title:content:)`,
  applied only to the Network Health/Info `GridRow` — Path to Internet
  and Speed Test keep the plain, unstretched `tile()` in their own
  `HStack`, so their independent sizing (Speed Test's history can grow
  arbitrarily tall; forcing that onto Path to Internet was rejected once
  already, see `scrollableContent`'s "Independent columns" comment) is
  unaffected.

  Verified via the real popover's own Screenshot button (accessibility-
  clicked, not just built) and a tight crop of the resulting PNG. One
  more lesson from this round: the pixel-measurement script written to
  check it had its own bug (picking up the footer's button borders below
  the tiles, the same false-positive class the orange Bug Report banner
  caused earlier) — direct visual comparison of the crop, cross-checked
  against the user's own live view, is what actually confirmed the fix,
  not the automated heuristic.

  **Round 3, a different pair**: a *third* same-day Bug Report ("can you
  align the bottom edges of path to internet and speed test?") named the
  window's other tile-grid row. First attempt: a `SectionLayout
  .forcesWindowBox` flag letting Path to Internet size to content below
  3 rows instead of always boxing at 150pt, on the theory that an empty
  box (2 confirmed hops in a box sized for the worst case) was the whole
  problem. Live verification (a real screencapture of the frontmost
  window, not a build check) showed it wasn't: Speed Test's real history
  already had 5 entries, past its own threshold, so it kept boxing at
  140pt regardless of the flag — the mismatch persisted, just for a
  different reason. That reason turned out to be structural, not a
  layout bug at all: **a network path is almost always short (1-4 hops,
  usually confirmed down to 1-2), while Speed Test's history only
  grows** — no box-forcing rule reconciles a tile whose content is
  inherently sparse with one that's inherently an accumulating log.

  Raised directly and answered directly: rather than keep chasing that
  asymmetry with layout rules, give Path to Internet the same kind of
  content Speed Test already has. `SnapshotStore.fetchProviderEdgeHistory`
  / `ProviderEdgeRecord` already existed for exactly this — a real
  change-log of the ISP edge address, built earlier and never wired into
  any UI — so this was surfacing existing data, not building a feature
  from scratch. Added `TracerouteViewModel.edgeHistory`, network-scoped
  the same way DHCP/Events are (`ProviderEdgeRecord.networkFingerprint`,
  optional — a mandatory version would have hit the exact migration
  failure `BUGS.md`'s store bug describes), wired
  `NetworkIdentityViewModel.onNetworkRecognized` to reload it (same gap
  as today's earlier Events/DHCP fix), and appended it below the current
  hop list inside Path to Internet's existing box — one shared
  scrollable area, mirroring how Speed Test's history *is* its content
  rather than an addition below a separate "current state" display.
  `forcesWindowBox` was reverted (the window boxes unconditionally again,
  for every section) and Path to Internet's declared window height was
  set equal to Speed Test's (140, not derived from either tile's actual
  content — "reasonable sizes, the window scrolls past whatever doesn't
  fit" was the explicit call, since squeezing every tile to fit exactly
  stopped being the point once nothing has to fit inside a popover
  anymore). Verified against the real store (3 existing
  `ProviderEdgeRecord` rows migrated and adopted cleanly, no fallback)
  and live via a screencapture of the actual frontmost window: both
  tiles' bottom borders and the divider below them now land on the same
  row.

**From off-site testing** (8 items originally; 3 turned out
to be bugs and moved to `BUGS.md` — Known Networks not recognizing an
unfamiliar network, the first-traceroute latency inflation, and the
Wi-Fi transition event misfiling. 4 more were already fixed and dropped
from this list. This one remains, since it's an idea, not a defect):

- [ ] **8. Cross-check the router's own interfaces/routes via SNMP
  against the current method (SCDynamicStore), and report a
  disagreement.** Needs the router to expose standard IP-MIB tables
  (`ipRouteTable`/`ipCidrRouteTable`, `ifTable`) over SNMP, which is not
  guaranteed — the printer on the home network already showed weak
  standard-MIB support (`prtAlertTable` returning only sentinel values),
  so this needed checking per router, not assumed.

  **No longer blocked on shell-can't-reach-LAN-devices — since checked
  live, with a genuine split result across two real routers.** The
  home router (`Alta Route10`, `10.0.0.1`) already responds fine to
  standard IP-MIB tables — `ipNetToMediaTable` came back fully
  populated (see the neighboring "Use SNMP against the router/switch
  itself…" item), so `ipRouteTable`/`ifTable` are worth trying there
  specifically next. **But field-tested live against a second, real
  router — the off-site network's ASUS RT-AC68P (`192.168.1.1`) — and it answers *no*
  SNMP at all**, not even a basic `sysDescr`, tried under `public` and
  `private` (this app's configured `thistle` too), and under both
  SNMPv1 and SNMPv2c — every combination timed out identically.

  **Confirmed why, not just inferred from the timeout**: stock ASUS
  firmware has no SNMP support at all — not a disabled toggle, a
  genuinely absent feature. It only becomes available via third-party
  firmware (Asuswrt-Merlin) or manually installing `net-snmp` over SSH,
  neither of which a typical router owner would have done
  ([SNBForums](https://www.snbforums.com/threads/snmp-on-rt-ax88u-running-stock-firmware.77761/),
  [mikaelgranberg.se](https://www.mikaelgranberg.se/node/25?language=en)).
  So this isn't a probing failure or a wrong community string — it's a
  real, common, and apparently popular router line (ASUS RT-AC series)
  shipping with no SNMP path at all on its stock firmware. This
  approach needs a real fallback for exactly that case, since it's
  looking like the common one for consumer routers, not the exception.

  **Concrete next step, before any code**: `snmpwalk` the router
  directly with the community strings already configured, same as was
  done for the printer:

  ```bash
  snmpwalk -v2c -c public -t 2 -r 1 <router-ip> 1.3.6.1.2.1.4.21   # ipRouteTable
  snmpwalk -v2c -c public -t 2 -r 1 <router-ip> 1.3.6.1.2.1.4.20   # ipAddrTable
  ```

  If those come back empty, unpopulated, or the router doesn't answer
  SNMP at all (confirmed real outcome, not just possible), this is a
  dead end on that hardware — worth writing up as such per-router
  rather than half-building it, same discipline as the printer's own
  finding.

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

- [x] ~~Test per-network scoping and Network Review on a second network.~~
  **Done**, on a real live switch (this Mac's own Home ↔ guest-Wi-Fi
  VLANs, same router). All confirmed clean via direct `sqlite3` queries
  against the real store, not just the UI: the guest network recognized
  as distinct (its own Known Networks row, `timesSeen` incrementing on
  return visits); Events (550 vs. 47), DHCP History (301 vs. 6), and
  Wi-Fi samples (12 vs. 29) cleanly separated with zero cross-network
  leakage; Home's row, label, and full history stayed intact and
  reachable through the Review sheet while connected to the guest
  network (screenshotted directly — header, label, seen count, and
  populated Events section all correct); the crash-shape duplicate-row
  query stayed empty throughout. This also closes out the Network
  Review UI itself, which had only ever been build-verified before
  this — now actually seen rendered, live, for both networks.

  **One real gap found, since fixed — see DESIGN-NOTES.md's "A router
  serving two VLANs is a genuine edge case per-network scoping doesn't
  fully cover."** The router's guest-side address was getting a
  persisted SNMP row under *both* networks' fingerprints, kept alive
  indefinitely by `syncAliasFreshness` — invisible in the live UI (the
  shared-MAC alias merge papered over it), but a real persisted-data
  leak. Root cause traced to `SNMPViewModel.candidateAddresses()`
  scanning beyond the current subnet (raw ARP cache, plus "local"
  traceroute hops added for ISP edge router discovery); fixed by
  restricting it to strictly the current subnet plus its gateway. SNMP
  no longer auto-discovers an off-subnet ISP edge router as a result —
  an accepted tradeoff for scanning never reaching outside the current
  network.

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

- [x] ~~"Generate Report" button on Network Review.~~ **Built and
  verified live.** Reuses `ScreenshotService`'s `ImageRenderer` against
  the Review sheet itself — same `isCapturingScreenshot`/
  `capturingScreenshotCopy` shape as `ContentView`'s own screenshot
  path, needed because `ScrollView` content otherwise renders as
  completely absent off-screen (see `ScreenshotService`'s own doc
  comment). Also fixed the DHCP row's `appKitToolTip(..., enabled: true)`
  that this same file's own comment had flagged as a landmine for
  whoever built this — an `NSViewRepresentable` `ImageRenderer`
  substitutes a yellow "prohibited" glyph for, now `enabled:
  !isCapturingScreenshot` like every other tooltip in the app.
  `ScreenshotService.capture` gained an optional `filenamePrefix` (default
  `"NMS"`, unchanged for every existing caller) so a report is
  distinguishable by filename alone — `NMS-Review-<network>-<date>.png`.
  Confirmed end-to-end against the real running app: a real "Home"
  report saved as a complete, correctly-rendered 1677×15374px PNG (full
  Events/SNMP/DHCP/Wi-Fi history, no blank sections, no tooltip glyph),
  revealed in Finder on completion.

- [x] ~~DHCP tile → Events as a multi-line message.~~ **Resolved: keep
  them separate, deliberately not merged.** The blocking *technical*
  tension was already gone: Events moved window-only in the audience
  split, so it no longer shares the popover's precise 17pt/row height
  calibration this was originally worried about breaking — the window's
  Events box is just a generous, independently-scrolling 350pt area
  regardless of how many lines any one entry takes, and `eventRows` no
  longer truncates to one line as a result. What remained was the
  original *idea* — folding DHCP History's own detail into a multi-line
  Events entry instead of keeping it a separate section — and on
  reflection that's the wrong direction, for three reasons:
  1. **Different audiences at different granularity.** `dhcpHistoryList`
     shows every field of every real lease change (server, address,
     broadcast, gateway, DNS, domain, lease/T1/T2 timing, transaction
     ID — "the densest jargon in the app," per its own tooltip).
     Events already logs a one-line summary of the same transition
     (`dhcpLeaseChanged`). Merging means either bloating every Events
     row to DHCP's full technical density, or discarding that detail to
     fit Events' shape — a real loss of diagnostic value either way.
  2. **Events is a shared, cross-subsystem list with one row shape.**
     Interface changes, SNMP restarts, connectivity outages, SaaS
     status, and DHCP changes all render through the same
     colored-dot-plus-label-plus-detail row. Making just DHCP's entries
     uniquely two-line-dense would make that one list inconsistent, not
     simpler.
  3. **This already matches the app's own established pattern.** The
     popover/window audience split works exactly this way — headline in
     one place, full detail one level down (see this file's "Split by
     audience" entry). Events is the headline ("something changed");
     DHCP History is already the "one level down" detail view. Merging
     them would collapse a distinction the rest of the app deliberately
     keeps, not simplify anything.

- [ ] **File the two `swift-frontend` compiler crashes with Apple
  Feedback Assistant.** Two genuinely different crashes, not two copies
  of one — the previous wording here conflated them: (1) "failed to
  produce diagnostic for expression" at type-checking, on a conditional
  `Window` scene inside `@SceneBuilder`; (2) an `EarlyPerfInliner` SIL-
  optimizer crash, Release/Archive builds only, on a class's
  synthesized `deinit` when that class is nested inside a generic type.
  Raised as a to-do three times now and never actually filed — actual
  submission needs the user's Apple ID in Feedback Assistant's own app,
  not something doable from here.

  **Both reports fully drafted and ready to paste in** — title,
  description, minimal standalone repro code, and the toolchain
  versions they were found on (Xcode 26.3/17C529, Swift 6.2.4, macOS
  15.7.7). Delivered to the user as a file; not committed here since its
  only job is a one-time paste into Feedback Assistant, not ongoing
  project documentation. Both workarounds already live in the real code
  (`NMSApp`'s `comparisonWindowContent`; `NoBounceScrollCoordinator` at
  the top level) — filing these is purely for Apple's benefit at this
  point.

- [x] ~~Ethernet link speed telemetry.~~ **Built.** Discussed alongside
  the Wi-Fi telemetry work; scoped and shipped end-to-end this session.
  `EthernetLinkService` shells `networksetup -getMedia <device>` — same
  free-ride pattern as `ping`/`arp`/`traceroute`/`ipconfig`/`snmpget`,
  no IOKit needed — verified against this Mac's own real Gigabit
  connection before writing the parser (`1000baseT <full-duplex
  flow-control>`). `EthernetLinkViewModel` mirrors
  `WiFiSSIDViewModel.refresh(isWiFi:)`'s shape but simpler: no persisted
  history, no events, no periodic timer — link speed only changes on a
  physical event (cable swap, different switch port), which is exactly
  when `NMSApp`'s existing topology-change wiring already calls
  `refresh` again, so a timer polling a static value would add nothing.
  New `SectionLayout.ethernetLink` case (window-only, 60pt — just Speed
  and Duplex, no signal to chart, no BSSID/channel/security the way
  Wi-Fi's box has), gated the same way as the Wi-Fi section it sits
  alongside and is mutually exclusive with. No sparkline — a link speed
  is a step function that only ever answers "still negotiated the same
  it always does" or "cable's unplugged," not a continuously-varying
  trend RSSI's own sparkline actually earns. Verified live end-to-end:
  relaunched the real app, confirmed `ui-state.log`'s
  `EthernetLinkViewModel.currentSpeedMbps | 1000.0` against this Mac's
  actual Ethernet connection.

- [x] ~~Decide whether to keep the printer alerts feature.~~ **Reversed:
  removed.** Originally decided "keep" on cost grounds (marginal
  `lpstat -l -p` overhead, no popover space, forward-compatible for
  free) without weighing whether it ever shows real content. Revisited
  directly ("does the tile add anything? is SNMP sufficient?") against
  what `DESIGN-NOTES.md`'s "Printer fault detection... a real dead end"
  entry had already established: both CUPS (`lpstat -l -p`) and the
  standard SNMP Printer MIB (`prtAlertTable`/`prtCoverStatus`) were
  tested against a real fault (a physically open drawer) and both came
  back empty or meaningless, on this hardware. A tile that can only
  ever say "OK" is worse than no tile — it implies fault-monitoring
  that isn't real. Removed entirely: `PrinterDiscoveryService
  .printerAlerts()`/`parseAlerts()`/`humanReadable(reasons:)`,
  `ConnectivityViewModel.refreshPrinterAlerts()`/`applyPrinterAlerts()`/
  `printerStatuses`, the `.printerAlert`/`.printerAlertCleared`
  `AppEventKind` cases, and the window-only tile — reachability
  monitoring (`configuredNetworkPrinters()`,
  `infrastructureUnreachable`/`Reachable` events) is completely
  untouched, since that was never in question. A note for the future is
  left directly in `DESIGN-NOTES.md`'s dead-end entry: a different
  printer's firmware might expose real fault detail through either
  path, so this isn't a permanent "never build this" — just a "not on
  this hardware, verify concretely before trying again."

- [ ] **Run `/code-review ultra` on the branch.** User-triggered and
  billed, so it can't be launched from a session. Worth it: a manual pass
  over just the concurrency and event handling found a shipped crash and
  a main-thread stall, so a multi-agent pass over the whole branch would
  likely surface more.

- [x] ~~Code review the Screenshot and Bug Report code.~~ **Done
  (`d505b6f`, `6cd9caa`).** Found exactly the recurring bug class this
  was raised to check for: `communityRow`'s `TextField` had no
  `isCapturingScreenshot` guard at all, unlike `bugReportRow`'s identical
  field — never reported since it only triggers if a community-string
  edit happens to be in progress at the exact moment a capture fires.
  Fixed, then hardened structurally: extracted a shared
  `ContentView.captureSafeTextField` (mirroring how `scrollBox`/
  `tile(fixedHeight:)` already centralize the equivalent
  `NoBounceScrollView` guard) so both call sites — and any future one —
  go through one path instead of hand-rolling the branch. Added a
  "Capture-mode guard audit" test that scans the source for raw
  `TextField`/`NoBounceScrollView` constructions and pins the count, so
  a future bypass fails the build. Also added retention for the
  screenshots/state-dumps directories (30 days, neither had any before)
  and a privacy notice in every state dump, both raised as follow-on
  ideas during the same pass.

- [ ] **Auto-confirm the ISP Edge Router hop via an RDAP organization
  walk, instead of always requiring a manual star.** Raised directly:
  on most small/home networks, the ISP edge really is the 2nd hop (the
  first non-RFC1918 address) — could NMS just trust that and start
  polling, asking the user only when the topology is genuinely
  ambiguous? Then extended, also raised directly: what about a
  traditional corporate network using real public IP addresses
  internally, with a complicated WAN — can RDAP detect *that* case
  too? (It can — see below; the two questions turn out to need the
  same underlying mechanism.)

  **The needed signal mostly already exists.**
  `TracerouteViewModel.suggestedEdgeHop` already picks the first
  non-RFC1918 hop, and `TracerouteHop.isLocal` already folds CGNAT into
  that same check — so a CGNAT hop is already correctly excluded, not
  mistaken for the answer. `leadingNonInternetHopCount` already counts
  exactly "how many private/CGNAT hops precede the first public one":
  `1` is the simple single-NAT home case (your own router, then the
  real internet); `2+` means an extra NAT layer — the customer's own
  second router, or the ISP's own CGNAT — and its own doc comment
  already says "traceroute alone can't tell which" at that point. So
  "CGNAT makes it more complicated" is already handled correctly today;
  the open question is only whether the simple (`== 1`) case is safe to
  auto-confirm without asking.

  **It isn't, on its own — `suggestedEdgeHop`'s own doc comment already
  names the failure mode.** A campus/enterprise network produces the
  *identical* signature: hop 1 = local gateway (RFC 1918), hop 2 = the
  organization's own public-IP border router — same
  `leadingNonInternetHopCount == 1` as a genuine home ISP, but hop 2
  isn't the ISP. Auto-confirming on hop count alone would silently
  start monitoring the wrong device there — worse than one manual
  click, since nothing would visibly look broken afterward.

  **A second, more extreme version of the same failure, also raised
  directly: a traditional corporate network handing out real public IP
  addresses internally, with a complicated multi-site WAN.** Some
  large/older organizations never adopted RFC 1918 internally — the
  Mac's own interface address, and every hop for a while, can already
  be real, non-RFC1918, non-CGNAT public IPs, all still inside the
  company's own network. `leadingNonInternetHopCount` would read `0`
  here (nothing private to count), and `suggestedEdgeHop` would point
  straight at hop 1 — confidently wrong, since hop 1 is just the
  nearest corporate router, not any kind of internet edge.

  **The fix generalizes to a single algorithm covering both failure
  modes, not two separate special cases.** The real primitive both
  scenarios need is "which organization does this address belong to,"
  via RDAP (`ISPIdentityService.identify(ip:)` — already takes an
  arbitrary IP, not just the Mac's own public one):
  1. Identify "home org" — RDAP the Mac's own local interface address
     if it's already public (the traditional-corporate-network case);
     otherwise RDAP the first hop past the private/CGNAT prefix (the
     home-network case, where "home org" is just the ISP itself, found
     in one step).
  2. Walk the trace forward from there, RDAP-ing each hop in turn
     (skipping any still RFC1918/CGNAT — `isLocal` already identifies
     those, and a CGNAT address won't carry an individually-delegated
     RDAP registrant anyway, so it should be skipped rather than
     treated as "no match, stop here").
  3. **The first hop whose RDAP org genuinely differs from "home org"
     is the real candidate** — not the first non-RFC1918 hop. On a
     simple home network this is still hop 2, same answer as today. On
     a corporate network with real public IPs and a complicated WAN, it
     correctly walks *through* however many internal hops share the
     company's own org before finding where the network actually
     hands off to a different provider — the genuine edge, rather than
     confidently naming hop 1.

  **The goal, stated directly: auto-detect *and* auto-configure simple
  networks; for complex ones, at minimum identify and explain what's
  going on rather than presenting a bare hop list — and auto-configure
  those too whenever the walk still lands on a confident answer.** This
  is deliberately three tiers, not the binary "auto-confirm or fall
  back to manual" it might sound like above:
  1. **Simple** (home org found in one step, next hop is a different
     org) — auto-configure. The common case, and where this pays off
     most immediately.
  2. **Complex but still resolvable** (several same-org hops walked
     through — CGNAT, a multi-hop corporate WAN — before a confident
     organization change is found) — **also auto-configure.** The walk
     doesn't stop being trustworthy just because it took more than one
     step; a corporate network with a 5-hop internal WAN that
     eventually hands off to a clearly different org is exactly the
     "auto-configuration of complex scenarios is even better" case,
     not one to punt on by default.
  3. **Genuinely ambiguous** (no RDAP org resolves for any hop, the
     walk runs out of hops still matching "home org" without ever
     finding a different one, multiple hops flip organizations back and
     forth unconvincingly, or a hop is unreachable/times out before a
     boundary is found) — fall back to asking, but *say what was
     found*: which hops were walked, which organizations they
     resolved to (or "no answer"), and why no confident boundary
     emerged — not just today's plain numbered hop list with no
     annotation. Even when NMS can't safely pick for you, it should be
     able to say *why* this network's topology is the harder case,
     which is real information the current UI (a bare list plus a
     star) doesn't surface at all today.

  Never confirm silently on address-space classification (RFC1918 vs.
  not) alone in any tier — that raw classification is the exact
  assumption both failure modes above break; the organization walk is
  what actually earns the auto-configuration, at any hop count.

  **Concrete next step before any code**, same discipline as the
  neighboring "cross-check via SNMP"/"discover via router SNMP" items:
  verify the org-match actually discriminates in practice on at least
  two real, different topologies — this household's own simple network
  (`leadingNonInternetHopCount == 1`) is one data point, not proof the
  approach generalizes. A real corporate/campus network to test the
  "walk past several same-org hops" behavior against would be
  especially valuable, since that's the harder case neither this app
  nor its author has real data on yet. RDAP registrant names are
  already known to be inconsistent (legal entity vs. brand vs. reseller
  — see this same file's ISP status-page table), so a same-org false
  mismatch is a real risk worth checking for before trusting the
  comparison to gate anything automatic.

  **If built, this should log a new neutral `AppEventKind` — raised
  directly as the natural place to explain tier 3, not just an
  afterthought for tiers 1/2.** Same shape as `ispOrganizationChanged`/
  `subnetTooLargeToScan`: informational, not an up/down pair, logged
  once per genuine topology finding rather than on every 10-minute
  retrace. Two cases, one kind, message text differing (same pattern
  `multipleNATLayersDetected` already uses for its own two directions):
  - **Tiers 1/2 (auto-configured):** "ISP Edge Router identified
    automatically: hop N (organization)" — optionally naming how many
    same-org hops were walked through for tier 2, so a complex-but-
    resolved case reads differently from the trivial one. This is what
    makes the auto-confirmation visible rather than silent — a user can
    always see which hop is actually being monitored and object via the
    existing manual star if it's ever wrong, the same "never silently
    and permanently decide something health-critical" posture the rest
    of this app already follows (see `SNMPViewModel.rebuildDeviceList`'s
    own "pruning automatically is far worse to get wrong than leaving a
    stale row" reasoning for the same instinct applied elsewhere).
  - **Tier 3 (couldn't resolve automatically):** explains *why* —
    e.g. "Couldn't identify your ISP automatically: N hops share your
    own network's organization with no clear handoff — pick the right
    one manually" or "no organization could be resolved for any hop."
    This is the direct answer to "identify complex scenarios" even
    when auto-configuration isn't safe: the user gets a real, specific
    reason logged in Events, not just a bare hop list defaulting
    silently to "Not confirmed" the way it does today.

  Logged once per genuine change (a new trace landing on a different
  tier or a different hop than last time), not on every periodic
  retrace that reaches the same conclusion — same "only a real
  transition logs anything" convention `logAddressingChangeIfNeeded`
  already follows for `multipleNATLayersDetected`.

- [x] ~~Monitor a user-configured DDNS hostname for staleness — does it
  actually still point at the current public IP?~~ **Shipped**:
  `DDNSResolutionService` (`dig @1.1.1.1`, not `getaddrinfo` — see that
  type's own doc comment for why the anti-caching trick below couldn't
  apply here), `DDNSViewModel` (per-hostname `syncState`: `.current`/
  `.stale`/`.blockedByCGNAT`, the last one reusing
  `TracerouteViewModel.includesConfirmedCGNAT` rather than adding new
  detection, and preempting the plain comparison rather than
  supplementing it — see `syncState`'s own doc comment), one or more
  hostnames configured via a new Preferences section
  (`FeatureFlags.DDNSHostname`, same shape `UserAddedSaaSSite` already
  established) with a 1-minute/5-minute check-interval picker, three
  new `AppEventKind` cases (`ddnsRecordStale`/`ddnsRecordCurrent`/
  `ddnsBlockedByCGNAT`), a window-only summary row in the Info tile
  (colored dot + hostname/count + interval, a manual "check now" button,
  full per-hostname detail in the tooltip), and `FailureInjector
  .applyDDNSChanges`/`isDDNSForced` for scripted testing of the
  transition logic. Verified against a real, live stale DDNS record —
  a genuine full round trip (real stale → fault-injected stale → real
  recovery), not just unit tests.

- [ ] **An external vantage point for real firewall/ACL reachability
  testing, triggered by a firewall change or router firmware update —
  a bigger idea than anything else in this file, and a real, deliberate
  exception to "no server, local-only" if built.** Raised directly,
  building on the CGNAT/port-forwarding item above: NMS can already say
  "CGNAT is present, so inbound access likely won't work," but can't
  say "here's what's *actually* reachable from outside right now" —
  that needs something probing the connection from outside it, which
  nothing running only on this Mac can do.

  **The IPv6 framing is the sharpest version of why this matters, and
  is worth stating precisely.** Under IPv4 with NAT, a home network's
  internal devices are protected *by construction*, almost as a side
  effect: no explicit forwarding rule means no path in at all, whether
  or not the firewall itself is configured thoughtfully. IPv6 typically
  has no NAT — a modern IPv6 deployment commonly hands out a real,
  globally-routable address to every device on the LAN directly. That
  removes the accidental backstop entirely: once IPv6 is in the
  picture, the router/firewall's actual ACL ruleset is the *only* thing
  standing between the internet and every device behind it, not a
  fallback under an already-restrictive NAT boundary. A misconfigured
  rule, or a firmware update that silently resets or changes default
  ACL behavior, has a much larger and more direct blast radius than the
  IPv4-behind-NAT equivalent ever did.

  **Real prerequisite, not yet true**: this app has **no IPv6 support
  at all** today — confirmed directly, not assumed. `IPClassifier`/
  `SubnetCalculator` only have IPv4 concepts (`isRFC1918`, `isCGNAT`,
  `packedIPv4`), and `SystemConfigurationService`'s one IPv6 mention
  only watches `State:/Network/Global/IPv6` for change-notification
  purposes — it never reads or displays an actual IPv6 address
  anywhere. This idea becomes *critical* specifically once IPv6 support
  is real; until then it's still a genuinely useful idea for IPv4/NAT
  setups (confirming a port-forward rule actually works, not just that
  it's configured), just lower-stakes. IPv6 support itself belongs on
  this list as its own real, sizeable prerequisite item, not assumed
  as a given.

  **Real, personal motivation behind this, not just a hypothetical**:
  "every time I update or reconfigure my firewall/router I wish I had
  this feature" — raised directly, from actual recurring experience,
  not a speculative nice-to-have.

  **Revised privacy framing, correcting an overstatement above**: a
  public IPv4 address and an IPv6 delegated prefix aren't secret in the
  first place — every server this Mac has ever connected to already
  sees exactly that, every time, as a basic fact of how routing works.
  Raised directly as a correction, and it's right: exposing that
  specific information to an external checker isn't a new disclosure
  in itself. What the earlier framing actually got at, more precisely,
  is the *self-hosted* question below — not "is the IP sensitive" (it
  isn't) but "is a new third party now in the loop, and does it keep
  any record of having tested this specific network." A self-hosted
  checker answers that cleanly: there's no third party at all, since
  the "external" vantage point is infrastructure the user already
  rents and trusts (a VPS), not a stranger's service.

  **Concretely proposed, per that same idea, raised directly: a
  self-hostable Docker container, as its own separate open-source
  project, not a feature built into NMS itself.** NMS stays a macOS
  client; the checker is a small, focused, cross-platform service
  meant to run anywhere with a real public IP — same separation of
  concerns this app already applies everywhere else (shelling out to
  `ping`/`traceroute`/`snmpget` rather than reimplementing them, RDAP
  instead of a hand-rolled WHOIS client). A sketch, not a spec:
  - **Stateless HTTP(S) API, no client-supplied target address at
    all** — the checker uses the *source* address of the incoming
    request itself as the thing to test (the same well-established
    pattern sites like canyouseeme.org already use), so there's no way
    to ask it to test an unrelated third party's network by mistake or
    on purpose. A request like `GET /check?tcp=51820,32400` gets back
    open/closed/filtered for each port, tested by the checker
    attempting its own outbound connection back to the requester's
    address.
  - **IPv6 prefix delegation, reported the same way**: if the
    connecting request arrived over IPv6, the checker reports the
    prefix it saw (typically the first 64 bits — the usual DHCPv6-PD
    delegation size) alongside the per-port results, giving a direct
    answer to "did my ISP hand me a new prefix" the same way the
    existing `publicIPChanged` event already answers that question for
    IPv4.
  - **Per-address checks are targeted at NMS's own known-active
    addresses, never a scan of the delegated prefix — raised directly,
    and a real correction to the sketch above.** A /64 host space is
    2^64 addresses; nothing like IPv4's /24, and not something any
    external checker could or should attempt to sweep the way
    `SNMPViewModel` sweeps a small IPv4 subnet. The right shape instead:
    NMS already knows its own real, currently-active IPv6 address(es)
    from its own interface — that's what gets sent to the checker for
    testing, not the prefix itself. Extending to *other* LAN devices'
    real addresses (not just this Mac's own) has a concrete, already-
    proven-shaped mechanism available: `LANDiscoveryService` already
    reads the local IPv4 ARP cache (`arp -n -a`) to find devices this
    Mac has actually talked to, rather than scanning; macOS's IPv6
    neighbor cache (`ndp -a`) is the direct structural equivalent for
    IPv6 — reading it would surface exactly the same kind of
    already-known-active address list ARP does for v4, no new
    discovery mechanism invented, just the same "read what the OS
    already knows" pattern applied to NDP instead of ARP. Only ever
    testing addresses NMS has independent evidence are real and active
    is also the tighter version of the privacy point above: the checker
    never learns the *shape* of the network (which parts of a /64 are
    populated), only the specific addresses someone chose to have
    tested.

    **The existing SNMP composite device list is a second, higher-value
    source for the same targeting — raised directly, and it adds
    something NDP alone can't: names, not just addresses.**
    `SNMPViewModel.devices` (already MAC-deduplicated via
    `mergingSharedMACs`, so a VRRP pair or shared-interface device isn't
    tested twice under two addresses) is a curated set of devices the
    user already cares enough about to have SNMP identify — the router,
    switches, APs, anything else that answers — as opposed to NDP's raw
    cache, which reflects *everything* this Mac has recently talked to,
    phones and guests included, with no sense of which entries actually
    matter. Correlating by MAC address (the same key `macByAddress()`
    already uses to merge shared-interface IPv4 aliases) between an
    SNMP device's known MAC and NDP's MAC-to-IPv6 mappings would answer
    "which IPv6 address, if any, belongs to *this specific, already-
    named device*" — turning an external check result from an anonymous
    "port 443 open on `fe80::...`" into "port 443 open on your router,"
    the same legibility SNMP discovery already brings to the IPv4 device
    list. Not required for a first version (NDP alone already avoids
    the scan-the-prefix problem), but a real, natural enrichment once
    both pieces exist.
  - **No persistent logging, by design, not just by policy** — since
    the whole value of self-hosting is "no one else's server holds a
    record of my network's ports and history," the reference
    implementation should hold state only for the duration of handling
    one request, nothing written to disk, nothing aggregated across
    requests. Worth stating as a hard design requirement for the
    reference implementation, not left as an assumption.
  - **NMS becomes a configurable client, not tied to one instance** —
    a Preferences field for the checker URL, defaulting to nothing
    (feature inert until someone points it at an instance, whether the
    project's own reference deployment, their own self-hosted one, or
    a friend's). Keeps the "which specific server, if any, my IP goes
    to" a fully user-controlled decision, not a hardcoded dependency.

  **A natural, already-existing trigger for "recheck after a change,"
  found by reusing what's already built rather than inventing new
  detection**: `AppEventKind.snmpDeviceSoftwareChanged` already fires
  when a router/firewall's own `sysDescr` changes (a firmware update),
  for devices that answer SNMP. That's exactly the "router/firewall
  software update" trigger raised directly — re-running the external
  reachability check specifically when that event fires for the
  router, rather than only on a fixed timer, would catch a firmware
  update silently changing ACL defaults close to when it actually
  happens. A direct, user-initiated "check firewall now" action (after
  someone knows they just changed a rule themselves, which nothing on
  this Mac can observe directly) covers the other half of "whenever you
  change your firewall rules."

  **Still worth an explicit Preferences toggle and a clear description
  of what happens, even with the privacy framing corrected above** —
  not because the IP/prefix is sensitive, but because this is the
  first feature in this app whose entire purpose is *actively probing
  this specific network's own defenses* from outside it, which is
  worth a deliberate "yes, do this" rather than silently defaulting on
  the moment a checker URL happens to be configured.

  Not proposing to build any of this now — flagging it as the biggest,
  most architecturally different idea in this file, worth returning to
  once IPv6 support is real, and worth scoping the companion Docker
  project (its own repo, its own API contract, its own README) as a
  deliberate first step before NMS's own client side is written.

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
- **IPv4 Record Route (or other IP options) for explicit path recording**,
  raised from prior experience with them on Cisco routers. Largely
  non-functional on today's public internet: modern backbone/ISP routers
  widely treat any packet carrying IP options as a slow-path case and
  drop, rate-limit, or ignore them outright — long-standing practice from
  when options-bearing packets were a common scanning/DoS vector, and
  because fast-path forwarding hardware doesn't handle them. Even where a
  router does cooperate, the classic 40-byte options field caps Record
  Route at about 9 hops before running out of room. `TracerouteService`'s
  existing TTL-increment/ICMP-Time-Exceeded technique already gets the
  same "explicit path recording" outcome without needing any router
  cooperation beyond generating a TTL-expiry ICMP message, which every
  router still does regardless of how it treats IP options — so this
  would add nothing traceroute doesn't already show, and would likely
  work less reliably given how often options get dropped in transit.
