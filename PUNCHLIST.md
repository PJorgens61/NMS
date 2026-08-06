# Punchlist

Open items, tracked here so they survive between sessions. Not a spec —
see `DESIGN-NOTES.md` for the reasoning behind anything non-obvious.
Actual defects live in `BUGS.md` instead — this file is ideas, testing
tasks, and decisions. Check items off or delete them as they land; add
new ones as they come up.

Resolved items are moved out to keep this file scannable, not deleted —
see `docs/archive/PUNCHLIST-resolved-2026-08-04.md` and
`docs/archive/PUNCHLIST-resolved-2026-08-05.md` for everything checked
off as of those dates, full reasoning intact.

## Open

- [ ] **Idea: for a private-addressed hop, distinguish "the ISP has no
  reverse-DNS zone for this space" from "the zone exists but this host
  isn't in it."** Raised directly during field testing (2026-08-05,
  Comcast residential/DOCSIS) — real network specifics deliberately left
  out of this entry, see the standing privacy rule this file's own
  conventions already follow.

  The question that started this: does an ISP register PTR names for
  its own RFC1918-addressed internal hops (a CMTS/regional-aggregation
  router, say) the same way it does for its public-facing ones? Tested
  live, empirically, not just theorized:

  1. A plain recursive `dig -x` for the private hop, against three
     different resolvers (the local router, the ISP's own public
     resolver, and a third-party one) — all three came back `NXDOMAIN`.
     Read naively, that looks like "no record exists anywhere."
  2. But `dig -x <public-hop-ip> +trace` finds the ISP's *own*
     authoritative nameservers (the ones genuinely delegated their real
     public reverse zones, confirmed via the normal root → ARIN →
     ISP-NS delegation chain).
  3. Querying *those exact same authoritative servers* directly for the
     `SOA` of the private hop's own `/24` reverse zone (not just the
     `PTR` for one host) returned a real, live, `aa`-flagged SOA record
     — same admin-contact pattern, same primary nameserver, as the
     ISP's confirmed-real public zone. The zone is genuinely
     provisioned, on the same infrastructure, just apparently unpopulated
     (checked four addresses in it, all `NXDOMAIN` at the authoritative
     server too — not merely a caching/visibility artifact upstream).

  So "NXDOMAIN from a recursive resolver" collapses two genuinely
  different ISP postures into one identical-looking answer: *no
  reverse-DNS infrastructure for this space at all* vs. *the
  infrastructure is live and actively managed, they just haven't named
  this particular host*. The second case is a real, if soft, signal
  that a hop is deliberately-operated ISP infrastructure (worth
  distinguishing from customer-side gear) even when it never gets a
  human-readable name — relevant to the still-open "private hop might
  be the real circuit terminator, not yet-reached ISP" idea elsewhere
  in this file/session.

  **If ever built:** a debug-only deep-PTR check — `dig +trace` on a
  same-`/24` **public** hop already resolved a name for (there's
  usually one nearby in a real ISP trace) to find the ISP's own
  authoritative nameservers, then query those directly for the private
  hop's zone `SOA`. `NOERROR`+real SOA vs. `REFUSED`/no answer is the
  actual distinguishing signal — the plain recursive `PTR` lookup
  already done via `ReverseDNSService`/`dig @1.1.1.1` can't tell these
  apart on its own. Speculative, not scoped further than this — would
  need a real UI treatment (a small badge/note, not a whole new tile)
  and isn't worth building without a second real-world case confirming
  the pattern generalizes past one ISP.

