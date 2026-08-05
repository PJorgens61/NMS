# Resolved punchlist items (archived 2026-08-05)

Items checked off `PUNCHLIST.md`'s "Open" section as of 2026-08-05,
moved here to keep that file scannable. Each entry's original reasoning
is preserved verbatim -- this is an archive, not a summary. See
`PUNCHLIST.md` itself for what's still open.

- [x] **Website copy revisions, raised directly (2026-08-04).** **Applied**
  (`website-v2` commit `250d7c7`), lightly polished for grammar/site-voice
  consistency per this entry's own "apply as-is or refine further" note
  ("its own DNS" not "it's own DNS," "Globalping" matching the page's
  existing capitalization, "your Mac" not "your mac"). Verified live in
  the actual rendered page before pushing, not just by eyeballing the
  HTML diff.

  Combined `hop-8` ("swift-programmers") with the standalone "gap"
  section into one tighter section -- new headline, condensed lede
  covering both the modern-tech-stack and Windows-port pitches, five
  bullets instead of six (kept the four factual tech-stack ones, folded
  the two Gap bullets into one "we'd welcome a Windows port... MIT-
  licensed" bullet). Trailing hop-9 (opensource) and the separate FW
  "outside view" gap section (added independently on the iMac's side,
  `f072159`) were unaffected -- confirmed no overlap before applying.

  Path Discovery's lede and all three bullets reworded punchier per the
  queued copy; the diagram embed itself (a separate, unrelated piece of
  work from earlier the same day) was untouched.

  Original queued copy, verbatim as given 2026-08-04:

  **Structural: combine `hop-8` ("swift-programmers", line ~774) with
  "The Gap" section (line ~799) and condense** — two sections making a
  related pitch (built with modern Apple tech / no Windows equivalent
  yet) read as one, tighter section instead of two.

  Headline (currently The Gap's `<h2>`):
  - old: "Windows has a hundred network apps. Mac doesn't have one —
    until now."
  - new: "Windows has lots of network apps — For the Mac it's
    crickets — until now"

  Body copy (replaces/condenses swift-programmers' + Gap's `<p
  class="lede">`s):
  - old (paraphrased combination of both sections' current copy):
    Windows network apps monitor LANs and local servers; SwiftUI/
    SwiftData under the hood; no Windows port.
  - new: "NMS is built for the way that networks work today — WiFi,
    the Internet, SaaS services, Zoom calls. If you prefer to run
    Windows go ahead and port it. It's open source with MIT license.
    Claude can help with that."

  **Path Discovery section (line ~638), lede:**
  - old: "'The ISP' isn't one faceless blob — it's a real chain of
    routers, and Path Discovery draws it. It merges this Mac's own
    outbound trace with reverse traces run from several outside
    vantage points simultaneously (via Globalping, free and
    unauthenticated), so you see where every path converges on the
    same infrastructure, not just your own one-sided view of it."
  - new: "They say the Internet is a 'network of networks'. See for
    yourself."

  **Path Discovery section, bullet 1 (ISP Edge Router confirmation):**
  - old: "Confirms whether the 'ISP Edge Router' hop really is your
    ISP's edge — a majority of outside vantage points agreeing is
    real evidence, not a guess."
  - new: "Finds your true ISP Edge Router even in complex topologies
    using CGNAT or Enterprise WANs"

  **Path Discovery section, bullet 2 (interface DNS names):**
  - old: "Every interface's DNS name and IP address, not just one —
    a single router can answer to more names than you'd expect."
  - new: "ISP routers have lots of interfaces each with it's own DNS
    name. — NMS sorts them out for you."

  **Path Discovery section, bullet 3 (vantage point count):**
  - old: "Vantage points aren't fixed at five, and aren't limited to
    the US — dial the count up or mix in other countries to see your
    path from further away."
  - new: "Path Discovery uses the globalPing server network to
    generate remote Traceroutes to discover the 'backside' info that
    you can't discover directly from your mac."
