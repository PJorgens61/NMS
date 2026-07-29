# NMS — User Guide

A menu bar utility that watches your Mac's network path — router, ISP
edge, DNS, HTTP, and any switches/APs you point it at — and tells you
what actually broke.

## Contents

1. [Install & authorize](#1-install--authorize)
2. [The menu bar icon](#2-the-menu-bar-icon)
3. [Anatomy of the popover](#3-anatomy-of-the-popover)
4. [Usage scenarios](#4-usage-scenarios)
5. [Reference tables](#5-reference-tables)
6. [Troubleshooting](#6-troubleshooting)
7. [What it deliberately won't do](#7-what-it-deliberately-wont-do)

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
| 🟡 Yellow — marginal | The critical path is fine, but something you're separately watching — an SNMP-monitored switch or AP — isn't answering. |
| 🔴 Red — critical | Your network interface is down, or one of the critical-path checks is failing. Something is actually broken. |

This is a strict priority order, not a count — one critical failure
means red even if everything else is fine, and a marginal issue never
escalates to red on its own.

## 3. Anatomy of the popover

![The full popover](images/popover.png)

*A real capture — a brief blip took the router and one AP down and
back up a few minutes earlier, bracketed by matching "became
unreachable" / "reachable again" pairs in Events. The two identical
"AP1" rows in SNMP Devices are a separate, known quirk: NMS merges a
device answering at two addresses (a common VRRP setup) into one row
once it has confirmed both addresses share the same hardware — right
after a network change, that confirmation can lag until the next scan,
so the same device briefly shows twice.*

The popover is a 2×2 tile grid up top — **Network Health** and **Path to
Internet** on the left, **Info** and **Speed Test** on the right — the
two columns sized independently, so one can run longer than the other.
Below that, full width: **Events**, **SNMP Devices**, and **DHCP
History**, in that order.

### Network Health

Seven rows, each a colored dot plus a sparkline and a response time or
status, ordered **bottom to top** as the actual path out of your Mac —
read it that way when something's wrong:

| Row (bottom → top) | What it actually checks |
|---|---|
| Network | Is there an active interface at all, and do we know what it's connected to (Ethernet, or a named Wi-Fi network) |
| Local Router | Ping to your gateway's LAN address — is anything answering one hop away |
| Public IP | Ping to your *own* router's WAN-facing address — tests whether the gateway's internet-facing side is alive (catches a dead modem/ONT the LAN-side check can't see) |
| ISP Edge Router | Ping to whichever traceroute hop you've confirmed as your ISP's own router — "Not confirmed" until you do |
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

### Info

Network name and type, IP address in CIDR notation, router and DNS
server addresses, and your current public IP. On Wi-Fi, a **BSSID** row
also appears — useful on a network with more than one AP, to tell which
one you're actually associated with. The **Known network** / **New
network** line with a "seen N×" count tracks how often NMS has
recognized this router before (by its hardware address, not its name).

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

- **Run Speed Test** measures throughput against a public endpoint —
  roughly 50MB of real data transfer, so it's a manual action, never run
  automatically. Takes about a second on a fast connection.
- **Run Network Quality** (next to the "~50MB per run" label) runs
  Apple's own network quality test for the one signal a plain transfer
  can't produce — responsiveness under load (RPM). Takes 25–40 seconds.

Every run is kept, newest first, as a genuine time series — unlike DHCP
History, a run gets a row even when the numbers are close to the last
one.

### Events

A running log of state *transitions* only — not a stream of every
check. An outage produces one red line when it starts and one green line
when it clears; nothing is logged while things stay the same in either
direction. A fresh install with a healthy network correctly shows
nothing here yet, not an error.

### SNMP Devices

Any switch, access point, or other SNMP-capable device NMS can reach
gets listed with its name, current uptime, and software/firmware
descriptor — a device that unexpectedly restarts (uptime resets) or
changes descriptor (a firmware update) logs an event automatically. Each
row's leading dot is that device's live reachability. **Scan** clears
the list and re-sweeps the subnet from scratch — expect up to 15–20
seconds on a full /24.

Two devices sharing one physical network interface (a common VRRP
setup) are shown as a single entry with both addresses listed, rather
than as two separate devices. SNMP community strings — the read-only
"password" your gear expects — default to `public`; click **Change** to
edit them as a comma-separated list, tried in the order you list them.

### DHCP History

Every time your DHCP lease actually changes — a different server,
address, or timing — NMS records it here, newest first. The newest
entry doubles as your current lease. Each entry is two lines: server and
assigned address on the first, every other parsed field (broadcast,
gateway, DNS, domain, lease/T1/T2 timers, transaction ID) on the second.

### Footer controls

**Refresh** re-reads network state immediately. The camera icon saves a
screenshot of the popover and logs an event naming the file. **Open in
Window** opens the same live data in a separate, resizable window (see
below). **Quit** exits NMS. The small gray line underneath shows the
build hash and the store's on-disk size.

### Open in Window

The popover has a fixed height and can't scroll, so a long Events or
DHCP History list is always cropped to what fits. **Open in Window**
opens the same data in an ordinary, resizable window instead: each
history section scrolls independently in its own box, and a scrollbar
on the right reaches anything taller than the window itself. Both stay
open to the same live state — closing the window doesn't stop
monitoring, and the popover keeps working normally alongside it.

## 4. Usage scenarios

### Scenario A — First time on a new network

1. Open the popover and check **Info** — confirm the router/DNS
   addresses and public IP look right for where you are.
2. Under **Path to Internet**, star the hop that's genuinely your ISP's
   router. This turns "ISP Edge Router" in Network Health from "Not
   confirmed" into a real, monitored check.
3. If you manage the switches/APs here, set the right community string
   and click **Scan**. Anything that answers gets tracked for restarts
   and firmware changes from then on.

### Scenario B — "Is it my Wi-Fi, or is the whole internet down?"

Read Network Health **bottom to top** and find the lowest row that's
failing — that's almost always the real fault, not the highest one:

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
can be your own organization's router, not the actual ISP. If the
suggested hop's hostname doesn't look like an ISP, scroll the hop list
and star the correct one further down instead — Network Health switches
to monitoring that address immediately.

### Scenario D — Watching a specific switch or AP

Set the community string it actually uses, click **Scan** once to find
it, and NMS re-polls it every minute from then on. Watch for an uptime
that resets to zero (an unplanned restart) or a software descriptor that
changes (a firmware upgrade) — both generate an Events entry the moment
they're noticed.

### Scenario E — Recognizing you're on a different network

The **Known network** / **New network** line is keyed on the router's
own hardware address, not its name — so it correctly tells apart your
home network from a similarly-named guest network on the same router,
and recognizes your own network again after leaving and coming back,
even across an interface change (Ethernet to Wi-Fi).

## 5. Reference tables

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
| Traceroute re-run | 10 min | Also re-run after any topology change, and when internet reachability changes either direction |

## 6. Troubleshooting

**`snmpget` unavailable on this macOS version.** Apple removed the
underlying command-line tool. Nothing to fix on your end — SNMP
features are unavailable on this Mac.

**No SNMP devices found.** Either nothing on your subnet answers SNMP
under the current community string(s), or it's mid-scan (15–20s on a
full /24) — check the string under **Change** first.

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
known quirk, not a bug in the data — see the note under the popover
screenshot above.

## 7. What it deliberately won't do

- No push notifications, email, or remote alerting — it's a menu bar
  indicator you glance at, not a monitoring service.
- Watches from this one Mac's point of view only — it can't tell you
  whether a problem is local to this machine or affects the whole
  network.
- Sparklines cover roughly the last 30 checks per layer (about 15
  minutes) — a short-term trend, not a long-term historical dashboard.
  Events remains a recent-activity log, not a trend graph.
- SNMP discovery covers the reachable local subnet only, not
  routed/remote segments.

---

*NMS is a personal macOS utility, not a commercial product.*