- [ ] **Framework to remember: "the same ISP name" can mean two
  structurally different topologies, and the confirmed edge hop's
  owner doesn't always match the ISP you think you're on.** Raised
  directly during field testing (2026-08-05, two different physical
  locations, same ISP by name) — real network specifics deliberately
  left out, same reasoning as the entry above.

  Two connections, both presumed/labeled the same residential cable
  ISP, looked nothing alike:

  1. **Residential-shaped**: a private/RFC1918-addressed hop (see the
     deep-PTR entry above) sitting *before* the first hop that resolves
     to the ISP's own named public backbone — confirmed edge landed
     several hops out. CGNAT-style shape, even though the connection's
     actual public IP wasn't CGNAT space itself — just the ISP's own
     internal aggregation layer using private addressing.
  2. **Business/commercial-shaped**: no private hop at all before the
     first public address — confirmed edge landed one hop closer in.
     Looked "simpler," but the address at that hop turned out (checked
     via `whois`) to belong to a **different carrier entirely** — a
     wholesale/transit provider, not the ISP whose name was on the
     account. Zero PTR either direction, so hostname alone gave no
     hint of the mismatch; only an ownership/ASN lookup on the
     confirmed hop's address caught it.

  **The generalizable point**: hop *count*/shape (private-hop-then-public
  vs. straight-to-public) is not a reliable signal for "which carrier
  actually owns this circuit," especially for business/commercial
  service, which is frequently delivered over leased or wholesale
  backhaul from a different company than the one on the bill. A
  same-named ISP can present two topologically different faces
  depending on residential-vs-commercial provisioning, and the
  confirmed edge hop can silently belong to a carrier other than the
  presumed one.

  **If ever built:** `ISPIdentityService` already does an RDAP/WHOIS-
  style lookup for the public IP itself — the natural extension is
  running that *same* lookup against the confirmed edge hop's address
  too, and flagging a mismatch ("your ISP is identified as X, but the
  confirmed edge hop belongs to Y") the same way Path Discovery already
  flags corroboration mismatches from outside vantage points. Another
  case of "a second vantage point catches what one check alone can't,"
  same theme as Path Discovery and Firewall Visibility — not scoped
  further than that yet, needs a second real-world case of the mismatch
  before it's worth building.

- [ ] **Field-test sweep, 2026-08-05 — multiple locations in rapid
  succession (a coffee shop, a Target, an AT&T-served Starbucks, a
  Burger King), same session as the two entries above.** Real network
  specifics deliberately left out. Grouped bugs/ideas raised live,
  not yet investigated in code — capturing before they're lost, not
  claiming root cause on any of these yet.

  - **Possible stale-data-after-network-switch issue(s).** Two reports:
    "Firewall Visibility may have data from previous networks," and
    separately wondering whether a topology view was "a leftover from
    [the previous location]." The second is likely just expected
    behavior, not a bug — Path Discovery only runs on manual trigger,
    doesn't auto-rerun on network change, so an already-open results
    page legitimately keeps showing the last network's run until
    re-triggered. The FW one needs an actual look: does
    `FirewallVisibilityViewModel`'s scan history/state correctly scope
    to `currentNetworkFingerprint` the way `TracerouteViewModel
    .reloadMonitoredHop()` explicitly does (see that function's own
    doc comment on the two-beat reset/reload pattern needed to avoid
    exactly this), or could a scan started on one network display
    against a different one if you switch mid-scan/right after?
  - **"Path Discovery failed"** at one location — plausibly just a
    real dead/throttled connection at the time (see below), not
    necessarily a bug, but no error detail was captured live to
    confirm which.
  - **SaaS status rows all gray, while a plain HTTP check succeeded**,
    at the Burger King location. `SaaSMonitoringViewModel`'s `.unknown`
    (gray) state covers *two* different real cases with one dot: "not
    checked yet" (5-minute interval, hasn't fired since joining) and
    "the check itself failed" (`"Could not check status"`/`"Not
    reachable"`) — genuinely ambiguous from the UI alone which one
    this was. Plausible real cause given the location: a captive-
    portal/restrictive-WiFi allowlist that lets one known-good HTTP
    target through while blocking or interfering with the many
    different third-party SaaS status-page domains. Not confirmed
    live either way — whether it resolved after the next 5-minute
    check wasn't observed.
  - **Idea: rename "Speed Test" to "HTTP Speed Test."** Raised directly
    — the existing feature is HTTP-based (per its own description
    elsewhere: "up to ~50MB per run"), not a true bandwidth test like
    Ookla/iPerf; the current label doesn't signal that distinction.
  - **Confirmed gap, not just a guess: the topology diagram never does
    a local reverse-DNS fallback for backside hops.** Raised directly
    ("topology display doesn't have a dns name for every hop. is it
    checking?") and checked in the code, not assumed — `grep` across
    `TopologyBuilder.swift`/`DebugToolsView.swift` shows `ReverseDNSService`
    is never called anywhere in the Path Discovery flow. Every backside
    hop's hostname is whatever Globalping's own `resolvedHostname`
    field returned, verbatim; a hop Globalping left `null` just shows
    as a bare IP in the diagram, permanently, even if a plain local
    `dig -x`/`getnameinfo` against it would resolve fine. The original
    topology-diagram design plan explicitly called for exactly this
    fallback ("reused for backside hops Globalping didn't already
    resolve") — it just never got implemented. A real, scoped gap:
    for each backside hop with `hostname == nil`, call
    `ReverseDNSService.hostname(for:)` the same way frontside hops
    already get enriched, before building the topology.
  - **Idea: show the SSID in the Wi-Fi/Network tile.** Raised directly,
    not currently shown anywhere in the merged Network tile as far as
    this session confirmed.
  - **Suspected throttling at one location** — connection seemed
    degraded, user tried rotating the Mac's Wi-Fi MAC address as a
    live test (their own manual action, not an NMS feature) to see if
    a fresh MAC changed the behavior. No conclusive before/after
    comparison captured live. Not necessarily an NMS idea by itself,
    but a real motivating case for the per-host fallback probe idea
    already open elsewhere in this file (ICMP alone can't distinguish
    "throttled" from "actually down").
  - **"Path and ISP edge confused"** — a UI/conceptual confusion
    flagged live between the Path Discovery feature and the ISP Edge
    Router concept/row. Not enough detail captured in the moment to
    know if this is a real UI clarity gap or a one-off mix-up; worth
    a fresh look next session rather than guessing at the fix now.
  - **Confirmed via NMS's own `ISPIdentityService`** (not just manual
    `whois`, as in the entry above): correctly identified Verizon
    Business at the Target-adjacent location — real, live validation
    of that feature against ground truth already independently
    confirmed by hand.
  - **A third real topology data point, different ISP entirely**: the
    AT&T-served location (hostname pattern: `lightspeed`/`sbcglobal.net`
    — AT&T's fiber/DSL consumer branding) showed the *same*
    CGNAT-shaped topology (a private hop before the first public one)
    as the original cable-ISP case, not the simpler business-style
    shape from the Target-adjacent location. That makes it two
    different ISPs (cable and AT&T fiber/DSL) both showing the
    private-hop-then-public shape, vs. one commercial connection that
    didn't — starting to look like a residential-vs-commercial
    distinction more than a per-ISP one.
  - **Fourth data point, Burger King: ISP is Etheric Networks**
    (ethericnetworks.com) — a small, wholly locally-owned Bay Area ISP
    (Burlingame, CA, operating since 2003), hybrid fixed-wireless +
    fiber over 300+ miles of their own dark fiber, explicitly
    business/commercial-focused ("connecting where others can't" —
    construction sites, healthcare, schools, retail). Topology observed
    live as simple, non-CGNAT-shaped — no private hop before the first
    public one, consistent with the Target/Verizon-Business case rather
    than the residential cable/AT&T shape. Strengthens the
    residential-vs-commercial-shape hypothesis above: a *third*
    business-class connection, from a *third* different carrier, again
    showing the simple shape — this is looking like a real pattern
    (provisioning-model-based), not coincidence across two data points.
  - **UI/possible confusion**: Network tile reported as slow to update
    right after joining a new network — raised as "do we still have a
    race condition?" (echoing the Firewall Visibility stale-data
    question above). Not investigated live; worth checking whether
    `NetworkIdentityViewModel`'s reset/reload two-beat pattern (see
    `TracerouteViewModel.reloadMonitoredHop`'s doc comment) is actually
    followed by every tile that depends on network identity, or just
    some of them.

    **Second, more concrete instance of the same suspected bug**, same
    field-testing day, different location (an "Xfinity reseller"
    network): ISP Edge Router briefly displayed a different ISP than
    the one this network's own recorded provider-edge history ever
    actually logged. Checked directly — this network's own history
    (`ProviderEdgeRecord`, filtered by its exact `networkFingerprint`)
    shows only one ISP's hostnames, both timestamped after this
    network's own `firstSeenAt`; the other ISP never appears in it at
    all. Strong circumstantial evidence this was a brief leftover
    display from the *previous* network during the switch-over window,
    not a real second edge for this one — timing lines up (the
    previous network's own last-seen public IP was only ~2 minutes
    before this one started). Not proven without having captured the
    exact transitional moment live, but two independent live reports
    of "wrong/stale ISP shown right after switching networks" in one
    session is worth treating as a real bug, not a fluke, next time
    this file is worked from.

- [ ] **Idea: stop trying to determine *the* ISP Edge Router — monitor
  every hop in the first few instead, and drop the confirmation step
  entirely.** Raised directly, live, after a full session of finding
  real cases where "the" edge hop is genuinely ambiguous or
  mis-identified: a residential ISP's edge redundantly alternating
  between two real routers (see the framework entry above), a private
  hop that might be the true circuit terminator instead of the
  "confirmed" public one (see the deep-PTR entry above), and a
  confirmed hop whose owner didn't match the presumed ISP at all
  (Verizon Business on a connection thought to be something else).
  Every one of these is a variant of the same root problem: picking
  *one* hop as "the" edge and trusting it.

  **The proposal**: monitor every hop in, say, the first 3-4 positions
  past the home router, unconditionally — no `suggestedEdgeHop`
  heuristic, no star-button confirmation step, no possibility of
  picking wrong. Real tradeoff, not a free win: trades one clean
  "ISP Edge Router: up/down" signal for several rows of raw hop
  status, which is more coverage but more to interpret — "hop 2 timed
  out" doesn't say *is my ISP down* the way one confirmed row does
  today. Would also need real UI rework (`PathToInternetTile` currently
  has exactly one edge row; this implies a small group of them) rather
  than a quiet backend change. Not scoped further than this — a real
  architectural alternative worth weighing against incremental fixes
  to the current one-hop-confirmed model (the private-hop-visibility
  idea, the ISP-identity-mismatch-flagging idea) next time this file
  gets worked from, not decided here.

  **Extension, raised directly right after**: Path Discovery's own
  *reverse* traces (the external-vantage-point/backside data) already
  surface multiple real near-edge ISP routers independently of the
  frontside hop count — today that data feeds the topology diagram and
  the corroboration check against one confirmed hop, but under this
  "monitor everything near the edge" model it could be a second source
  of *which* routers to add to the monitored set, not just frontside
  hops 1-3. Same not-yet-scoped status as the parent idea.

  **Stability caveat, raised directly ("i assume that if an isp router
  responded to pings yesterday it will today")**: true at the *hop
  position* level (something reliably answers at "hop 3"), not
  necessarily at the *specific-IP* level — directly observed the
  Comcast edge alternate between two different real routers within
  minutes (see the framework entry above). Supports keying any
  "monitor everything nearby" set off hop position, same as
  `monitorHop` already does today, not a pinned address.

  **Proposed decision logic, raised directly**: identify every nearby
  ISP router (frontside + backside per the extension above), ping all
  of them, and treat *any* response as proof the access circuit is up
  — an OR across the whole set rather than one confirmed hop's
  pass/fail. Real asymmetry worth carrying into the design: this
  direction is safe (one response definitively proves "up"), but the
  reverse isn't — *all* silent doesn't safely prove "down," since
  ICMP can be selectively deprioritized at an individual router even
  on an otherwise-healthy circuit (same reasoning already behind
  `isLikelyLocalPingFailure` elsewhere in this app). "Any responds"
  can be trusted directly; "none respond" would need the same
  corroboration care already applied elsewhere, not a bare inference.

  **To discuss when back home, not decided remotely**: this whole
  idea, its extension, this caveat, and the proposed OR-logic above —
  flagged directly, not to be acted on without a real conversation
  first.

- [ ] **Not actually a bug: "ISP Edge Router" (Network tile) and the
  confirmed hop's own hostname (Path to Internet) can legitimately
  disagree, and did, live.** A real screenshot from the Xfinity-reseller
  location: Network tile's ISP Edge Router row read "AT&T," while the
  same moment's confirmed/starred hop in Path to Internet resolved to a
  real `*.comcast.net` hostname. Traced to root cause in the code, not
  guessed — `ISPIdentityViewModel.identify(ip:)` does an RDAP/WHOIS
  lookup on the **public IP** (`PublicIPViewModel`'s own address),
  entirely independent of the confirmed hop's traceroute-derived
  hostname. These are two genuinely different signals: who an IP
  block is *registered* to (RDAP) vs. who's *actually operating* it
  (the real router that answers there) — and real-world IPv4 block
  leasing/resale between carriers (very plausible here, given the
  network was itself already identified as an "Xfinity reseller")
  means they can legitimately differ without either being wrong.
  Retracts the earlier "maybe the same race condition" guess two
  entries up for this specific case — that race-condition suspicion
  (Network tile slow to update, ISP Edge Router showing the previous
  network's ISP right after switching) is still open and separate,
  just not what this particular screenshot was showing.

  **If ever worth surfacing**: when `shortOrganizationName` (RDAP) and
  the confirmed hop's own hostname's apparent operator visibly
  disagree, a small note in the UI ("registered to X, operated by Y")
  would turn a confusing-looking contradiction into an actual finding
  — same "two vantage points, more truth than either alone" theme as
  Path Discovery and Firewall Visibility. Not scoped further.

- [ ] **Field-test sweep continued, same day: an AT&T retail store,
  then a second Starbucks in San Mateo.** Real specifics left out,
  same convention as every entry above.

  - At the AT&T store: SaaS statuses started all-gray (same ambiguous
    state as the Burger King entry above) and **confirmed this time**
    to just be "hasn't checked yet," not blocked — went "mostly green"
    after observed live, timed at **~4 minutes**, close to
    `SaaSMonitoringViewModel`'s real 5-minute `checkInterval`. Good
    real data point for the open gray-state-ambiguity idea above: this
    specific case really was just pending, not a captive-portal block.
  - NMS's own CGNAT badge ("CGNAT — shared public IP") confirmed
    correct at this location too, live, against a hop address actually
    inside the reserved `100.64.0.0/10` range — first *directly
    confirmed real* CGNAT this session (earlier cases were CGNAT-
    *shaped* topology without the address itself being in reserved
    space; this one's address genuinely was).
  - Second Starbucks (San Mateo): ISP identified as AT&T, **two**
    private hops before the first public AT&T-hostnamed one (vs. one
    private hop in the earlier AT&T/Starbucks case, and one in Jack's
    original Comcast case) — a third real depth variant of the same
    residential-CGNAT-shaped pattern, this time two layers deep
    instead of one. Worth remembering hop depth isn't fixed even
    within "the same ISP, same shape" — the private-hop-then-public
    pattern can be one *or more* hops deep.

- [ ] **Field-test sweep, final stop same day: a simple AT&T connection,
  hostname pattern confirmed as "Lightspeed."** Real specifics left out,
  same convention as every entry above. Checked what "Lightspeed" actually
  is rather than assuming — it's not a current AT&T product/plan name;
  it was SBC's internal 2004 codename for their original fiber/IPTV
  buildout (publicly launched as U-verse in 2005, after SBC became AT&T).
  The name lives on today only as legacy internal infrastructure naming
  baked into hostnames — consistent with the earlier AT&T data point in
  the entry above this one, which also noted a `lightspeed`/`sbcglobal.net`
  hostname pattern. Topology at this stop was simple (not CGNAT-shaped) —
  worth noting as a data point *against* the earlier residential-vs-
  commercial-shape hypothesis, since AT&T showed both shapes across
  different stops this session (CGNAT-shaped at the earlier AT&T/Starbucks
  stops, simple here) — shape may vary by specific access technology/plan
  under the same carrier, not purely by residential-vs-commercial.
  Last stop of today's field-test sweep — session ended here.

  **Flagged to review next session, not yet gone through**: this whole
  day's sweep (Jack's, Target, the AT&T-served Starbucks, Burger King/
  Etheric, the AT&T store, the second San Mateo Starbucks, and this
  final Lightspeed stop) produced a lot of entries in this file in rapid
  succession, captured live rather than digested. Worth a dedicated pass
  next session to actually read back through all of today's entries,
  decide what's worth scoping into real design work vs. what was a
  one-off observation, before adding more on top.

- [x] **Path Discovery: network name + local reverse-DNS fallback, built
  and shipped same day, once home.** Raised directly, live, mid-field-
  test-sweep: "topology display should include the network name for
  reference later" and "yes, nms topology discovery should check dns for
  every ip and name that it finds to reconcille and combine them into
  logical routers" — closes the two gaps this file's own "Field-test
  sweep" entries above already named (no network label anywhere on the
  diagram; `ReverseDNSService` never called for backside hops, confirmed
  via `grep`, not assumed).

  **Network name**: `DebugToolsView.currentNetworkName` prefers
  `NetworkIdentityViewModel.currentNetwork?.label` (a deliberate human
  choice) over `WiFiSSIDViewModel.currentSSID` (whatever the router
  happens to broadcast), `nil` on Ethernet with no label set. Shows in
  the exported page's `<title>`/`<h1>`/subtitle
  (`LocalDiagnosticServer.renderReverseTracePage`) and is slugged into
  the auto-saved export's own filename
  (`path-discovery-<slug>-<timestamp>.html`,
  `LocalDiagnosticServer.exportReverseTraceHTML`) — the actual point
  raised a few messages later the same day ("can we save the topology
  output for later reference" / "part of the network snapshot?"): a
  folder of these exports was otherwise only distinguishable by
  timestamp, not which network produced them.

  **Reverse-DNS fallback**: `DebugToolsView.enrichBacksideHostnames` —
  for every backside hop Globalping itself left `hostname == nil`, a
  local `ReverseDNSService.hostname(for:)` lookup fills it in before the
  topology is built. Same blocking-call-off-the-cooperative-pool pattern
  already established by `lookUpSiblingAddresses` in the same file
  (`DispatchQueue.global` + `withCheckedContinuation`, never called
  directly inside the `Task`) — `getnameinfo` blocks its calling thread,
  bounded to a 2s timeout per address.

  Paused mid-implementation earlier the same day ("let's implement later
  when i am home... don't build yet"), resumed once actually home.
  Verified for real, not just the unit suite (176/176 still pass): built,
  launched the real signed app, clicked "Path Discovery…" live against
  the real home network — the exported page read "NMS — Path Discovery —
  Thistle" in title/h1/subtitle, the filename was
  `path-discovery-thistle-<timestamp>.html`, and the hop table came back
  fully populated (Sonic/Cogent/Twelve99/Hetzner hostnames all resolved)
  with only genuinely-unresolvable private hops left as bare IPs — no
  PTR record, matching this file's own earlier deep-PTR investigation,
  not a bug in the new fallback.

  **Separate, real finding from the same work, worth its own note**:
  getting to a live-verifiable build required first fixing why a plain
  build+test run needed roughly 20 Keychain password prompts. Root
  cause: ad-hoc code signing (no Team ID — see the deferred "give NMS a
  real code-signing identity" entry below) means `FWKeychain`'s Keychain
  grant never survives a rebuild, and `NMSUITests` relaunching the real
  signed app several times in one run multiplied it badly. Fixed for
  DEBUG builds only, explicitly **not** a substitute for the real fix:
  `FWKeychain` now reads/writes a plain local file
  (`~/Library/Application Support/NMS/fw-device-token.debug-only.txt`)
  instead of touching Keychain at all when `#if DEBUG`. Release builds
  are untouched, still real Keychain — the code-signing Team entry below
  is still the actual fix; this is a testing-convenience workaround,
  raised and approved directly in the moment ("can we write the FW token
  to a persistent file during testing? fix it later?").

  Also hit, and worth remembering for next time rather than re-diagnosing
  from scratch: a genuinely flaky Swift/SwiftData `@Model`-macro compile
  error (`KnownNetwork` reported as not conforming to `Identifiable`,
  which it does via `PersistentModel`) under parallel batch compilation.
  Confirmed nondeterministic, not a real regression — rebuilding the
  exact same code twice failed once and succeeded once, and isolating it
  from every one of today's edits showed bare `HEAD` alone hit it too,
  intermittently. No code changed for this; if it recurs, just retry the
  build before assuming something's actually broken.

- [ ] **Idea: a network snapshot / before-and-after comparison feature.**
  Raised directly: "when i update my network i'd like to know that the
  new network works the same as the old network... did i configure the
  new network to work like the old network. did i overlook some
  detectable configuration on the firewall/router/wifi?" A real,
  distinct use case from anything currently in NMS — today's tools
  (Known Networks history, Path to Internet, SNMP Devices) all show
  *one* network's current state, not a structured comparison between
  two points in time for what's nominally "the same" network after a
  hardware/config change.

  Not scoped in any technical detail yet — worth thinking through next
  session what "the same setup" even means to capture and diff
  (DHCP/DNS config, SNMP device inventory and their reported configs,
  Wi-Fi channel/security settings, port-forward rules via Firewall
  Visibility, the confirmed ISP edge shape) and what a side-by-side
  table would actually look like, rather than guessing at a design
  here. A real, well-motivated idea, just needs its own design pass.

  **Related idea, raised directly as a question ("can we save the
  topology output for later reference? ... part of the network
  snapshot?")**: yes, this looks like a building block of the above,
  not a separate feature. Today's Path Discovery runs already produce
  exactly this kind of saved artifact for free — every run auto-exports
  a timestamped local HTML snapshot (`script/diagnostic-exports/
  path-discovery-<timestamp>.html`, via `LocalDiagnosticServer
  .exportReverseTraceHTML`, local-only/gitignored) — so "save topology
  output for later reference" already happens today, just isn't yet
  labeled or indexed in any way that makes a folder of them useful for
  comparison. That's exactly what the paused `networkName` threading
  work (see `LocalDiagnosticServer.swift`'s in-progress, uncommitted
  changes — explicitly on hold until back home) would fix: right now
  those saved exports are only distinguishable by timestamp, not by
  which network they were taken on. If the snapshot/comparison feature
  above ever gets built, these existing per-run topology exports are a
  natural data source to diff against, once they're actually
  labeled/network-scoped rather than anonymous timestamped files.

- [ ] **Give NMS a real (free Personal Team) code-signing identity —
  approved, deferred to a later session ("yes, but tomorrow").** Currently
  `CODE_SIGN_STYLE = Automatic` with no team set — confirmed via
  `codesign -dvvv` on a real build: `Signature=adhoc`, `TeamIdentifier=not
  set`. Two real, live-confirmed problems trace back to this:

  1. **Firewall Visibility's Keychain token re-prompts for a password on
     every rebuild.** macOS's "Always Allow" Keychain grant is tied to
     the requesting app's code identity; ad-hoc signing has no stable
     identity across rebuilds — confirmed live that the ad-hoc
     signature's hash changes even with zero source changes (the "Stamp
     build info" script embeds a fresh timestamp every build), so every
     rebuild looks like a brand-new untrusted app asking for the same
     secret again.
  2. **iCloud Keychain sync for that same token doesn't work at all.**
     Tried adding `kSecAttrSynchronizable` to `FWKeychain` so the token
     could sync across the user's own Macs instead of being copied by
     hand (raised directly: "i need to manually copy the token onto
     every mac that runs nms?") — confirmed live `SecItemAdd` fails with
     `errSecMissingEntitlement`/-34018, since synchronizable Keychain
     items need a real Team Identifier to scope the access group. Reverted
     to local-only for now (`FWKeychain.swift`'s own doc comment records
     the finding).

  **Fix**: add a Development Team in Xcode's Signing & Capabilities for
  the NMS target (a free Personal Team, signed into any Apple ID, is
  enough — no paid account needed), plus a Keychain Sharing entitlement
  if re-enabling `kSecAttrSynchronizable` at the same time. A real posture
  change from `DEV-SETUP.md`'s current "no paid account needed to run
  locally" framing (still true, but worth updating the wording so it
  doesn't read as "no Apple ID needed at all"), and affects every machine
  that builds NMS — worth a heads-up on the cross-machine sync issue (#6)
  before/after landing it.

- [ ] **Idea: per-host fallback probe method (HTTP/HTTPS/DNS, not just
  ICMP) for connectivity targets.** Raised directly (2026-08-04) while
  comparing NMS against `NetViews` (a paid, professional macOS network
  diagnostic app) — NetViews lets you right-click a host in its ping
  monitor and switch it to answer-based-on-HTTP/HTTPS/DNS instead of
  ICMP, specifically for networks where ping is blocked but the host
  still answers on those other ports.

  Every check target today goes through `ConnectivityService.Target`
  (label, host, timeout) and `check(_:)`, which always shells out to
  `/sbin/ping` — see `ConnectivityService.swift`. DNS and HTTP checks
  already exist (`ConnectivityViewModel.runDNSCheck`/`runHTTPCheck`),
  but as two *fixed, global* probes (one DNS lookup, one HTTP fetch),
  not a per-host alternative for Router/Public IP/ISP Edge Router/
  SNMP-confirmed infrastructure/printers.

  **This would be a genuine alternative to, not just an addition
  alongside, `isLikelyLocalPingFailure`/`shouldSuppressAsLocalInterference`.**
  That heuristic exists because ICMP-only checking can't tell "the
  network is fine but something local starved the `ping` subprocesses"
  from "the host is actually down" — it currently *guesses* from the
  pattern (path-critical pings all fail while DNS/HTTP succeed) and
  suppresses the event log for the guessed-interference case. A host
  known to have ICMP blocked (a firewall, a VPN endpoint, certain
  managed switches) could instead get a *true* answer every round by
  checking it over HTTP/HTTPS/DNS specifically, rather than being
  guessed-around every time.

  Open questions, not resolved: per-host method needs to be
  user-configurable somewhere (a picker in the Network tile's own row,
  or in Preferences alongside the other per-feature settings) since
  there's no way to auto-detect "this host blocks ICMP but answers
  HTTP" without first trying and failing at ICMP anyway; and whether
  DNS-as-a-liveness-check makes sense for an arbitrary LAN host at all
  (most SNMP devices/printers don't run a DNS resolver — HTTP/HTTPS
  is the more broadly applicable fallback of the two for LAN targets,
  DNS mattering more for the existing WAN-facing DNS-server check).

- [x] **Path Discovery, built and shipped**: a debug-only "Path
  Discovery…" button (new "Debug Tools" window, alongside Diagnostic
  Log — see that window's own entry below for why debug buttons moved
  out of the main footer) runs a real multi-source reverse traceroute
  via Globalping toward this Mac's own public IP, opens the result as a
  local web page, and — the actual point, raised directly ("the info
  collected should inform the path to internet function") — feeds back
  into Path to Internet: whenever a probe's last hop before reaching
  this Mac matches the confirmed ISP edge hop, that's recorded
  (`ProviderEdgeRecord.externallyCorroboratedAt`/
  `pathDiscoveryProbeCount`/`pathDiscoveryCorroboratingCount`) and shown
  as a small corroboration line under the confirmed hop. New service:
  `GlobalpingReverseTraceService` (debug-only, unauthenticated, matches
  `ISPIdentityService`'s house style for a simple JSON-API client).
  Planned via `EnterPlanMode`, built, tested (7 new tests, full suite
  131/131), verified live end-to-end including a real Release-build
  check confirming the whole feature compiles out cleanly.

  **Redesigned the results page the same day, raised directly** ("the
  focus is the isp edge router... present the results in tabular form
  for comparison across the remote sources... include dns info about
  multiple interface IPs"). The page's primary view is now a comparison
  table — one row per probe, showing that probe's own ISP-edge
  candidate (the same `lastHopBeforeDestination` extraction the
  corroboration check already used, now factored out and shared) and
  whether it matches the confirmed hop — instead of separate per-probe
  hop-list sections that needed a mental diff to compare. A "known
  addresses near the edge" section cross-references every hop across
  every probe's *own* full path that shares a device stem with an edge
  candidate (`GlobalpingReverseTraceService.deviceStem`, a narrow,
  Sonic-shaped `lo`/`ae`/numeric-prefix stripper — real data, not
  guessed), plus a couple of supplementary `dig` lookups
  (`DebugToolsView.lookUpSiblingAddresses`, reusing
  `DDNSResolutionService`) for a stem's bare name and `lo0.` form
  specifically — the two patterns confirmed live to reliably resolve.
  Full per-probe hop lists kept, just moved into a collapsed `<details>`
  below the comparison table rather than deleted. 4 more tests added
  for `deviceStem` (16 total for this feature now), full suite still
  green.

- [ ] **Path Discovery's corroboration check is exact-address-only, and
  the very first live use already hit the reason that matters: a
  router's loopback interface vs. its physical interface.** Built and
  shipped (see the "Path Discovery" entry below), then immediately
  exercised live: the confirmed ISP edge hop resolved to a `lo0.bng3...`
  hostname (a Sonic BNG's loopback interface — a virtual, link-less
  interface routers commonly use specifically because it's reachable
  regardless of which physical port is up); Path Discovery's own
  Globalping traces from earlier the same night showed `ae0.bng3...`
  (the same BNG's aggregated-Ethernet interface, the one actually
  carrying traffic) as the last hop before reaching the destination.
  Same physical device, two real, different addresses — the exact-match
  corroboration check correctly reported 0/5, which is honest given
  what it can prove, but doesn't mean the confirmed hop is wrong.
  Raised directly, and worth distinguishing from a similar-sounding but
  mechanically different finding earlier the same night: this isn't the
  near-side/far-side-of-one-link issue (a hop's reply address vs. the
  far side of the same physical link) — a loopback isn't one side of a
  link at all, it's a separate virtual interface with no physical link.
  This is squarely the alias-resolution problem already named in the
  Reverse-traceroute entry below (Ally, MIDAR, kapar; CAIDA's Ark
  project) — proving two different addresses belong to the same device,
  not something a plain equality check can do.
  Fixed for now: the tooltip explains the limitation honestly (a low/
  zero count doesn't mean the hop is wrong) rather than reading as a
  warning. Not fixed: the actual corroboration logic still can't detect
  this case. Full alias resolution (cryptographic-strength proof two
  addresses are the same device — IP-ID/timing correlation, Ally/MIDAR/
  kapar) stays a real research-grade follow-up, not a quick win.

  **A real, cheaper, live-confirmed technique found the same night,
  worth building before the full research-grade version**: `dig` forward
  lookups of *guessed sibling hostnames* on the same device stem.
  Starting from one PTR result (`lo0.bng3.snfcca05.sonic.net`), tried
  forward-resolving plausible sibling interfaces on that same
  `bng3.snfcca05` device — confirmed live, not assumed: the bare device
  name with no interface prefix at all resolves to the *identical*
  address as `lo0` (real evidence `lo0` is this device's default/
  identity address in Sonic's own convention, not something
  semantically separate); `ae0.bng3...` with no numeric prefix doesn't
  resolve at all, but `305.ae0.bng3...` and `304.ae0.bng3...` (a
  VLAN/sub-interface-style numeric prefix) both do, to two different
  real addresses — meaning this one device has multiple distinct
  customer-facing sub-interfaces, each independently discoverable via
  forward DNS, with zero live traceroute probes needed to stumble onto
  each one.
  Not full alias resolution (doesn't *prove* the addresses are the same
  physical box the way IP-ID/timing correlation would — still worth
  being honest about that gap), but real, immediately actionable
  circumstantial evidence, cheap (a handful of `dig` calls, no network
  measurement infrastructure), and it just worked on a real device
  tonight. Same interface-naming-convention caveat as before still
  applies for *generalizing* this across other ISPs (Sonic's own
  `lo0`/`ae0`/numeric-prefix scheme won't match another operator's), but
  as a manual, one-ISP-at-a-time investigative technique (not an
  automated cross-ISP parser) it's genuinely useful today, not just a
  future research direction.

- [ ] **Idea: path discovery toward the specific SaaS services NMS
  already monitors, sourced from probes hosted on that provider's own
  network — not just abstract ISP topology.** Raised live (2026-08-04),
  tying the night's whole reverse-traceroute thread back to something
  NMS actually does: `SaaSMonitoringViewModel`/`SaaSStatusService`
  already tracks whether the SaaS a user's work depends on is up —
  this would add "is a slowdown my network's fault, or something in the
  path near that specific provider," using the same reverse-traceroute
  technique but sourced deliberately close to the SaaS provider's own
  infrastructure instead of a random vantage point.
  Confirmed feasible live via Globalping (`api.globalping.io`, see
  `script/diagnostic-exports/reverse-traceroute-home-20260804.md` for
  the full session): `GET /v1/probes` exposes each probe's hosting
  provider (`location.network`), and the measurement API accepts
  `{"network": "<name>"}` as a location filter — real probes exist on
  Amazon.com, Google, Oracle, DigitalOcean, Akamai Connected Cloud,
  HUAWEI CLOUDS, among others, out of ~4800 active probes checked.
  Real caveat, not glossed over: this is "near a major hyperscaler in
  general," not literally the exact facility a specific SaaS's backend
  runs in — a real, live, sourceable *approximation*, not precision.
  Also confirmed the same session: traceroute's per-hop latency numbers
  are noisy for structural reasons (ICMP reply deprioritization,
  ECMP/load-balanced path variance) — any implementation here should
  treat hop *identity*/path convergence as the reliable signal, latency
  numbers as suggestive at best. Not built — no API auth needed at all
  for reasonable usage, which makes this considerably more approachable
  than it might sound.

  **Confirmed direction, once Path Discovery actually shipped (see that
  entry above): reuse it, don't build a second parallel tool.** Raised
  directly — when this gets built, it should use a local web page for
  display (`LocalDiagnosticServer`'s reverse-trace content mode, the
  same mechanism Path Discovery already proved live) and feed its
  results into the same corroboration/context wiring Path Discovery
  already has in Path to Internet, not stand alone. Concretely: this is
  a second `locations` filter mode (`{"network": "<provider>"}` instead
  of `{"magic": "USA"}`) on the *same* `GlobalpingReverseTraceService`
  and the *same* Debug Tools window — plausibly a second button
  ("Path Discovery (near SaaS)…" or a provider picker) rather than new
  server/service infrastructure. The corroboration math itself doesn't
  need to change; it's the same "does the last hop before the
  destination match" check, just against a deliberately SaaS-adjacent
  vantage point instead of a general geographic one.

- [ ] **Idea: a Share button for diagnostic state, with the interesting
  case being "the network is down, save it and offer to resend once
  it's back."** Raised live (2026-08-04): "mac apps often have a
  'share' button... could a user share some application state with
  another user? Perhaps a corporate help desk? A broken network
  interferes with this. could we save the bad state and then offer to
  resend it whenever the network comes back up?"
  Two very different costs bundled in one idea:
  1. **Cheap**: a Share button on the existing export
     (`script/export-diagnostic.sh`'s JSON, or the debug-only
     Diagnostic Log page) via macOS's standard `NSSharingServicePicker`
     — Mail/Messages/AirDrop. AirDrop specifically doesn't need
     internet at all if the recipient is nearby. No new state machine.

     **This already covers the follow-up "send it to my own iPhone,
     which still has cellular" idea raised in the same conversation** —
     AirDrop is one of `NSSharingServicePicker`'s built-in destinations,
     and it transfers over Bluetooth + peer-to-peer Wi-Fi (AWDL), not
     through either device's regular internet-routed connection. It
     doesn't care whether the Mac's ISP link is up, or even whether the
     Mac is associated with any Wi-Fi network at all — just that both
     devices' radios are on. No custom Mac<->iPhone protocol or
     companion app needed; the "remote worker" pattern (get the file
     onto a device with its own working uplink, then forward from
     there) falls out of the plain Share Sheet for free.
  2. **Real work**: "save now, offer to resend once back online" needs
     an actual queue — capture the export at failure time, persist a
     pending-share intent (including *who* it was meant for, captured
     before connectivity was lost), detect restoration (the app already
     watches this continuously via `ConnectivityViewModel`/
     `NetworkMonitorViewModel`), and **re-prompt rather than silently
     auto-send** — a stale export firing off unreviewed once reconnected
     is a real risk, not just a nice-to-have safeguard.
  **Privacy, raised in the same breath and genuinely not minor:** a
  diagnostic export isn't only the user's own data — it can include
  DHCP-leased and SNMP-discovered devices belonging to *other* people on
  the same network. "Help desks have deep visibility" holds for
  corporate IT, but the app has no way to know who's actually on the
  other end of a share. Real precedent already in this codebase for
  exactly this shape of concern: `KnownNetwork.isPublicForCapture`
  gates automated capture behind an explicit per-network opt-in rather
  than defaulting to "capture everything" — a share feature should
  probably follow the same discipline (review/redact before sending,
  never silent, especially for the deferred-resend case).
  Not built — the cheap version (plain Share Sheet on the existing
  export) is a reasonable small first step if this gets picked up; the
  queue-and-resend version needs real design work first, not just
  implementation.

- [ ] **Idea: a private-address traceroute hop appearing mid-path (not
  leading) could be an ISP's own privately-numbered backbone link, not
  NAT/CGNAT — the app doesn't currently explain this possibility
  anywhere.** Raised live (2026-08-04): "in theory, an isp could use
  rfc1918 private ips for their backbone router interfaces. eBGP would
  carry the public customer IPs. The router interface ips are not part
  of the 'service' so it doesn't break the internet... might lead to
  some odd traceroute results." Real, known backbone-design practice
  (sometimes called "unnumbered"/privately-addressed transit links), not
  purely hypothetical — a link's own transport address doesn't need to
  be public for the customer traffic it carries (routed via BGP-learned
  public prefixes) to work. Not confirmed against any specific ISP or
  observed live in any trace so far, per the user's own framing ("i
  don't know if any isp does this").
  Why this matters here specifically: it's a **third, distinct** cause
  of a private-looking hop, different from the two
  `TracerouteViewModel.leadingNonInternetHopCount`'s own doc comment
  already names ("the customer's own second router" or "the ISP's own
  carrier-grade NAT"). It wouldn't even trip that detector — it only
  counts *leading* private hops before the first public one, and an
  unnumbered backbone link would typically appear *after* the first
  public hop instead. But a private RFC1918 address showing up
  mid-path in Path to Internet's raw hop list could still read as
  alarming (looks like a mid-route NAT detour) to someone who doesn't
  know this is normal, benign ISP-internal numbering with zero bearing
  on their own connection.
  Not built — worth considering whether Path to Internet's hop-list
  UI/tooltips should explain this specific pattern (leading private hop
  = NAT signal, worth investigating; mid-path private hop after the
  first public one = probably just internal ISP numbering, not a
  concern) rather than coloring/treating every private hop the same way
  regardless of position.

- [ ] **Add tooltips to Known Networks and Preferences windows.** Raised
  live (2026-08-04). The app-wide tooltip-discoverability push earlier
  this session covered the main popover/window's tiles and buttons, but
  these two separate windows weren't audited as part of that pass. Not
  built — needs its own pass through both windows' controls (rename
  field, home-network button, review/forget buttons in Known Networks;
  every toggle in Preferences) the same way the main window already got.

- [ ] **Idea: visualize the Network tile's rows as a dependency chain —
  and explain the concept itself in the user guide and on the website,
  not just in the app.** Raised live (2026-08-04): "network tile shows
  a dependency graph (?). each layer is dependent on the layers below
  it." Checked what already exists first: the dependency model is
  already real, just not drawn as one — `ConnectionLayer`'s own doc
  comment already describes the exact chain (interface → network →
  local router → ISP edge router → DNS → HTTP, low to high), and
  `rootCauseLayerID` already dims a failure's downstream consequences
  (lighter red) vs. the actual root cause (full red). My read, given
  live: a full node/edge graph is a bigger lift for what a flat list
  mostly already conveys, since the chain is strictly linear, not
  branching — no layer depends on two others in a way the list can't
  express. A cheaper middle ground worth considering instead: a plain
  connecting line down through the row dots (Interface→Network→
  Router→...→HTTP), which gets most of the visual "this depends on
  that" clarity without full graph-layout complexity. Not decided,
  not built.
  Second half of the same message: **the underlying concept (why a
  router failure shows DNS/HTTP as also unhealthy, and how to read
  "full red vs. dimmed red" as root-cause vs. consequence) should be
  explained somewhere a user actually reads it** — the user guide
  (`docs/user-guide.md`) and the NMS-website-v2 site, not just left
  implicit in the app's own coloring. Related to, but distinct from,
  this file's existing "`docs/user-guide.md` (and README.md) need a
  real pass" item further below — that one's about general staleness; this is
  specifically about a concept that may never have been written down
  anywhere at all, in-app or out.

- [ ] **Idea: detect cable modem/ONT failure via the router's own SNMP
  WAN-interface status, as a faster complement to Path to Internet —
  not a replacement.** Raised live (2026-08-04): Path to Internet's real
  diagnostic value is catching classic access-circuit and modem/ONT
  failures. If the router runs SNMP, polling its outbound/WAN
  interface's operational status (standard MIB-II `ifOperStatus`) would
  generally show the same failure faster and more directly — that
  interface drops the moment the modem/ONT stops passing link.
  Real caveat, from the same message, and the reason this can't just
  replace Path to Internet: this only works when the router is directly
  attached to the modem/ONT. **If a switch sits between them, the
  router's own interface stays up** (link to the switch, which is fine)
  even after the modem/ONT itself fails upstream of that switch — so
  SNMP interface status alone would miss exactly that topology, and only
  a real reachability test past that point (what Path to Internet/
  traceroute already does) still catches it.
  Not built. Checked first: nothing in the codebase currently polls
  router SNMP for WAN interface status (`ifOperStatus`/`ifAdminStatus`)
  — confirmed via grep, not assumed. Worth scoping as a second, earlier-
  warning signal alongside Path to Internet where SNMP + simple topology
  make it reliable, not as a replacement for the harder-but-universal
  reachability check.

  **Clarified in a follow-up message, same day:** Path to Internet's
  reachability testing actually covers two distinct "sides," and SNMP
  can only ever stand in for one of them. The **local router's own
  outbound/WAN interface** (near-side) is something this Mac could
  plausibly poll directly via SNMP, per the caveat above — it's the
  user's own device. The **ISP's PE router** (far-side, the confirmed/
  suggested hop in Path to Internet) is never SNMP-pollable — it's the
  ISP's equipment, not reachable or authorized for that kind of query —
  so reachability testing (ping/traceroute) is the *only* tool that
  works there, not just the more-general one. Any future SNMP-based
  near-side signal would be strictly additive to the local-router half
  of what Path to Internet already covers, never a substitute for the
  PE-router half.

- [ ] **A manual way to switch to a scratch datastore and back, for
  poking around live during testing without touching the real store.**
  Raised live (2026-08-04): "do we need dedicated datastores for
  testing? then we can test with a fresh or archive network state and
  then restore the real datastore afterwards."
  Checked what already exists before assuming a gap: this is already
  fully built, just script-only. `NMSApp.storeURL()`
  ([NMSApp.swift:681](../NMS/NMSApp.swift:681), `#if DEBUG`) reads a
  `NMSStorePath` UserDefaults override before falling back to the real
  on-disk store; `script/scenarios.sh` already does exactly this
  workflow — copies the real store to a scratch path, points the app at
  the copy via `defaults write Thistle.NMS.plist NMSStorePath <path>`,
  runs its assertions against the copy, then clears the override and
  relaunches against the real store, leaving nothing behind.
  The real gap: no interactive way to do this by hand mid-session — only
  as a scripted, assertion-driven run. Not built: a small debug-menu
  affordance wrapping the same `NMSStorePath` mechanism (e.g. "Use
  Scratch Store…" to pick fresh-vs-copy-of-real, and "Restore Real
  Store" to clear the override and relaunch) rather than a new datastore
  concept.

- [ ] **Reverse-traceroute / router alias-resolution idea — needs the
  user's own account, not built tonight.** Raised live during the
  Martha's Coffee session (2026-08-04), while investigating whether the
  first public traceroute hop (found to be the ISP PE candidate — see
  `script/diagnostic-exports/field-test-notes-20260804-marthas-coffee.md`
  for the full reasoning) shows a "near-side" address rather than
  confirming anything about its far side.
  A **reverse traceroute** — run from a remote vantage point back toward
  this Mac's own public IP, rather than outbound from here — would
  directly show the return-direction path traceroute alone can't
  capture, and would be a legitimate unicast target (the public IP,
  unlike `1.1.1.1`, isn't anycast). Tried live: a public looking glass
  (`lg.he.net`) was in progress when the ask shifted to RIPE Atlas
  specifically; confirmed via RIPE Atlas's own docs that creating any
  on-demand measurement — even a single one-off traceroute — requires a
  logged-in account with a credit balance, so it couldn't be completed
  anonymously in this session.
  Bigger idea raised in the same thread: seeing *all* interfaces of a
  single ISP router (not just whichever one answered one probe) is a
  real, named technique — **alias resolution** (Ally, MIDAR, kapar;
  used by CAIDA's Ark project) — correlating addresses observed from
  many diverse vantage points to prove they're the same physical device.
  Real research-grade technique, not a quick win.
  Not built — needs either the user's own RIPE Atlas account/API key
  handed to a session, or falling back to a no-login public looking
  glass (`lg.he.net` or similar from `traceroute.org`'s directory) for a
  less rigorous single-vantage-point version.

  **Follow-up the same day, once home:** account created (free "RIPE
  NCC Access" signup, confirmed live — not the LIR Portal, which is a
  separate, unrelated membership/allocation system easy to land on by
  mistake). Attempted a real one-off traceroute toward the home
  network's public IP (`192.184.170.5`, RDAP-confirmed Sonic.net, LLC)
  from 5 US probes — blocked: **new accounts start at 0 credits, and
  RIPE Atlas has no way to buy credits with money at all.** Credits are
  earned only by hosting a probe/anchor, sponsoring, RIPE NCC
  membership, or a transfer — confirmed directly from RIPE's own credit
  docs, not assumed.
  If this gets revisited: the realistic path for an individual is
  RIPE's free software probe (a Docker container, ~15 credits/minute
  while connected) — but **not a quick unblock**: accounts are only
  credited once per day per RIPE's own docs (so even starting a probe
  immediately wouldn't unlock a 3000-credit measurement same-day), and
  registration requires generating a probe key then waiting for RIPE
  NCC to manually process it before the probe even starts counting as
  connected. Worth doing on its own schedule if ongoing RIPE Atlas
  access matters, not worth spinning up just to unblock one curiosity
  traceroute. For tonight, left as: HE's looking-glass attempt (see
  above) is the best answer available, itself inconclusive rather than
  negative.

  **Update, later the same day, once home**: retried HE's looking glass
  against the home (Sonic.net) network — this time it worked, run
  manually in Safari rather than via browser automation (which kept
  losing form state this session; the manual route was simply more
  reliable). Reached the actual destination end-to-end this time,
  unlike the inconclusive Comcast attempt. Full trace, hop-by-hop
  reading, a real unresolved public-IP discrepancy (Terminal's `curl`
  and Safari's HE session reported two different, both RDAP-confirmed,
  Sonic addresses), and a genuine latency anomaly at one hop (likely a
  traceroute artifact, not confirmed either way) are all in
  `script/diagnostic-exports/reverse-traceroute-home-20260804.md`.

  **Idea from the same result, then actually done, same day**: run the
  same reverse-trace from *several* different vantage points toward the
  same target — the last few hops before the destination should
  converge regardless of starting point, since every path funnels
  through the same last-mile infrastructure to reach one specific home
  connection. Tried for real via **Globalping** (`api.globalping.io`)
  instead of RIPE Atlas — **works fully anonymously, no account, no
  token, no credits at all** (a plain unauthenticated POST to
  `/v1/measurements` just worked, confirmed live). Ran a traceroute
  toward the home public IP from 3 simultaneous vantage points (Buffalo
  NY, Los Angeles CA, Houston TX, auto-picked by `{"locations":
  [{"magic": "USA"}]}`) — all three, via completely different transit
  routes, converged on the identical last four hops into Sonic's
  network, real alias-resolution-style evidence with zero setup cost.
  Also confirmed the latency anomaly from the HE trace above is real
  (same hop, inflated in all three independently-routed traces) and
  solved the public-IP discrepancy (the resolved hostname says
  `...dynamic.sonic.net` — the address genuinely changes). Full
  writeup in `script/diagnostic-exports/reverse-traceroute-home-20260804.md`.
  **This effectively resolves the core capability gap this whole item
  was chasing** — Globalping is a meaningfully better tool for
  reverse-traceroute/multi-vantage-point work than RIPE Atlas turned
  out to be, for anyone without existing RIPE Atlas credits. The RIPE
  Atlas credit-earning threads above (software probe, cloud hosting)
  are no longer urgent given this, just left in place as background in
  case RIPE Atlas's specific probe network (denser/different from
  Globalping's) is ever needed for something else.

  **Refinement, same day:** run the software probe on a free always-on
  cloud host instead of the Mac — "could be any free cloud host," not
  AWS specifically. Real advantage: credits accrue proportional to
  *connected* time, and a personal Mac that sleeps or changes networks
  has gaps that directly interrupt accrual, unlike a cloud VM. RIPE's
  probe needs almost nothing (1 CPU core, 20MB RAM, 100MB disk, Docker)
  — any free-tier VM from any provider (AWS, GCP, Oracle Cloud's
  permanently-free tier, Azure, etc.) comfortably covers it, and native
  Linux Docker on a real Linux host is simpler than Docker Desktop's
  virtualization layer on macOS. Does **not** fix the actual bottleneck
  though: RIPE's once-daily credit batching and manual probe-
  registration processing are RIPE-side, unaffected by where the probe
  runs. Also worth remembering if this gets built: the cloud-hosted
  probe becomes a vantage point in that provider's own datacenter
  network, not "near home" — it's purely a credit-generating asset, not
  itself useful for the home-network reverse-trace question. AWS
  specifically checked live (2026-08-04): free-tier terms depend on
  account age (AWS changed the program July 2025) — legacy accounts get
  750 hrs/month of a t2/t3.micro free for 12 months from account
  creation (enough for 24/7); newer accounts get a $100-200 credit pool
  instead, valid 6 months. Whichever provider gets picked, check that
  account's actual current free-tier terms before assuming, not this
  note.

- [ ] **Field-test session notes — Martha's Coffee, Church St, 2026-08-04.**
  Raised live, mid-session, to act on later rather than interrupt testing.

  1. **DDNS tile reads as wrong/stale while away from home — not a caching
     bug, a framing gap.** Confirmed via `DDNSViewModel.swift`: DDNS
     checking is deliberately *not* scoped to `currentNetworkFingerprint`
     (unlike DHCP/NetworkQuality/Traceroute/WiFiStressTest/SNMP, which all
     already reset cleanly on a topology change via
     `NetworkIdentityViewModel.reset()` nilling the fingerprint before
     re-recognition — so "clear all network displays until confirmed" is
     largely already true app-wide for anything fingerprint-scoped). DDNS
     is intentionally global: the whole point is catching a home DDNS
     client silently failing, checked from *anywhere*, including away from
     home — see the view model's own doc comment. So it keeps resolving
     and comparing the configured home hostname against whatever network
     you're currently on, which will read `.stale` on every non-home
     network by design, not just this one.
     Real gap: nothing in the UI signals "this is checking a specific
     hostname regardless of your current network" vs. every other tile's
     implicit "this is about your current network" convention — so a
     `.stale` reading away from home looks like a bug rather than the
     expected always-checking-home behavior. Possible fix direction (not
     built): either a persistent label on the DDNS section clarifying
     it tracks configured hostname(s) independent of current network, or
     suppressing the stale event-log entry (not the display) specifically
     when the current network doesn't match whichever `KnownNetwork` the
     user has labeled as home — no such "this one is home" designation
     exists yet, would need adding to `KnownNetwork` or inferring from a
     label match.

  2. **Network Summary tile — one-glance "is this network basically
     working" view, aimed at Concise mode.** Requested live: basic
     connection state, SSID, and any specific problems already detected
     elsewhere in the app, rolled up into one line/tile answering "is the
     network basically connected and functional?" without requiring a
     scan across every other tile. Open question raised in the same
     breath: should it fold in a one-line SaaS-monitoring rollup too (with
     full per-service detail staying in the existing `SaaSStatusTile`,
     this tile only surfacing something like "2 services degraded"), or
     leave SaaS out of the summary entirely since it's a different concern
     (third-party service health vs. this network's own connectivity)?
     Also requested live: a basic Wi-Fi quality indicator in the same
     rollup (e.g. reusing `WiFiTile`'s existing signal/PHY-rate reads
     reduced to one good/fair/poor-style badge, not the full tile's
     detail) — same "roll up, don't duplicate" shape as the SaaS
     question above, same open question of whether it belongs in this
     tile at all vs. staying in `WiFiTile` alone.
     Not built — needs scoping (which existing view models it reads from,
     what counts as a "problem" worth surfacing here vs. staying buried in
     its own tile, whether it's Concise-mode-only or shown always).

- [ ] **Brief in-tile explanatory text for each test feature — "I keep
  forgetting how each test works."** Raised directly. Checked what
  already exists before assuming a gap: three of the four dedicated
  test tiles already carry a short, always-visible caption (10pt,
  secondary color) — Speed Test ("up to ~50MB per run"), Apple
  networkQuality (two lines: the real data-plan cost, plus "Higher RPM
  means a more responsive connection under load" explaining the
  metric's own convention), and Local Stress Test ("many concurrent
  MTU-sized pings, ~1-2s, real traffic"). Every explanation beyond that
  currently lives only in `.accessibilityHint(...)` — screen-reader-only,
  invisible to a sighted user, which is probably the real gap behind
  "I keep forgetting": the fuller explanation exists in the code, just
  not on screen.
  Two real gaps found:
  1. **Path to Internet has no inline caption at all** (`ContentView
     +Window.swift`'s `tracerouteSection`) — jumps straight to status/
     hop rows with nothing explaining what "Trace Now" does or why
     confirming a hop with the star matters.
  2. **The `networkQuality` quick-check row (top of the merged Network
     tile) has no room for one** — unlike the other three, it's one row
     inside a dense, multi-row tile, not its own tile with header space
     to spare. Adding a caption there costs real vertical budget inside
     `ContentView.tileHeight`'s fixed height, the same tension that
     originally motivated splitting Apple networkQuality into its own
     tile in the first place (see that tile's own doc comment: "easy to
     miss as a small, secondary button buried inside Speed Test's
     tile"). A tooltip (`.help(...)`, hover-visible unlike
     `accessibilityHint`) might be the better fit for this one
     specifically rather than fighting for inline space.
  Not built — worth deciding whether the fix is "add captions to the
  two gaps and call it consistent" or "audit whether the three existing
  captions are actually good enough" (they currently explain cost/
  duration more than *purpose* — e.g. Speed Test's caption says nothing
  about what a bufferbloat/RPM reading is *for* versus raw throughput).

- [ ] **`docs/user-guide.md` (and README.md) need a real pass covering
  two confirmed staleness layers — a text rewrite and an annotated
  screenshot, grouped here since both keep re-deriving the same
  diagnosis independently.** Started live once already, then explicitly
  cancelled to be tracked here instead.

  **Why it's stale, confirmed directly, not assumed — and why a rewrite
  that already happened didn't fix it.** `docs/user-guide.md` got a real
  rewrite in `0fd18fe` (Aug 2), but that commit predates the
  single-window rebuild (`4e4e83a`, Aug 3) by about a day — it was
  accurate when written and immediately re-invalidated by the very next
  architectural change. Re-confirmed live just now, not trusted from the
  commit message alone: `grep`ing `NMS/NMSApp.swift`'s actual `Scene`
  body shows three plain `Window` scenes (`"NMS"`/main,
  `"Known Networks"`, `"Preferences"`) and zero `MenuBarExtra` anywhere
  in the app — yet `docs/user-guide.md` still opens with "A menu bar
  utility," still has a `## 2. The menu bar icon` section describing a
  green/yellow/red glance-without-opening status the app has in no form
  today (not even a Dock badge), and still frames `## 3. Anatomy of the
  popover` / `## 4. Expert Mode` as two separate surfaces instead of the
  one window that actually exists. **A second, independent staleness
  layer, also still present in both docs** (re-confirmed live:
  `docs/user-guide.md` and `README.md` both still have separate
  `### Network Health` and `### Info` headings): both predate the
  Network Health/Info merge into one "Network" tile (this file's own
  archived "Network Health and Info tiles" entry). Sections 3/4's actual
  *content* (Path to Internet, Speed Test, Wi-Fi, Ethernet, SaaS Status,
  Events, SNMP Devices, DHCP History) is otherwise accurate and worth
  keeping — this needs restructuring around what's real today, not a
  content rewrite from scratch.

  **Directly relevant context for how to write it, not just what to
  fix**: current plan is to focus development on the single app window
  itself to speed up building out the network tooling, and only once
  that matures, consider a separate simplified UI for non-technical
  users. So the rewrite should describe the current single-window app
  plainly, as the real current shape, not hedge it as temporary or
  gesture at a future popover/simple-mode — that's a later, separate
  decision, not part of documenting what exists today. **The "document
  the lost at-a-glance status as gone, or rebuild it" question has a
  real answer from a later conversation**: rebuild, eventually, as part
  of that same future simplified UI, organized around a single
  mission-control-style word rather than the old green/yellow/red
  dot-only glance (see the "Nominal" status-language trial already
  shipped on the DHCP row, and the tagline material in issue #7) — still
  not built, still gated on the technical-focus phase finishing first,
  but worth knowing the eventual shape isn't a blank slate so this
  rewrite shouldn't describe the current gap as permanent.

  Two deliverables against that same diagnosis, not one:

  1. **The structural text rewrite** — merge sections 3/4 into one
     description of the single window, fix the "menu bar utility"
     framing, and fold Network Health/Info into the one real "Network"
     section, across both `docs/user-guide.md` and `README.md`.

  2. **An annotated screenshot** — a real screenshot with callout
     boxes/arrows pointing at each element (tiles, footer buttons) and a
     short label on what it does, alongside the prose rather than
     replacing it. Mechanically: a real PNG (`screencapture`, or the
     app's own Screenshot button once it's confirmed to reflect live
     layout — see `BUGS.md`'s "the capture path never actually exercises
     the `NSHostingView`/`NSScrollView` layout" finding on that button's
     own limits) with callout boxes/labels composited on top, saved
     under `docs/images/`. **Mirror the callout labels from the app's
     own tooltips, not a parallel set of captions** — a lot of controls
     already carry `.help(...)`/accessibility-hint text (the
     reachability dot's tooltip, `rpmThresholdHelp`, every external-link
     icon's accessibility hint, and more), so a callout's label should be
     sourced from — or kept word-for-word consistent with — the same
     string already live in the Swift code, rather than hand-written doc
     prose that can quietly drift from what the real UI says. What
     doesn't mirror automatically is layout — matching a label to
     *where* its element actually sits on a real screenshot stays a
     manual/visual step regardless. Do this one *after* the text rewrite
     lands, so the screenshot isn't stale before it's even committed.


- [ ] **SNMP community strings, the Local Stress Test's confirmation,
  and LAN Discovery's sweep all touch other devices on whatever
  network the Mac is on — protection against an unfamiliar/office
  network is inconsistent across the three, not yet fixed.** Raised
  directly, with a real safety angle: "could this protect office
  networks from the stress test features," then "any others?" Audited
  every active-probing feature against the passive/read-only ones
  (Path to Internet, Network Health, SaaS Status — none of these touch
  anyone else's gear beyond normal, expected ping/traceroute/HTTPS
  traffic) and found three with real gaps, each different:
  1. **SNMP community strings are global, not per-network.**
     `SNMPViewModel.communities` persists under one `UserDefaults` key
     (`NMS.snmpCommunities`), so a string set for one network's gear
     (or left on the "public" default) gets tried against *every*
     other network's SNMP devices too, not just the one it was
     actually confirmed correct for. The feature itself *is* already
     off by default (`FeatureFlags.snmpDevices`, opt-in) — this gap is
     about the community string, not whether scanning happens at all.
  2. **The Local Stress Test's confirmation is global, not
     per-network, and the feature has no flag at all.** `WiFiStressTestViewModel
     .hasConfirmedBefore`/`markConfirmed()` read/write one global
     `UserDefaults` bool — once dismissed on a home network, the
     one-time alert never appears again on any other network the Mac
     joins, including an office network where firing concurrent
     MTU-sized ping bursts at someone else's router without a fresh,
     explicit yes is a real problem. Unlike SNMP, this feature has *no*
     `FeatureFlags` gate at all — the confirmation alert is the only
     protection it has, and it's the weaker, global-not-per-network
     kind.
  3. **LAN Discovery's subnet sweep has no gate of any kind.**
     `LANDiscoveryViewModel.scan()` — an ARP-based active sweep that
     feeds SNMP candidate addresses and MAC-merge data — runs
     unconditionally, confirmed by reading the whole file: no
     `FeatureFlags` check, no confirmation, not even gated behind
     `FeatureFlags.snmpDevices` despite mainly existing to feed it.
     Runs on every network regardless of familiarity.
  This is the same *class* of bug already found and fixed once in this
  project's history: `TracerouteViewModel.monitoredHopNumber` had the
  identical "single global `UserDefaults` value, no per-network
  scoping" shape, confirmed live to carry a stale confirmation over
  between networks (see `BUGS.md`'s "Confirmed ISP Edge Router hop
  isn't scoped per network" entry) — worth checking whether any other
  `UserDefaults`-backed setting in this app has the same gap rather
  than fixing just these in isolation.
  Recommended fix shape, not yet built: key by
  `currentNetworkFingerprint` the same way `KnownNetwork`/per-network
  history tables already do — re-prompting the stress test's
  confirmation on a network it's never seen, letting SNMP communities
  be tried/remembered per network rather than globally, and giving LAN
  Discovery's sweep a real gate (its own, or folded into
  `FeatureFlags.snmpDevices` since that's most of what it's for)
  rather than none. A per-network "confirmed/known" fix is the right
  lever for all three — it makes every one of them effectively
  restricted by default on any network the Mac hasn't explicitly said
  yes to, without needing a separate always-off toggle on top. Real
  design question first: does "confirmed on this network" need its own
  dictionary-shaped default (`[fingerprint: Bool]`), or does it belong
  in a real per-network SwiftData row instead, matching how most other
  per-network state in this app already persists.

- [ ] **Expose NMS's checks to Siri/Apple Intelligence via App Intents.**
  Raised directly, sketched out, not yet built. Checked the real
  constraint first: NMS already targets macOS 15.7
  (`MACOSX_DEPLOYMENT_TARGET`), which covers Apple Intelligence's Siri
  App Intents requirement (macOS 15.1+) — no deployment-target blocker.
  "Teaching" Apple Intelligence itself isn't a thing a third-party app
  can do (its model is closed, not fine-tunable) — this is App Intents
  integration instead: define a handful of narrow, structured actions
  Siri can route natural-language phrases to, each backed by code that
  already exists.

  Proposed intents, each a thin wrapper: `CheckNetworkHealthIntent`
  (`ConnectivityViewModel.checks`), `RunNetworkQualityIntent`
  (`NetworkQualityViewModel.runQuickCheck`), `GetPublicIPIntent`
  (`PublicIPViewModel.currentIP`/`ISPIdentityViewModel`),
  `CheckDDNSIntent` (`DDNSViewModel.statuses`), `GetDHCPLeaseIntent`
  (`DHCPLeaseViewModel.history.first`).

  **The real architectural question**: `AppIntent.perform()` is a
  struct method the system calls, with no natural handle on the
  already-running `@MainActor` view models `NMSApp.wireDependencies`
  wires up. Needs a small `@MainActor` singleton (e.g.
  `NMSIntentBridge.shared`) that `NMSApp` populates with weak
  references to those view models, so intents read *live* state
  instead of spinning up a second, parallel set of pings/subprocess
  calls per Siri request.

  **A real gap to close first**: `NetworkQualityViewModel.runQuickCheck`
  is fire-and-forget today, publishing its result via `@Published`
  rather than returning it — an intent needs an awaitable
  `async throws -> Int` variant to give Siri a real answer instead of
  "started, check back later." Also needs an `AppShortcutsProvider`
  with 2-3 concrete invocation phrases per intent ("check my network,"
  "how's my Wi-Fi") drafted deliberately, not guessed, for Siri to
  route reliably.

- [ ] **Network Health: expand the sparklines to use the extra space
  freed by the single-window rebuild, and align them with the icon
  column.** `Sparkline.swift` draws at a fixed `44×11pt` — its own doc
  comment explains why: sized to add no vertical height in a popover
  row, "the one sparkline use where a taller drawing would still cost
  real popover budget." That constraint is gone now that NMS is a
  resizable window, not a fixed-height popover (see the rebuild in
  `PUNCHLIST.md`'s own history) — the doc comment is stale and the
  sizing is now an arbitrary leftover, not a real constraint. Widening
  (and possibly heightening) it is free real estate now. Separately,
  `connectionHealthSection`'s `Grid` (`ContentView.swift`) puts the
  external-link icon and the sparkline in two different columns, each
  independently `Color.clear`-padded on rows that don't use them —
  worth checking whether that's actually producing consistent
  horizontal alignment between the icon and sparkline across rows once
  the sparkline's width changes, since the two columns aren't sized
  from a shared reference today.

- [ ] **Fold the Ethernet Speed/Duplex tile into the merged Network
  tile's own Network row, instead of its own separate section.**
  Reference updated after the Network Health/Info merge above — the
  target is now `connectionLayersLowToHigh`'s `networkLayer` (the
  "Network" row inside `ContentView.connectionHealthSection`), not
  `infoContent`/`infoSection`, which no longer exist. Still open,
  reasoning unchanged: `ContentView+Window.swift`'s `ethernetLinkSection`
  is its own small window-only box (`scrollBox(.ethernetLink)`, two
  rows: Speed, Duplex) rendered separately, mutually exclusive with
  `wifiSection` the same way. Move Speed/Duplex to live with the
  Network row instead, the way the Wi-Fi tile's Signal/Channel/PHY Rate
  already sit apart from that row today (BSSID especially) — worth
  deciding during implementation whether that same precedent argues for
  leaving Ethernet's own detail where it is instead of moving it, since
  this request cuts the other way from that existing split.

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

  **A third use case, raised directly: reviewing field-test diagnostic
  output is easier as a generated local web page than as new SwiftUI
  added to the shipped app.** Lower-stakes than the two above, worth
  being precise about the difference: Apple networkQuality formatting
  and the Mermaid diagram privacy fix are real, shipped end-user
  features; this is dev/testing tooling, the same category as
  `FailureInjector`/`UIStateLogger` — worth scoping as debug-only rather
  than assuming it needs the same bar as a shipped feature. Same
  loopback-only/no-dependencies/on-demand constraints still apply
  regardless of which tier it ships in.

  **Scope, refined directly to something leaner than a data/screenshot
  dashboard: a simple chronological log of test activity and
  results** — what ran, when, what it found — rather than a richer
  side-by-side viewer. Closer to a plain HTML rendering of
  `script/export-diagnostic.sh`'s own output plus each field-test
  screenshot (see the "Run Field Test" button item elsewhere in this
  file) inserted at the point it was taken, than a dashboard with its
  own separate layout/navigation to design and maintain. A real, much
  smaller first version to build than the dashboard framing implied.

  **Recommended build order, raised directly: start here, not with
  either shipped-feature use case above.** This is the simplest of the
  three (no Mermaid-JS-bundling, no parsing Apple's verbose report
  format) and has standalone value from its first real use — the next
  field-testing trip — rather than needing repeated use to justify the
  work. Proves the actual server plumbing (`NWListener`, loopback-only,
  on-demand lifecycle) end-to-end on a low-stakes debug-only target
  before the other two use cases build more complex content generators
  on top of the same mechanism. One thing this *doesn't* deliver as a
  side effect, worth being precise about: the separate "UI experiment
  mockup harness" idea elsewhere in this file wants CSS that visually
  matches the real app (native fonts, colors, tile borders) — a log
  page doesn't need or benefit from that same styling, so building this
  first proves the server mechanism but not that harness's own
  app-matching mockup CSS, which would still be its own follow-on step.

  **The recommended first step above is now built** — `LocalDiagnosticServer.swift`,
  a debug-only "Diagnostic Log…" footer button opening a local,
  loopback-only, ephemeral-port, token-gated page listing recent Events,
  color-coded to match `EventsTile`'s own polarity logic. Verified live:
  built, tests pass (119/119), clicked through the real button, real
  page loaded in the browser. The server plumbing (`NWListener`,
  on-demand lifecycle, no third-party dependency) is proven working —
  the other two use cases (Apple networkQuality formatting, the Mermaid
  diagram privacy fix) can build their own content generators on this
  same mechanism whenever they're taken up. The UI-experiment mockup
  harness's own app-matching CSS is still a separate, not-yet-built
  follow-on, per the note directly above.

- [ ] **TCP/UDP stress-test ideas for testing further out than the
  local hop** — separate from the local Wi-Fi ping stress test above
  (now built), and less developed. TCP/UDP echo (RFC 862/863) is
  confirmed dead on modern equipment — raised directly ("I think that
  idea is no longer supported"), matches this app's own existing
  HTTP-based approach elsewhere. What actually works instead:
  - **TCP**: no echo needed — open a real connection to something
    guaranteed to answer and push/pull a bulk transfer, timed. This is
    exactly `NetworkQualityService`'s existing probe/full-transfer
    shape, just pointed at a LAN target rather than Cloudflare's
    endpoint.

    **Not the router's own admin HTTPS port** — the original idea here,
    reconsidered after the local ping stress test above shipped and
    revealed a real router-control-plane-overload risk (a consumer
    router's management CPU choking under sustained load, not just its
    switching fabric — see that entry's own notes on this). A router's
    embedded web UI is served by that same fragile management CPU, and
    HTTP(S) is *more* expensive per-request than ICMP echo to begin
    with — TLS handshake overhead, request parsing, often a dynamically
    generated status page — so hammering it with a bulk transfer would
    stress exactly the fragile path already flagged as risky, likely
    harder than ping does. Target some other device on the LAN instead
    (a NAS, a Mac, anything that isn't the router's own management
    plane) if this gets built — confirmed reachable the same way via
    `DeviceWebDetectionService`, just not the router itself.
  - **UDP**: trivial to send, but proves only "can send," not
    "arrived" — no built-in delivery confirmation, so measuring loss
    needs a cooperating receiver. Nothing on a stock router does this;
    the external firewall/ACL checker idea further down is the one
    already-sketched mechanism that could, repurposed for load/loss
    measurement instead of port-reachability.

  **Still not decided**: whether the TCP/UDP half ships standalone or
  waits on the external-checker project (for UDP's receive-side
  requirement specifically) — a scoping question raised and not yet
  answered.

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

- [ ] **SaaS monitoring: three remaining candidates, each blocked on
  its own scoping decision, not a drop-in the existing curated-list
  entries were.** Grouped here since they share the same shape (a
  real service worth monitoring, but needing a decision before it can
  be added the way GitHub/Cloudflare/Figma/etc. were) rather than
  three separate open items.

  - **Add AWS to SaaS monitoring — needs a scoping decision first.**
    `https://status.aws.amazon.com/rss/<service>-<region>.rss` (RSS,
    re-confirmed live, `ec2-us-east-1` tested) is real but per-service-
    per-region, not one aggregate feed the way Google Cloud/Workspace are
    — there's no single "AWS" entry to add without first deciding which
    service/region slugs actually matter (e.g. just this house's actual
    AWS usage, or a fixed starter set like EC2 us-east-1). Also a new
    `Shape` case needed (RSS/XML parsing, unlike every existing entry).

  - **Microsoft 365 needs a decision before it can be added at all.**
    No public, unauthenticated endpoint exists — `DESIGN-NOTES.md` already
    confirmed `401` on the real API (Microsoft Graph Service
    Communications) without an OAuth app registration. Options, same
    three as Workday/ADP's existing gap: skip it, fall back to a plain
    reachability check against a Microsoft 365 domain (weaker signal,
    same shape as the Workday/ADP fallback already designed), or treat it
    as the first candidate for the separate tenant-auth project in
    `DESIGN-NOTES.md`. No pull toward one yet.

  - **iCloud needs a scoping decision too — it isn't one service.**
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

- [ ] **Run `/code-review ultra` on the branch.** User-triggered and
  billed, so it can't be launched from a session. Worth it: a manual pass
  over just the concurrency and event handling found a shipped crash and
  a main-thread stall, so a multi-agent pass over the whole branch would
  likely surface more.

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

- [ ] **Wi-Fi site survey mode.** User names a set of locations (rooms
  in a home, floors in an office), then walks between them tapping
  "record here" in NMS at each stop. Each tap grabs a WiFi snapshot —
  RSSI, noise, channel/band, PHY/link rate, same CoreWLAN data the app
  likely already samples — and stamps it against that named location
  and timestamp. Display as a location list with the existing
  dot-history sparkline pattern (the same one built for networkQuality)
  per room, so repeat walkthroughs show whether a spot's signal is
  trending better or worse over time.

  Deliberately scoping to **manual** location tagging for v1 — user
  taps "next room," no indoor positioning. Automatic location detection
  via BSSID/RSSI fingerprinting is a real technique but a lot of extra
  surface area for a first cut; treat it as a stretch goal only if
  manual tagging proves too tedious in practice. Similarly skip a
  floor-plan heatmap view for now — a sorted list of rooms already
  answers "which room has the worst Wi-Fi," and a heatmap needs a floor
  plan image/coordinate input that's its own separate feature.

- [ ] **Write `PORTING.md`: map every Apple-specific dependency to its
  purpose and a plausible Windows equivalent**, so a future contributor
  (human or AI-assisted) porting NMS to Windows isn't reverse-engineering
  platform intent out of Swift syntax line-by-line. At minimum needs an
  entry for each of: `CoreWLAN`/`CWWiFiClient` (Wi-Fi RSSI/noise/channel
  data), `SwiftData` (local persistence), `MenuBarExtra`/the single-window
  app shape (Windows system-tray equivalent), Apple's `networkQuality` CLI
  for the bufferbloat/responsiveness test (no direct Windows equivalent —
  needs its own solution), and `ASWebAuthenticationSession`/Keychain
  (Windows OAuth flow + Credential Manager). The actual SwiftUI view code
  isn't portable regardless of who wrote it and would be a rewrite either
  way — this doc is about the *behavior* to preserve, not the Swift itself.

  Requires actually grepping the NMS codebase for every platform-specific
  API in use — not yet started, this entry just captures the idea and the
  known dependency list from a conversation about Windows-port readiness.

- [ ] **Automate the privacy/security review as a per-release step.**
  `docs/reviews/2026-08-03-privacy-security-review.md` is a first,
  manually-run pass checking the app's "no account, no cloud, no
  telemetry" claims against the actual source (dependencies, network
  endpoints, shell-out safety, sandbox status, stress-test scoping).
  If this becomes a standing part of the release process, it should be
  a script that re-runs the same greps against each tagged release's
  commit and flags drift from the previous review, rather than a fresh
  manual pass every time — and the resulting file should note plainly
  that it's a reproducible methodology check, not a "certification"
  (no one, including an AI, can cryptographically prove a review
  document wasn't edited after being generated — the trust comes from
  a reader being able to rerun the exact commands themselves, not from
  who's credited as having written it).

- [ ] **Field-testing session (2026-08-03): a batch of ideas raised
  during real field use, not yet built.** Recorded here together since
  they came out of one session; each is independent.

  1. **ISP short names.** The Network tile shows the RDAP-identified
     organization's full legal name ("Sonic.net, LLC") — raised
     directly as too formal for a glance-at-a-tile display. Wants a
     1-2 word display form ("Sonic") instead. Needs a mapping (curated
     list of known ISPs to short names, falling back to the full name
     for anything unrecognized) — probably lives near
     `ISPIdentityService`/`ISPIdentityViewModel`.

     **A cheaper alternative, raised directly: just take the first word
     of the RDAP name, no curated table at all.** Works cleanly on a
     real fraction of cases seen this session — "Comcast Cable
     Communications, LLC" → "Comcast", "Sonic.net, LLC" → "Sonic.net"
     (close enough), "RCN Corporation" → "RCN". Breaks on others
     already documented elsewhere in this file: "Time Warner Cable"
     (part of the Charter/Astound history in the short-name/brand
     mapping item below) would give "Time," and bare "RCN" vs. "RCN
     Corporation" vs. "Astound Broadband LLC" — the same real entity,
     per that item's own findings — would show three different short
     names for one brand instead of converging on one. A first-word
     heuristic is a real, much cheaper starting point for the *display*
     problem specifically, but doesn't help the *comparison* problem the
     fuller mapping item below also solves (recognizing two legal names
     as the same brand when walking RDAP org changes) — worth building
     as a fallback under a small curated table rather than a full
     replacement for it, so the common short/clean cases (the majority,
     going by this session's own real ISP names) need no table entry at
     all, and only the genuinely messy ones (Time Warner, the
     Astound/RCN family) need curating.

     **Checked against the top ~20 US ISPs by subscriber count, not just
     the two data points above — roughly half work cleanly, and the
     failures cluster in one recognizable pattern rather than being
     random noise.** Confidence varies per row: Comcast and the
     Astound/RCN family are this project's own live-verified RDAP
     findings; Verizon's is web-sourced (below); the rest are inferred
     from each company's known public/legal corporate name, not
     RDAP-queried live — worth a real `rdap.org` check per ISP before
     trusting this table the way the rest of this file's findings are
     trusted.

     | ISP | Legal/RDAP org name | First word | Works? |
     |---|---|---|---|
     | Comcast | "Comcast Cable Communications, LLC" (verified live) | Comcast | yes |
     | Charter/Spectrum | "Charter Communications, Inc." | Charter | yes |
     | AT&T | "AT&T Services, Inc." | AT&T | yes |
     | **Verizon** | **"MCI Communications Services, Inc. d/b/a Verizon Business"** — legacy UUNET/MCI naming still live on AS701 ([source](https://whoisrequest.com/ip/AS701)) | **MCI** | **no** |
     | T-Mobile | "T-Mobile USA, Inc." | T-Mobile | yes |
     | Cox | "Cox Communications, Inc." | Cox | yes |
     | Lumen/Quantum Fiber | legacy "CenturyLink..."/"Qwest Communications..." blocks | CenturyLink / Qwest | mixed — outdated brand |
     | Altice/Optimum | legacy "Cablevision Systems Corp." vs. "Altice USA" | Cablevision / Altice | mixed — outdated brand |
     | Frontier | "Frontier Communications Corporation" (merging into Verizon as of Jan 2026) | Frontier | yes, but transitional |
     | Windstream | "Windstream Communications, LLC" | Windstream | yes |
     | Mediacom | "Mediacom Communications Corporation" | Mediacom | yes |
     | **Cable One**/Sparklight | "Cable One, Inc." | **Cable** | **no — meaningless alone** |
     | **Astound**/RCN/Grande/Wave | **"Astound Broadband LLC" / "RCN Corporation" / "RCN"** (verified live) | Astound / RCN / RCN | **no — 3 results, 1 brand** |
     | WOW! | "WideOpenWest Finance, LLC" | WideOpenWest | mixed — loses "WOW!" branding |
     | Google Fiber | "Google Fiber Inc." / under Google LLC | Google | mixed — conflates with the search company |
     | Ziply Fiber | "Ziply Fiber LLC" | Ziply | yes |
     | **Consolidated Communications** | "Consolidated Communications, Inc." | **Consolidated** | **no — meaningless alone** |
     | **TDS Telecom** | **"Telephone and Data Systems, Inc."** — their actual legal/SEC name | **Telephone** | **no — doesn't even contain "TDS"** |
     | Metronet | "Metronet Inc." | Metronet | yes |
     | Breezeline | legacy "Atlantic Broadband Finance, LLC" (pre-2022 rebrand) | Atlantic | likely no — stale pre-rebrand name |

     **The failure pattern is the useful finding, not just the count.**
     Every failure above is either a legacy/M&A-holdover legal name
     surviving in ARIN records after a rebrand or acquisition (Verizon/
     MCI, Optimum/Cablevision, Breezeline/Atlantic, Astound/RCN) or a
     holding-company legal name that never matched the consumer brand at
     all (TDS/Telephone, Consolidated, Cable One/Cable) — not random
     noise, and notably it hits Verizon, one of the 3-4 biggest ISPs in
     the country. Confirms the recommendation above: first-word as the
     default (a real majority, including several of the largest
     providers), with a small curated override table for this specific,
     recognizable failure class (~6-8 entries from this table alone),
     rather than either a full curated table or first-word alone.

  2. ~~**Preferences window sizing bug.**~~ **Fixed in `99b0eb5`,
     closes #9.** Reported directly: too tall for a MacBook Air's
     screen and couldn't be resized by dragging at all. Root cause:
     `NMSApp`'s `Window("Preferences", ...)` used
     `.windowResizability(.contentSize)`, which locks the window to
     exactly its content's height with no manual resize possible —
     fine when `PreferencesView` was short, but it grew (13 SaaS
     services, DDNS hostnames, several toggles) past what fits on a
     smaller screen, the same failure `ContentView.body`'s own outer
     `ScrollView` already exists to prevent for the main window. Fix:
     wrapped `PreferencesView.body`'s content in a `ScrollView`,
     changed the scene to `.defaultSize(width: 380, height: 500)`
     instead of `.contentSize`. Verified: full test suite green, and
     live — opened the window, resized it programmatically via System
     Events (450x700, stuck), visually confirmed on the MacBook.

  3. ~~**Main window's scroll gutter is too narrow, and doesn't grow
     when the window is widened.**~~ **Fixed in `cde359f` (#10), then
     extended in `c36e4e2`.** Reported directly: the empty margin
     meant to catch trackpad/wheel input for the outer `ScrollView`
     (`ContentView.body`'s `.padding(.horizontal, 32)`) is a fixed
     32pt regardless of window width, and widening the window doesn't
     help — confirmed live: resizing the window from 600pt to 900pt
     left the tile content roughly centered with dead, non-interactive
     margin on both sides rather than the gutter itself growing.
     Fix: outer `VStack` changed from `.frame(width: 600)` to
     `.frame(minWidth: 600, maxWidth: .infinity)`; `scrollableContent`,
     `Divider()`, and `footerBar` each capped to a new shared
     `ContentView.tileContentWidth` (536, the tiles' own rendered
     width) and re-centered, so the *padding* grows with the window
     instead of a separate dead margin outside the `ScrollView`.
     **Second bug found applying this**: `scrollBox()` (the separate
     box mechanism Wi-Fi/Ethernet/SaaS Status/Events/SNMP Devices/DHCP
     History used) didn't share `tile()`'s width behavior — nested
     inside the outer `ScrollView`, it sized to its own content's
     natural width instead of its parent's constrained width, letting
     long rows push those six boxes out past every tile's edge above
     them. Two direct fixes to `scrollBox()` itself both still
     reproduced it live; fixed by switching those six sections to
     `tile()` outright (the same mechanism already proven correct) and
     removing `scrollBox()` entirely. Verified: full test suite green
     both times, and live each time — confirmed by the user who caught
     the original bug, including the second one surviving the first
     fix.

  4. **A curated list of common Wi-Fi router/AP vendor MAC OUI
     prefixes, to enrich the Wi-Fi display.** E.g. recognizing a
     BSSID's OUI as Aruba/Ubiquiti/Netgear/etc. and showing the vendor
     name alongside the raw MAC. Needs a data-source decision: the
     full IEEE OUI registry is large (tens of thousands of entries) —
     probably want a small curated subset of consumer/prosumer router
     vendors rather than the whole registry, bundled as a static
     resource rather than fetched live.

  5. ~~**Can NMS read more from macOS's own DHCP client, and could it
     trigger a renewal to help itself?**~~ **Fixed in `f034aa2` (#12).**
     Two distinct questions raised together: (a) does macOS expose more
     DHCP lease detail than NMS currently gathers, and (b) could NMS
     trigger a DHCP renew itself rather than only observing.
     **(a)**: comparing `ipconfig getpacket`'s raw output against
     `DHCPLeaseService.parse`, only one field had real diagnostic value
     and wasn't captured — `chaddr`, the MAC address the lease was
     granted to (everything else uncaptured is BOOTP protocol
     boilerplate). Added to `DHCPLeaseInfo`/`DHCPLeaseRecord`.
     **(b)**: `ipconfig set <if> DHCP` requires root outright, a much
     bigger commitment than a confirmation dialog — rejected. `scutil
     --renew <if>` (the same mechanism System Settings' own "Renew DHCP
     Lease" button uses) doesn't require root, though it still surfaces
     macOS's own administrator-authorization dialog on a standard
     (non-admin) account — confirmed live on this Mac. Two calls a few
     minutes apart only triggered one prompt, confirming macOS's normal
     authorization-caching applies, so this isn't "every click." Shipped
     as a "Renew" button on the DHCP History tile with a one-time
     confirmation alert, matching the Local Stress Test tile's own
     pattern exactly — honest about both the brief disruption and the
     possible admin-password prompt, not a silent auto-trigger.
     Verified: full test suite green, and live — clicked through the
     confirmation, watched a real new DHCP History entry appear with a
     fresh transaction ID.

  6. **Wi-Fi signal strength/speed history on the Network tile,
     dot-history style like `networkQuality`'s sparkline, with a
     color that changes over time (yellow initially, settling to
     green or red).** Raised directly as a natural extension of the
     existing dot-history pattern (`NetworkQualityRecord`'s own
     sparkline) applied to `WiFiSampleRecord`'s already-collected RSSI/
     PHY-rate data instead of a new metric. The color-over-time idea
     (start yellow, resolve to green/red) is a distinct interaction
     question from the data itself — worth its own design pass on what
     "resolves" means (a fixed timeout? enough samples collected? a
     confidence threshold?).

     **A visual precedent worth knowing about, seen live in a dedicated
     Wi-Fi status tool**: its own signal-history view is a continuous
     filled-area chart, not a dot-trail — a real, different option from
     the dot-history style this item started from. Worth weighing
     against dots before committing, not just defaulting to dots because
     that's what `networkQuality`'s own sparkline does.

  7. **DNS-unreachable should be visually distinct from other
     connectivity failures, not just red like everything else.**
     Raised directly after observing a real DNS-unreachable state in
     the field. Reasoning worth keeping: DNS failing while the router
     and raw connectivity stay healthy is a particularly confusing
     failure for a typical user — browsers fail cryptically, and it
     *looks* like "the whole internet is down" even though it isn't.
     Already distinguished at the *event* level (`dnsUnreachable` is
     its own `AppEventKind`, separate from `routerUnreachable`/
     `httpUnreachable` — see `script/scenarios.sh`'s "HTTP left
     healthy (injection is selective)" assertion), just not yet at the
     *tile display* level. Not yet designed what "visually distinct"
     should look like beyond red.

  8. **Fingerprinting common ISP/chain-store deployment models —
     considered, deliberately not pursued yet.** Idea: since chain
     locations (a Starbucks, a Whole Foods) might run identical or
     near-identical network deployments store-to-store, NMS could save
     ISP/topology data locally for comparison across visits, and
     potentially fold patterns into future app releases. The local,
     single-user comparison case (is every Starbucks the same?) is
     genuinely testable with data already collected. **The
     "incorporate into future NMS releases" half is a much bigger
     step, and not close to in scope**: it implies eventually
     crowdsourcing across *other* users' installs, which needs a
     server, a data-collection/consent model, and real privacy design
     — none of which exist and none of which should be assumed just
     because the local case is easy. Let the local-comparison version
     prove itself useful before considering that jump at all.

- [ ] **Three architectural findings from trying the `swiftui-specialist`
  skill (2026-08-04), deliberately deferred — each is a real,
  deliberate undertaking, not a same-night flag-flip.** Asked for a
  scan-and-suggest-focus-areas pass rather than a full review, per the
  skill's own large-codebase guidance. A fourth finding from the same
  pass (index-as-identity in two `ForEach`s) was small enough to fix
  immediately instead — see `c425805` for the one genuinely fixable
  site and why the other was deliberately left alone.

  1. **Observation migration — done (2026-08-04).** All 17 view
     models in `NMS/ViewModels/` converted from `ObservableObject`/
     `@Published` to `@Observable` (per-property observation tracking
     instead of `ObservableObject`'s coarse `objectWillChange`
     broadcast to every observer regardless of which field changed).
     A real migration, not a mechanical rename, done in six verified
     batches (pilot, then five batches of 2-5 view models each — see
     commit history), each followed by a full build and
     `test-quick.sh`: `EthernetLinkViewModel`, `EventLogViewModel`,
     `ISPIdentityViewModel`, `DDNSViewModel`, `SaaSMonitoringViewModel`,
     `WiFiStressTestViewModel`, `NetworkReviewViewModel`,
     `LANDiscoveryViewModel`, `PublicIPViewModel`, `WiFiSSIDViewModel`,
     `DHCPLeaseViewModel`, `NetworkIdentityViewModel`,
     `TracerouteViewModel`, `SNMPViewModel`, `NetworkQualityViewModel`,
     `NetworkMonitorViewModel`, `ConnectivityViewModel`. Every
     `@StateObject`/`@ObservedObject` site (`NMSApp.swift` and every
     `View` holding a view model) moved to `@State`/plain `var` in
     lockstep with its class's conversion, never left mismatched
     between builds.
     
     One real gotcha, not mentioned in `swiftui-specialist`'s own
     `references/dataflow.md`: eight view models have a `deinit`
     cleaning up a `Timer`/`NotificationCenter` observer token, and
     reading an `@Observable`-tracked stored property from `deinit`
     doesn't compile — `deinit` is nonisolated even on a `@MainActor`
     class, and (unlike plain `ObservableObject`/`@Published`
     properties) the macro's generated accessors surface that as a
     real "main actor-isolated property can not be referenced from a
     nonisolated context" error. Fixed by wrapping each such `deinit`
     body in `MainActor.assumeIsolated { }` — safe since every
     instance is only ever created/held on the main actor.
     
     Verified with a full build and `test-quick.sh` after each batch,
     `test-max.sh` (NMSTests + NMSUITests + live scenarios) at the
     end — all passed.

  2. **`ContentView` fan-in — done (2026-08-04).** All ten window
     tiles pulled out of `ContentView.swift`/`ContentView+Window.swift`
     into their own `View` types, each holding only the view model(s)
     it actually reads instead of the original 17-property struct:
     `EthernetTile`, `WiFiTile`, `SaaSStatusTile`,
     `EventsTile`, `SNMPDevicesTile`, `DHCPHistoryTile`,
     `PathToInternetTile`, `SpeedTestTile`, `AppleNetworkQualityTile`,
     `LocalStressTestTile`, and `NetworkTile` (the merged Network
     Health/Info tile — the largest, nine view models, since it
     genuinely synthesizes that much of the app's state). Shared
     plumbing (`tile()`/`row()`/`externalLinkIcon`/`.help(optional:)`)
     moved to `TileHelpers.swift`; the RPM color/tooltip logic shared
     between `NetworkTile` and `AppleNetworkQualityTile` moved to
     `QuickCheckDisplay.swift`; speed-test formatting moved onto
     `NetworkQualityRecord` as computed properties. Combined
     `ContentView.swift` + `ContentView+Window.swift`: 2,637 → 507
     lines. Verified with a full build, `test-quick.sh` after each
     tile, and `test-max.sh` (NMSTests + NMSUITests + live scenarios)
     at the end — all passed. `ContentView` itself still declares all
     16 view models (it has to, to construct the view-model graph and
     pass pieces down), but a change to any *one* of them no longer
     re-evaluates tiles that don't read it — only `ContentView.body`
     itself and whichever extracted tile(s) actually depend on that
     view model do. Combined with #1 above (now also done), that
     narrowing is now genuinely per-property, not just per-tile.

  3. **View structure/factoring — done for every case with a genuine
     independent invalidation story (2026-08-04); one item needs a
     live look before fully trusting it.** Surveyed all ~40 computed
     `some View` properties left after item #2. Most (row-rendering
     helpers for a single `ForEach` over one already-narrow tile's own
     one view model, e.g. `SpeedTestTile.runRows`) are the explicit
     "still have a place" carve-out in `swiftui-specialist`'s own
     `references/structure.md` — tiny fragments with no *independent*
     invalidation story, where extracting a separate `View` type would
     add indirection without changing what re-runs when. Genuinely
     factored, each into its own `View` type with narrow inputs:

     - `NetworkTile`'s `Grid` rows — `QuickCheckRow`/
       `ConnectionLayerRow`/`DHCPStatusRow`/`DDNSRow`
       (`NetworkHealthRow.swift` holds the shared `statusGridRow`
       builder + `ConnectionLayerRow`), plus made `ConnectionLayer`/
       `LayerStatus` `Equatable` so SwiftUI's struct diffing can
       actually skip an unchanged row. **Not yet visually confirmed —
       see caveat below.**
     - `PreferencesView`'s independently-toggleable sections —
       `SaaSServicePickerSection`/`UserAddedSitesSection`/
       `DDNSHostnamesSection`, each with its own `@State` moved out of
       `PreferencesView`. Before this, typing in the DDNS hostname
       field re-evaluated the unrelated SNMP toggle and SaaS picker
       too.
     - `SNMPDevicesTile`'s community-string editor — `CommunityRow`,
       with its own `@State` moved out; typing a community string no
       longer re-evaluates the tile's device `ForEach`.

     One case investigated and deliberately left as a computed
     property, not extracted: `ContentView.footerBar`. Its DEBUG-
     overrides and store-fallback banners have no `@Observable`
     property backing them at all — their only "refresh" mechanism is
     being swept along by `ContentView`'s own frequent re-renders.
     Extracting it into a `View` type with effectively-static inputs
     would make SwiftUI skip re-rendering it once its own inputs
     stopped changing, freezing those banners at whatever they showed
     on the first render — a real regression, not an improvement. See
     `ContentView.swift`'s own doc comment on `footerBar` for the full
     reasoning.

     **`NetworkTile`'s `Grid` alignment — verified structurally, not
     with the real live tile (2026-08-04).** This `Grid` has a
     documented three-round history of alignment bugs in this project
     (see `NetworkTile`'s own doc comment), and custom `View` types
     whose `body` is a `GridRow` — rather than `GridRow` appearing
     literally inside `Grid`'s own `@ViewBuilder` — needed real
     confirmation, not just "it's a documented-valid pattern."
     Screenshot automation is off by explicit instruction, and the
     real `NetworkTile` can't safely go through the `ImageRenderer`
     capture tool — `dhcpLease`/`connectivity`/`traceroute`/`publicIP`
     all spawn a timer or subprocess in `init`, the exact live-side-
     effect crash risk `NMSTests/PreviewCapture.swift`'s own doc
     comment documents.
     
     Worked around by rendering the *same* `Grid` structure and the
     *same* row types (`QuickCheckRow`, `ConnectionLayerRow` ×7, and a
     direct `statusGridRow` call standing in for `DHCPStatusRow`) fed
     with fixture `ConnectionLayer` values and one freshly-built
     `NetworkQualityViewModel` (confirmed side-effect-free at `init`)
     instead of the real object graph — see `PreviewCapture.swift`'s
     current `viewToCapture`. Rendered clean on the first try (no
     crash, no retry): all nine rows' dot/label/icon/chart/detail
     columns aligned correctly, including the Network row's sparkline,
     the Router row's external-link icon, correct root-cause-vs-
     consequence red-dimming on Internet/DNS/HTTP, and the DHCP row's
     yellow "changed recently" state.
     
     What this confirms: the *mechanism* (`GridRow` wrapped in a
     separate `View` type) genuinely works inside this specific `Grid`.
     What it doesn't confirm: the real `NetworkTile`, wired to its real
     nine view models with real data, hasn't been seen live by anyone
     — worth a look next time the app is run normally, though the
     structural risk this caveat originally worried about is resolved.

  4. **Soft-deprecated API sweep — done.** See `a512f7b`
     (`.coordinateSpace(name:)` → `.coordinateSpace(_:)`), the one
     confirmed finding from the sweep.

  Suggested order from the skill: fan-in (#2, done) → Observation
  migration (#1, done) → view structure (#3, done pending the
  `NetworkTile` visual check above).

- [ ] **`ImageRenderer`-based preview capture (`NMSTests/PreviewCapture
  .swift`, `script/capture-preview.sh`, 2026-08-04) — the crash is a
  race condition, not a single fixable line; the working version stays
  scoped to views with no real view-model dependency.** Built after
  trying `Iron-Ham/XcodePreviews` (iOS-Simulator-based, doesn't apply —
  NMS is macOS-only) as a way to see layout changes without a full
  build→launch→AppleScript→screenshot round trip.

  **Root-caused, not just narrowed.** Bisected step by step: a bare
  `Text`, a hand-built tile-shaped box, a bare `Grid`, and a `.task`
  that mutates `@State` on appear all render fine in isolation. But
  `ContentView`'s full `body`, `scrollableContent` alone, and even just
  the real Network tile (via a real `ContentView` instance from
  `ContentViewPreviewSupport.makeContentView()`) all crashed the
  test-host process — and then, rendering that same *known-safe*
  tile-shaped box while simply keeping that real instance alive in
  scope (none of its content rendered), the run crashed once and then
  succeeded identically on xctest's automatic retry. That's the tell:
  `makeContentView()` constructs all 17 real view models with their
  real side effects (background timers, subprocess spawns), and
  `ImageRenderer` expects to snapshot a static tree synchronously — if
  one of those background effects fires mid-render and touches
  `@Published`/`@State`, it crashes; if not, it doesn't. Longer/heavier
  renders reliably lose that race; short, simple ones usually win it,
  which is why the isolated examples read as "safe" until one wasn't.

  **What a real fix needs**: not a single line — a way to render
  against inert/stub view models with no live side effects, rather
  than the real, side-effecting object graph this currently reuses
  from Xcode's own canvas preview (`ContentViewPreviewSupport`, built
  for a live canvas where that liveness is the point). Two ways to get
  there, neither pursued tonight:

  1. **A second, stub-backed preview-support path** — parallel to
     `ContentViewPreviewSupport`, constructing the same view models
     against fixture data but with their timers/subprocess-spawning
     disabled (would need a flag or protocol seam most of
     `NMS/ViewModels/` doesn't have today — real work, not a quick
     addition).

  2. **Refactor `ContentView` to expose individual tiles as
     separately-reachable properties**, so a real tile could at least
     be isolated from the rest of `scrollableContent` — reduces how
     much of the live object graph's background activity overlaps a
     given render, though doesn't eliminate the race outright, since
     the view models still exist and still have their side effects
     running.

  Current tool (`viewToCapture` in `PreviewCaptureTests`) deliberately
  doesn't touch `ContentViewPreviewSupport`/any real view model at all
  — a starting point for a specific, isolated render (something
  hand-built, no live side effects), adjusted each time it's used.
  Good enough for the layout questions that came up tonight; genuinely
  rendering a real tile with real data needs one of the two above
  first.

- [ ] **Tooltips are undiscoverable app-wide — raised directly ("I can
  never find them in NMS").** Every existing tooltip (`dotHelp` on
  every `statusGridRow` line, `QuickCheckDisplay.rpmThresholdHelp`, now
  `WiFiTile`'s new `phyRateHelp`) is a plain `.help(_:)` hover — no
  visual cue that a label has more info at all, so finding one means
  blind guess-and-hover across the whole app. Surfaced while adding the
  PHY Rate tooltip (below) — that one has the identical problem the
  moment it ships.

  **Recommended fix, not yet built: a small "ⓘ" info glyph next to any
  label that has a tooltip**, so it's visibly discoverable instead of
  invisible-until-hovered. Keep the trigger itself native `.help()`
  hover — macOS doesn't expose a supported way to shorten that delay,
  and reaching for an undocumented/private-API hack for it isn't worth
  it. This is a real pass across every existing tooltip site (the
  status-dot `dotHelp`s, RPM help, PHY Rate help), not a one-line
  tweak — deferred as its own item rather than folded into the PHY
  Rate change that surfaced it.

- [x] ~~PHY Rate reads as a speed guarantee with nothing explaining the
  gap between it and what NMS actually measures.~~ **Built.**
  `WiFiTile`'s PHY Rate row now carries a tooltip
  (`WiFiTile.phyRateHelp`, via a new optional `help:` parameter on the
  shared `row(_:_:)` helper) explaining it's a negotiated ceiling, not
  a throughput guarantee, and that the gap is mostly protocol overhead
  and — especially in a crowded area — contention with neighboring
  networks, not something even a good access point controls. Prompted
  by a real live comparison this session: Apple's own `networkQuality
  -v`, run directly against this Mac's real Wi-Fi connection, showed
  excellent idle latency (4555 RPM) but loaded responsiveness of only
  315 RPM ("Medium" per Apple's own classification) — below this app's
  own "poor" threshold (800), confirming real bufferbloat under load
  that a fast PHY Rate/idle-latency number gives no hint of. Inherits
  the same discoverability problem as every other tooltip in the app —
  see the item directly above.

- [ ] **An expert mode and a second, calmer mode — not yet named,
  deliberately not "beginner" (raised directly: don't call it that).**
  Ties directly into the already-established plan (see this file's
  archived "docs/user-guide.md" item and DESIGN-NOTES.md): focus stays
  on the single technical window for now, a simplified UI for
  non-technical users is a real but later, separate phase — this
  extends that same eventual split to tooltips specifically, prompted
  by today's tooltip work going noticeably more technical (`scutil
  --renew`, `dig` against a named public resolver, subnet-scoping
  detail) right after it was raised directly that NMS "still targets
  expert users."

  **The design question this raised — two tooltip strings per spot, or
  one that adapts — has a first real answer now, scoped narrowly on
  purpose.** Built as a `FeatureFlags.tooltipTechnicalDetail` toggle
  (Preferences → "Tooltip Detail," Concise/Technical segmented picker,
  on-by-default) plus a `tooltip(_:technical:)` helper composing one
  adaptive string from an always-shown base and an optional appended
  clause — not two independent copies, avoiding the drift risk
  `rpmThresholdHelp`'s own reasoning already flagged. Wired into the
  five tooltips that had just gained mechanism-level detail (Refresh,
  DHCP Renew, SNMP Scan, DDNS Add, user-site Add). Deliberately named
  around what it actually does today (tooltip wording only) rather than
  "Simple/Expert" — see the naming-collision reasoning below, still
  intact and still the reason the bigger split isn't this.

  **Still open**: `PHY Rate`'s and `rpmThresholdHelp`'s own tooltips
  weren't split the same way — their technical content is woven through
  the explanation rather than appended at the end, so they'd need a
  rewrite, not just a call-site change, to fit the same `base`/
  `technical` shape. Worth doing once there's a second real reason to
  touch either, not a special-cased exception to chase down now.

  Whatever the bigger mode's naming lands on, it's still the same mode
  boundary as the future "Nominal popover" idea already tracked
  elsewhere in this file's history, not a second, unrelated toggle —
  worth deciding both together rather than shipping two separate
  expert/simple splits over time. This tooltip-detail preference is a
  deliberately small, reversible first step toward that, not a
  commitment to the eventual name.

- [ ] **Wi-Fi channel-crowding scan — how many other networks are
  competing for the current channel, as a clue toward poor Wi-Fi
  performance.** Raised directly, connecting to the "consumers see a
  PHY Rate number, not the real crowded-spectrum picture" reasoning
  already behind `WiFiTile.phyRateHelp` — this would make the crowding
  concrete and specific to the user's own environment instead of just
  explaining that it exists in the abstract.

  **Mechanism, not yet verified live**: CoreWLAN's
  `CWInterface.scanForNetworks(withSSID:)` returns every nearby
  `CWNetwork`, each with its own `channel`/`rssiValue` — counting how
  many share (or overlap) the currently-associated channel is the real
  signal. Two real correctness traps worth designing around from the
  start, not discovering after building: **2.4GHz channel overlap**
  (channels 1-11 in the US overlap except 1/6/11, so an exact
  channel-number match undercounts real interference — needs an
  overlap-aware count, not a bare equality check) and **weighting by
  signal strength, not a raw count** (a network at -85dBm barely
  competes for airtime against one at -50dBm on the same channel; an
  unweighted "N networks detected" could overstate crowding from
  distant/weak APs that aren't really the problem).

  **Known constraints from precedent already in this app**: Wi-Fi
  scanning needs Location Services authorization on modern macOS
  (`WiFiSSIDViewModel` already has a real, silent-when-denied path for
  this — same handling would apply here, not a new permission story),
  and an active scan takes real time and shouldn't run as background
  polling — on-demand only, same "costly features are on-demand, not
  always-running" convention Speed Test and Apple networkQuality
  already follow.

  **Checked against a real reference tool, raised directly: what does a
  dedicated professional Wi-Fi analyzer do here, that NMS could
  borrow?** Confirmed from that tool's own vendor blog (not just a
  generic description): its "Utilization inspector" added an
  **"Overlapping Networks" column — a raw count of networks overlapping
  the selected channel**, exactly the overlap-aware metric already identified above
  as the correctness trap to design around, now with real precedent
  that it's the right thing to count. Two things this changes about the
  plan:
  1. **A professional tool shows this as a plain number in a column,
     not a color-coded severity dot** — real evidence that "just show
     the count, let an expert reader interpret it" is a legitimate,
     established answer, not a cop-out. Strengthens the case for
     starting numeric-only and deferring color entirely, rather than
     inventing thresholds to justify a dot that this app's own
     `statusGridRow` shape would otherwise default to.
  2. **"Channel Utilization" itself (a %-busy airtime measure, distinct
     from a network count) is the actual richer metric professional
     tools use it alongside** — not yet confirmed whether CoreWLAN's
     public API exposes anything like it (`CWNetwork`/`CWInterface`
     only surfaced RSSI/channel/BSSID in what's been checked so far);
     if it doesn't, "Overlapping Networks" is the closest thing NMS can
     build without deeper/private API access, which is fine as a
     starting point but worth being honest that it's a proxy, not the
     same measurement a real spectrum-aware tool reports.

  One thing found in a search but *not* confirmed as that tool's own,
  and deliberately not adopted here: a "Channel Score" composite
  weighted-penalty formula (100 minus several named penalty terms)
  turned up in the same research pass, but the sourcing was ambiguous
  enough (possibly a different, competing tool blended into the same
  search results) that it isn't attributed to any specific product or
  treated as a real precedent — flagged so it doesn't get cited as one
  later without being re-verified against a first-party source.

  **Revised plan, given the above**: ship the overlap-aware
  "Overlapping Networks"-style count as a plain number first — no color,
  no invented thresholds, matching the reference tool's own choice —
  and treat a color-coded severity dot as a real follow-up only once
  there's an actual authoritative source for what count is genuinely
  bad, not a v1 requirement. Also worth a real check on `CWInterface`'s
  actual surface area before committing to "count only" as the ceiling
  of what's possible here.

  **Two more things seen live in a real session with that same tool
  against a real network, not just from the earlier web research**:
  1. **Channel Width matters for interpreting the count, not just the
     count itself** — an 80MHz channel occupies substantially more
     spectrum than a 20MHz one, so it inherently overlaps more of what's
     nearby. Worth showing alongside whatever overlap count NMS builds,
     not just the count alone, or a wide-channel network and a
     narrow-channel one with the same raw count would read as equally
     crowded when they aren't.
  2. **A small signal-strength fill-bar next to the dBm/RSSI number** —
     genuinely simple to build (a `Rectangle` scaled to signal strength,
     no chart library), and a real, low-effort visual upgrade over a
     bare number, independent of the crowding-count feature itself.

  **Explicitly out of scope for "simple," seen in the same session**:
  a real frequency-domain spectrum chart — each nearby network drawn as
  its own occupied-bandwidth shape across the band, the selected
  network highlighted so overlaps are visible at a glance. This is
  genuinely the most useful part of a dedicated analyzer for actually
  *seeing* crowding, but it's custom chart-drawing code and a real UI
  undertaking on its own — worth keeping as a distinct, much-later idea,
  not folded into "add a count to a row."

- [ ] **Log AP-to-AP roaming as a real event — a confirmed gap, not
  built.** Raised directly while looking at a dedicated Wi-Fi status
  tool, which notifies on exactly this ("when the computer... moves
  (roams) to a different access point"). Checked directly, not assumed: `grep`ing
  `AppEventKind` for anything roaming/BSSID-shaped turns up nothing —
  NMS shows the *current* BSSID in the Wi-Fi tile, but never logs a
  transition when it changes while the SSID stays the same (a real,
  distinct signal from `wifiNetworkChanged`, which is about roaming
  *between* SSIDs/networks, not APs within one). A multi-AP home or
  small-office setup — this Mac's own Aruba pair among them — roams
  silently today; nothing in Events would show it happened at all,
  let alone when or how often.

  **Directly testable, not just theoretical** — two APs on the same
  SSID are already available for real roam testing, not a hypothetical
  scenario to design blind for.

  Shape, not yet designed: a new `AppEventKind` case (`wifiRoamed` or
  similar), logged from wherever `WiFiSSIDViewModel` already detects a
  BSSID change, carrying old/new BSSID (and ideally old/new RSSI, to
  distinguish "roamed to a stronger AP" from "roamed to a weaker one" —
  the second being the more actionable finding). Same "only a real
  transition logs anything" convention every other change-event in this
  app already follows.

- [ ] **An automated "Run Field Test" button — sequences the safe
  checks, captures the result as data and a real screenshot, and gives
  a summary verdict.** Raised directly, building on
  `script/export-diagnostic.sh` (confirmed still working this session)
  and the field-testing workflow it exists for. Three real design
  questions this surfaced, not just "add a button":

  1. **A collision with deliberate consent gates already in this exact
     codebase — the central design tension, not a detail.** SNMP
     scanning is off by default specifically because "a friend testing
     on their own network hasn't necessarily reviewed or approved NMS
     probing their devices" (`FeatureFlags.snmpDevices`'s own doc
     comment) — precisely the field-testing scenario this button is
     for. Local Stress Test has its own one-time confirmation dialog
     because it generates real disruptive traffic; Apple networkQuality
     can use 1+ GB per run. A single button that fires all of these
     automatically either silently bypasses safeguards that exist for
     good reason, or has to stop and ask mid-sequence anyway, which
     defeats the point of automating it. **Resolved shape**: scope the
     automated button to only the already-safe, already-unconsented
     checks (traceroute, the quick ~5s networkQuality check) by
     default; the expensive/consent-gated ones (SNMP scan, Local
     Stress Test, full Apple networkQuality, Speed Test) stay separate,
     still-manual, still-deliberate actions run alongside it, not
     folded into the automated sequence.

  2. **Screenshot, but not via the existing Screenshot/Bug Report
     mechanism — that path has a known, real fidelity gap that would
     undermine the exact cross-referencing this is for.** The existing
     capture (`ImageRenderer` with `isCapturingScreenshot = true`,
     see `BUGS.md`) deliberately renders differently than the live
     window — it unclips scrollable sections so `ImageRenderer` has
     something to draw — which already caused a real bug: a captured
     screenshot showed text wrapping correctly while the live window
     was actually truncating it. Using that same path to check "does
     the display match the data" wouldn't reliably show what was
     actually on screen. The reliable alternative, already proven
     working throughout this project's own verification workflow this
     session: `/usr/sbin/screencapture -l<windowID>` — real on-screen
     pixels, not a separate re-render. Needs Screen Recording
     permission, a new permission dialog this app doesn't currently
     trigger anywhere — worth knowing going in, not discovering after
     shipping. (A more correct but bigger fix — replacing
     `ImageRenderer` with `NSView.cacheDisplay`-style capture of the
     real live view — would resolve the underlying gap for Screenshot/
     Bug Report too, not just add a third capture mechanism alongside
     two existing ones. Worth doing eventually; not required to unblock
     this item.)

  3. **A result summary has a real, dormant home already designed for
     it — `OverallStatus.compute`, written up in `DESIGN-NOTES.md`'s
     "All systems Nominal" section but never wired into any UI since
     the single-window rebuild removed the menu bar icon that used to
     show it.** A field-test verdict is exactly the kind of concrete
     trigger that could justify reviving it, rather than inventing a
     second, separate "test result" concept that would need its own
     aggregation logic.

  Not yet built — this is the scoping pass (what's safe to automate,
  which capture mechanism is trustworthy, where the verdict comes
  from), not a decision to start coding.

- [ ] **An HTML/CSS mockup harness for UI experiments, styled to match
  the real native app, not the marketing website.** Raised directly,
  after reflecting on how many rounds of UI iteration this session
  actually needed (dot sizing, row-highlight placement, box heights,
  tooltip styling) — each one a real build-relaunch-screenshot cycle
  for a change where the underlying logic was trivial and the visual
  feel was the only thing actually being decided.

  **The real, checked reason this would help, not just a hunch**: web
  content exposes a queryable structure (`get_page_text`, `read_page`,
  raw JavaScript against the DOM) that's precise and reliable; native
  macOS introspection only goes through the Accessibility API via
  `osascript`/System Events, which this project's own `CLAUDE.md`
  already documents as unreliable here (button lookup by name failing,
  sheets missing from the expected accessibility tree) — hit again this
  session as an empty result querying the networkQuality status text.
  Not "screenshots work better on the web" (they don't — the Browser
  pane had its own blank/stale-screenshot flakiness this session, same
  as native) — the actual advantage is a real introspection API on one
  side and mostly-guessed crop coordinates on the other. There's also
  an NMS-specific complication a mockup sidesteps entirely: the live
  app mixes real, sensitive network data into every screenshot, which
  cost real effort (and a few deleted files) avoiding this session — a
  mockup with fixture data has zero risk there.

  **What doesn't exist yet and would need building first**: a base
  harness that actually matches the real app's look (native fonts,
  colors, tile borders, row spacing) — not the marketing website's
  bright SaaS styling, a different visual language entirely. Once that
  exists, the workflow for a UI experiment becomes: iterate on the
  mockup live (instant reload, no privacy risk, precise JS-based
  verification) until the design feels right, then port the settled
  result into the real SwiftUI view — the translation step is
  unavoidable either way, but the exploration phase before it gets much
  faster.

  **Real, explicit limits, not oversold**: only helps for pure visual/
  layout experiments where the point is deciding how something should
  look. Doesn't help for anything where real behavior matters (state
  changes, real data, actual `Grid`/AppKit interop) — those still need
  the real app regardless, and the mockup can't catch the
  native-framework-specific rendering bugs that actually caused several
  real bugs in this app (the `Grid`/`NoBounceScrollView` interop issues
  were AppKit/SwiftUI-specific, invisible to any HTML version). Worth
  it for a non-trivial visual experiment; not worth it for a one-line
  tooltip change.

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
  change than the current merge; see DESIGN-NOTES.md. Reaffirmed directly
  (2026-08-03), not just left alone: Aruba/VRRP-pair APs are uncommon in
  NMS's actual target audience (home/small-office networks), so this is
  very unlikely to affect anyone else's install. The odd double-entry
  display (`10.0.0.16`, the virtual IP, and `10.0.0.17`, physical AP1's
  own address, both reporting `sysName: AP1` while AP1 is the active
  VRRP master — surfaced via `script/export-diagnostic.sh`'s first real
  run) is accepted as a cosmetic quirk specific to this one uncommon
  setup, not worth the bigger modelling change to fix generally.
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
