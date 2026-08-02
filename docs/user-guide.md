# NMS — User Guide

A menu bar utility that watches your Mac's network path — router, ISP
edge, DNS, HTTP, and any switches/APs you point it at — and tells you
what actually broke.

## Contents

1. [Install & authorize](#1-install--authorize)
2. [The menu bar icon](#2-the-menu-bar-icon)
3. [Anatomy of the popover](#3-anatomy-of-the-popover)
4. [Expert Mode](#4-expert-mode)
5. [Usage scenarios](#5-usage-scenarios)
6. [Reference tables](#6-reference-tables)
7. [Troubleshooting](#7-troubleshooting)
8. [What it deliberately won't do](#8-what-it-deliberately-wont-do)

## 1. Install & authorize

NMS is a single unsigned `.app` — no installer, no account, no
configuration file. Everything it shows comes from reading your Mac's
own network state directly.

**1. Move it somewhere permanent.** Drag `NMS.app` into `/Applications`
(or anywhere you like — it has no installer and writes nothing outside
its own app-support folder). Running it from Downloads works too, it
just won't survive a cleanup pass.

**2. Get past Gatekeeper.** NMS is built and signed locally, not
notarized by Apple, so the first launch is blocked. Double-clicking it
gives you a dead end ("Apple could not verify…" with no Open option).
Instead:

- Control-click (or right-click) `NMS.app` → **Open** → confirm **Open**
  in the dialog, *or*
- If that doesn't offer an Open option: **System Settings → Privacy &
  Security**, scroll to Security, click **Open Anyway** next to the NMS
  mention, then launch it again and confirm.

You only do this once. After the first successful launch, it opens
normally from then on.

**3. Grant Local Network access.** Almost immediately after launch,
macOS asks: *"NMS would like to find and connect to devices on your
local network."* Click **Allow** — without it, NMS can only reach as
far as your router, and SNMP/LAN discovery return nothing.

**4. Location access — only if you use Wi-Fi.** macOS treats a Wi-Fi
network's name (SSID) as location-sensitive, so reading it needs
Location permission. NMS only asks the moment it's actually needed — the
first time you're connected over Wi-Fi rather than Ethernet. Decline and
NMS keeps working, it just shows "Wi-Fi" instead of the network's name.

> **Optional — launch at login.** NMS has no built-in login-item
> setting. To start it automatically: **System Settings → General →
> Login Items & Extensions**, then add NMS under "Open at Login."

> **What it needs, and doesn't.** No account, no cloud service, no
> phone-home. Local Network and (optionally) Location are the only two
> permissions it asks for, both explained above — everything NMS
> displays is read directly from this Mac.

## 2. The menu bar icon

One glance tells you whether anything needs your attention — click it to
open the popover, click anywhere else to close it.

| Color | Meaning |
|---|---|
| 🟢 Green — normal | Everything on the critical path (router, ISP edge, internet, DNS, HTTP, public IP) is reachable. |
| 🟡 Yellow — marginal | The critical path is fine, but something you're separately watching — an SNMP-monitored switch or AP, or a configured printer — isn't answering. |
| 🔴 Red — critical | Your network interface is down, or one of the critical-path checks is failing. Something is actually broken. |

This is a strict priority order, not a count — one critical failure
means red even if everything else is fine, and a marginal issue never
escalates to red on its own.

## 3. Anatomy of the popover

![The full popover](images/popover.png)

*A real capture, on public Wi-Fi at a coffee shop — caught mid-outage:
the router briefly stopped answering, marked with the asterisk NMS adds
when a failure lines up with a recent network change. "New network,"
since this was the first time on this particular Wi-Fi.*

The popover is deliberately narrow in scope: **can I work right now, and
what's restricted about this network** — two tiles, side by side, plus a
footer. Everything more diagnostic — history, on-demand tests, per-device
detail — lives one click away in [Expert Mode](#4-expert-mode) instead,
so a fresh install's popover stays this short regardless of how many
diagnostic sections NMS has.

### Network Health

Seven rows, each a colored dot plus a sparkline and a response time or
status, ordered **bottom to top** as the actual path out of your Mac —
read it that way when something's wrong:

| Row (bottom → top) | What it actually checks |
|---|---|
| Network | Is there an active interface at all, and do we know what it's connected to (Ethernet, or a named Wi-Fi network) |
| Local Router | Ping to your gateway's LAN address — is anything answering one hop away |
| Public IP | Ping to your *own* router's WAN-facing address — tests whether the gateway's internet-facing side is alive (catches a dead modem/ONT the LAN-side check can't see) |
| ISP Edge Router | Ping to whichever traceroute hop you've confirmed as your ISP's own router — "Not confirmed" until you do (see [Expert Mode → Path to Internet](#path-to-internet)) |
| Internet Ping by address | Ping to a fixed public address (1.1.1.1) — real reachability past your ISP, bypassing DNS entirely |
| DNS | A fresh, cache-busting name resolution — catches DNS-specific outages a raw ping wouldn't |
| HTTP | An actual HTTPS fetch — catches a captive portal or an ISP filtering everything but web traffic |

Next to each row's response time is a small **sparkline** — its last
~30 checks, roughly the past 15 minutes. Each row scales its own line
independently, since DNS's single-digit milliseconds and a real internet
ping's tens of milliseconds would otherwise share an axis and flatten
the faster one into a flat scribble. A failed check breaks the line
rather than smoothing across the gap, marked with a small red dot along
the bottom — a bad patch is visible at a glance instead of silently
averaged away.

> **Root cause vs. consequence.** When several rows fail together, only
> the **lowest** shows full-intensity red — everything above it shows a
> dimmed red, since it's presumed a consequence, not a separate problem.
> An asterisk (`*`) next to a failure means it started right around a
> network change NMS also observed.

The Local Router and ISP Edge Router rows also get a small link icon
once their address is known, opening that device's admin page in your
browser — for the router, its own IP; for the ISP edge, whatever URL an
SNMP-detected web server there answered on, if any.

### Info

Network name and type, IP address in CIDR notation, router (address and
hardware MAC), DNS server address, and your current public IP. When NMS
can identify the organization behind your public IP's allocation, an
**ISP** row appears too — with a link to that ISP's public status page,
when one exists in NMS's own curated list. The **Known network** / **New
network** line with a "seen N×" count tracks how often NMS has
recognized this router before (by its hardware address, not its name).

Wi-Fi-specific detail (BSSID, signal strength, channel, PHY rate,
security) lives in Expert Mode's own **Wi-Fi** section instead of here —
see below.

### Footer controls

**Refresh** re-reads network state immediately. The camera icon saves a
screenshot of the popover and logs an event naming the file. The bug
icon opens a small comment field, then saves that same screenshot
alongside a state dump and your comment — use it to report something
that looks wrong, since it captures far more context than a plain
screenshot. **Expert Mode…** opens the same live data in a separate,
resizable window (see below). **Networks…** opens the list of every
network NMS has recognized (see [Scenario E](#scenario-e--recognizing-youre-on-a-different-network)).
**Preferences…** opens toggles for experimental features — whether to
turn on [SNMP Devices](#snmp-devices) (off by default) and
[SaaS Status](#saas-status) (on by default), which SaaS services to
monitor, and any sites you've added yourself. Every toggle applies
immediately, no restart needed. **Quit** exits NMS. The small gray line
underneath shows the build hash and the store's on-disk size.

## 4. Expert Mode

The popover has a fixed height and can't scroll, so anything more than
"can I work, what's restricted" would mean either an ever-taller popover
or an always-cropped one. **Expert Mode** opens the same live state in an
ordinary, resizable window instead, with every diagnostic section: a
full-width copy of Network Health and Info, plus Path to Internet, Speed
Test, Wi-Fi or Ethernet detail, SaaS Status, Events, SNMP Devices, and
DHCP History. Each history section scrolls independently in its own box,
and a scrollbar on the right reaches anything taller than the window
itself. Both surfaces stay open to the same live state — closing the
window doesn't stop monitoring, and the popover keeps working normally
alongside it.

### Path to Internet

NMS traces the route out to the internet and suggests which hop is
genuinely your ISP's own router — the first non-local hop isn't always
right, since a campus or enterprise network can hand out its own public
address space before traffic reaches the actual ISP. Tap the star (★)
next to the correct hop to confirm it; that address is then pinged on
the same fast cadence as everything else in Network Health, not
re-traced from scratch each time. **Trace Now** re-runs the trace on
demand.

### Speed Test

Two independent sources sharing one history list:

- **Run Speed Test** measures throughput against a public endpoint — up
  to roughly 50MB of real data transfer on a fast connection, so it's a
  manual action, never run automatically. On a slow connection (DSL,
  say) it uses much less: each direction starts with a small probe and
  only pulls the full amount if the probe suggests it's needed for an
  accurate reading. Takes about a second on a fast connection.
- **Run Network Quality** (next to the "up to ~50MB per run" label) runs
  Apple's own network quality test for the one signal a plain transfer
  can't produce — responsiveness under load (RPM). Takes 25–40 seconds.

Every run is kept, newest first, as a genuine time series — unlike DHCP
History, a run gets a row even when the numbers are close to the last
one.

### Wi-Fi

Shown only when you're actually connected over Wi-Fi. BSSID (the
specific access point you're associated with — useful on a network with
more than one AP), signal strength with a trend sparkline (and an SNR
figure when noise is also reported), channel and band, negotiated PHY
rate, and security type.

### Ethernet

The counterpart to Wi-Fi above, shown only when you're on a wired
connection: negotiated link speed and duplex (e.g. "1000 Mbps, Full
Duplex"). No trend to chart here — unlike a Wi-Fi signal, a wired link's
speed is fixed the moment it's negotiated and only changes on a physical
event (a different cable or switch port).

### SaaS Status

*On by default* — the one experimental feature that is, since it only
reaches public status pages rather than probing your own network (see
**SNMP Devices** below for the one that isn't). Periodically checks the
public status pages of business services you use (Slack, GitHub,
Cloudflare, and many others — pick which ones in **Preferences…**, or
turn the whole feature off there) and lists each with its current
status and a link to its own page. You can also add your own sites
under **Preferences…**; those are checked for plain reachability only
(not a real status page), shown separately under **Your Own Sites** so
that weaker signal isn't confused with a vendor's own reporting.

### Events

A running log of state changes — not a stream of every check. Most
entries are transition pairs: an outage produces one red line when it
starts and one green line when it clears, with nothing logged while
things stay the same in either direction. Some entries are purely
informational rather than up/down pairs — your public IP or ISP
changing, a network you've switched to or away from, an SNMP device's
software updating, a DHCP lease changing — these render in a neutral
color rather than red or green. A fresh install with a healthy network
correctly shows nothing here yet, not an error.

### SNMP Devices

*Off by default — turn on **SNMP Devices** under **Preferences…** first.*
Unlike SaaS Status above, this is active probing of your own LAN, so
it's opt-in rather than on by default. Once enabled, any switch, access
point, or other SNMP-capable device NMS can reach on your *current*
subnet gets listed with its name, current uptime, and software/firmware
descriptor — a device that unexpectedly restarts (uptime resets) or
changes descriptor (a firmware update) logs an event automatically.
Each row's leading dot is that device's live reachability. When NMS
finds a web admin page on a device, a small link icon opens it
directly. **Scan** clears the list and re-sweeps the subnet from
scratch — expect up to 15–20 seconds on a full /24.

Two devices sharing one physical network interface (a common VRRP
setup) are shown as a single entry with both addresses listed, rather
than as two separate devices. SNMP community strings — the read-only
"password" your gear expects — default to `public`; click **Change** to
edit them as a comma-separated list, tried in the order you list them.

Scanning never reaches outside your current subnet — a device only
visible from a different network (a guest Wi-Fi VLAN on the same
router, say) won't show up here until you're actually on that network.

**Printers get monitored even without SNMP.** Any network printer you've
already set up in System Settings → Printers & Scanners gets watched for
reachability too, whether or not it answers SNMP — NMS reads your Mac's
own printer configuration (`lpstat`) rather than relying on discovery. A
printer that also answers SNMP shows up once, in the list above; one
that doesn't still gets pinged, it just doesn't get its own row here
(no uptime/firmware to show for it) — its status folds into the same
marginal/critical signal and Events log as everything else being
watched. NMS doesn't attempt real-time fault detail (out of paper, cover
open) — on the hardware tested so far, neither CUPS nor the standard
SNMP printer MIB expose that while idle, so it isn't shown rather than
shown unreliably.

### DHCP History

Every time your DHCP lease actually changes — a different server,
address, or timing — NMS records it here, newest first. The newest
entry doubles as your current lease. Each entry is two lines: server and
assigned address on the first, every other parsed field (broadcast,
gateway, DNS, domain, lease/T1/T2 timers, transaction ID) on the second.

## 5. Usage scenarios

### Scenario A — First time on a new network

1. Open the popover and check **Info** — confirm the router/DNS
   addresses and public IP look right for where you are.
2. Open **Expert Mode**. Under **Path to Internet**, star the hop
   that's genuinely your ISP's router. This turns "ISP Edge Router" in
   Network Health from "Not confirmed" into a real, monitored check.
3. If you manage the switches/APs here, turn on **SNMP Devices** under
   **Preferences…** (off by default), then in Expert Mode set the right
   community string and click **Scan**. Anything that answers gets
   tracked for restarts and firmware changes from then on.

### Scenario B — "Is it my Wi-Fi, or is the whole internet down?"

Read Network Health **bottom to top** (visible directly in the popover)
and find the lowest row that's failing — that's almost always the real
fault, not the highest one:

- **Network is red** — the interface itself is down (cable, Wi-Fi drop,
  adapter). Nothing past it can be evaluated.
- **Network is green, Local Router is red** — your Mac is fine, but
  nothing beyond it answers: a switch, AP, or the router itself.
- **Local Router is green, ISP Edge Router or Internet is red** — your
  LAN is healthy; the break is upstream, between you and your ISP.
- **Everything below is green, only DNS or HTTP is red** — raw
  connectivity works; this is a resolver or web-filtering problem, not a
  real outage.

Each row's sparkline is worth a glance too — a run of red dots pinpoints
exactly when a layer started failing.

### Scenario C — The suggested ISP hop looks wrong

On a campus or enterprise network, the first non-local traceroute hop
can be your own organization's router, not the actual ISP. In **Expert
Mode → Path to Internet**, if the suggested hop's hostname doesn't look
like an ISP, scroll the hop list and star the correct one further down
instead — Network Health switches to monitoring that address
immediately.

### Scenario D — Watching a specific switch or AP

Turn on **SNMP Devices** under **Preferences…** if you haven't already
(off by default). Then in **Expert Mode → SNMP Devices**, set the
community string it actually uses, click **Scan** once to find it, and
NMS re-polls it every minute from then on. Watch for an uptime that
resets to zero (an unplanned restart) or a software descriptor that
changes (a firmware upgrade) — both generate an Events entry the moment
they're noticed.

### Scenario E — Recognizing you're on a different network

The **Known network** / **New network** line is keyed on the router's
own hardware address plus the subnet — not the network's name — so it
correctly tells apart a main LAN from a guest VLAN on the *same* router
(which otherwise share the same hardware address), and recognizes your
own network again after leaving and coming back, even across an
interface change (Ethernet to Wi-Fi).

Events, SNMP Devices, DHCP History, and Wi-Fi/Ethernet detail are all
scoped to whichever network is current: visiting a neighbor's network,
or any network other than your own, never mixes its data into your
usual history, and switching back shows your own history exactly as it
was. **Networks…** in the footer opens a list of every network NMS has
ever recognized — click into the name field to give a network a label
of your own (e.g. "Home," "Office"), which then shows up throughout the
app in place of the router's hardware address. **Review** opens a
read-only history for that network specifically (its own Events, SNMP
Devices, DHCP History, and Wi-Fi telemetry, exactly as it looked while
you were last on it), with a **Generate Report** button that produces a
plain-text summary you can save or paste elsewhere. **Forget** removes a
network and everything recorded on it, permanently.

## 6. Reference tables

### Status colors

| Color | Meaning |
|---|---|
| Full red | The root-cause layer — the lowest thing actually failing. |
| Dimmed red | Failing as a likely consequence of the row below it. |
| Gray | Not a failure — genuinely not evaluated yet (e.g. ISP Edge Router before you've confirmed a hop). |
| Green | Checked, and reachable. |

### How often things are checked

| Check | Normal interval | Notes |
|---|---|---|
| Network Health (all rows) | 30s | Drops to 5s while anything critical is failing; the first failure triggers one extra round immediately |
| SNMP device re-poll | 60s | Only already-discovered devices — a fresh Scan is manual |
| Public IP lookup | 5 min | Also re-checked immediately after any topology change |
| ISP identification | Whenever the public IP changes | Not on its own timer — a registrant only changes when the allocation behind your public IP does |
| Traceroute re-run | 10 min | Also re-run after any topology change, and when internet reachability changes either direction |
| Wi-Fi / Ethernet detail | 60s (Wi-Fi) / on network change (Ethernet) | Ethernet's link speed rarely changes mid-session, so it's re-read on a topology change rather than a timer |

## 7. Troubleshooting

**`snmpget` unavailable on this macOS version.** Apple removed the
underlying command-line tool. Nothing to fix on your end — SNMP
features are unavailable on this Mac.

**SNMP Devices doesn't appear in Expert Mode at all.** It's off by
default — turn it on under **Preferences…** first.

**No SNMP devices found (with the feature already on).** Either nothing
on your subnet answers SNMP under the current community string(s), or
it's mid-scan (15–20s on a full /24) — check the string under
**Change** first.

**A device I know is on my network never shows up in SNMP Devices.**
SNMP scanning is deliberately restricted to your current subnet — a
device only reachable from a different network (a guest VLAN on the
same router, a different Wi-Fi network entirely) won't be found until
you're actually connected to that network yourself.

**Network name never appears on Wi-Fi.** Location permission was
declined. Grant it under **System Settings → Privacy & Security →
Location Services** if you want the SSID shown; NMS otherwise works
fine without it.

**Public IP shows "Not checked" briefly after launch.** Normal — it
resolves within a second or two of opening the app.

**App won't open at all, no dialog.** Revisit step 2 in [Install &
authorize](#1-install--authorize) — this is Gatekeeper blocking an
unnotarized app, not a crash.

**Network Health flashed red briefly, but nothing appeared in Events.**
By design, not a bug. If every path-critical row (Router, Public IP, ISP
Edge Router, Internet) fails at once while DNS or HTTP still succeeds,
NMS treats that as this Mac being too busy to run its own ping checks on
time — not a real outage — and skips logging it. The measurements are
still recorded, so the sparkline may briefly show it; this is most
likely during something CPU-heavy running at the same time, like a
build.

**Two identical rows for the same device in SNMP Devices.** A real,
known quirk, not a bug in the data: NMS merges a device answering at two
addresses (a common VRRP setup) into one row once it has confirmed both
addresses share the same hardware. Right after a network change, that
confirmation can lag until the next scan, so the same device briefly
shows twice.

## 8. What it deliberately won't do

- No push notifications, email, or remote alerting — it's a menu bar
  indicator you glance at, not a monitoring service.
- Watches from this one Mac's point of view only — it can't tell you
  whether a problem is local to this machine or affects the whole
  network.
- Sparklines cover roughly the last 30 checks per layer (about 15
  minutes) — a short-term trend, not a long-term historical dashboard.
  Events remains a recent-activity log, not a trend graph.
- SNMP discovery covers your current subnet only, strictly — never a
  routed/remote segment, and never a different network you've merely
  visited recently.
- No real-time printer fault detail (out of paper, cover open) — see
  the note under [SNMP Devices](#snmp-devices).

---

*NMS is a personal macOS utility, not a commercial product.*
