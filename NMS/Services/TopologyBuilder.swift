import Foundation

#if DEBUG
/// Merges frontside (this Mac's own outbound trace, `TracerouteViewModel
/// .hops`) and backside (Path Discovery's external reverse traces,
/// `GlobalpingReverseTraceService.ProbeTraceResult`) into one layered
/// picture of the topology between this Mac and the public internet —
/// raised directly, with the exact layering algorithm specified: "bottom
/// line is my network router - 1 hop from nms... second line is my isp
/// edge router - 2 hops... keep expanding upwards until the 5 paths
/// diverge... next line is the 5 remote traceroute servers."
///
/// Pure and `nonisolated static` throughout, same testability posture as
/// `TracerouteViewModel.corroboratingSummary` — no network calls, no
/// SwiftData, just the hop/probe data already collected elsewhere. Any
/// forward-DNS "sibling" IPs (the extra known interfaces for a device) are
/// passed in already-resolved via `siblingAddresses`, not looked up here —
/// same shape and source as `LocalDiagnosticServer.renderReverseTracePage`'s
/// own parameter (`DebugToolsView.lookUpSiblingAddresses`'s result).
///
/// **Majority-tolerant divergence**: a single disagreeing probe among
/// several agreeing ones doesn't discard the tier — raised directly, live,
/// against real data: 4 of 5 vantage points agreeing on the ISP edge is
/// the single most useful finding Path Discovery produces, and an earlier,
/// stricter version of this ("any disagreement ends the shared picture")
/// threw that away entirely the moment one probe diverged, exactly the
/// real Ashburn case this whole feature grew out of. A tier with a true
/// majority (more than half of the sources with data at that tier) still
/// gets drawn *with* its minority node(s) shown too — real information,
/// not hidden — but only the majority's own sources keep expanding
/// outward; the minority's sources attach directly to their own node at
/// that tier instead of continuing. A tier with no clean majority (an
/// even split, or three-plus-way fragmentation) stops expanding there
/// entirely, same as before, since there's no real "trunk" left to follow.
enum TopologyBuilder {
    /// One IP address a node was observed under, with every hostname
    /// resolved for *that specific address* — raised directly ("list
    /// both dns names and ip addresses for each interface", then "list
    /// all dns names"): a single address can genuinely have more than one
    /// name (different probes' own reverse-DNS disagreeing, or a forward-
    /// DNS sibling lookup surfacing an alias the reverse lookup didn't),
    /// and a device's several interfaces don't all share one name either
    /// — each address keeps every name seen for it, not just the first.
    struct Interface: Equatable, Hashable {
        var hostnames: Set<String>
        var address: String
    }

    /// One merged device at a given hop-distance from this Mac. Multiple
    /// probes (or frontside + backside) landing on the same device — same
    /// hostname stem, or the same raw address when no hostname is
    /// available — collapse into one node listing every interface it was
    /// seen under. This is the "interface" concept raised directly: a
    /// router can legitimately have a different near-side and far-side
    /// address, and this is where both live on one node instead of two.
    struct Node: Equatable {
        var label: String
        var interfaces: [Interface]
        /// How many of the backside probes contributed to this node —
        /// frontside's own hop doesn't count toward this, it's folded into
        /// `interfaces` directly (see `mergeFrontside`).
        var sourceCount: Int
    }

    struct Tier: Equatable {
        var distanceFromNMS: Int
        var nodes: [Node]
    }

    struct Source: Equatable {
        var label: String
        var connectsToDistance: Int
    }

    /// Fill/stroke/text colors for the diagram's three visually distinct
    /// node categories — raised directly ("can we change colors for the
    /// traceroute hosts and the nms mac to help differentiate them
    /// visually? 3 colors?"): this Mac itself, the path/hop devices in
    /// between, and the external vantage points (sources) Path Discovery
    /// traces from. `Decodable` and defaulted rather than hardcoded
    /// inline in `renderMermaid` so `LocalDiagnosticServer` can read
    /// overrides from `topology-colors.json` at request time (same
    /// runtime-patchable pattern as `style.css`/`mermaid-init.js` — "can
    /// the configuration options be broken out into a file..."), while
    /// `TopologyBuilder` itself stays pure/file-I/O-free and every
    /// existing test keeps working unchanged against `.default`.
    struct NodeColors: Equatable, Decodable {
        struct Style: Equatable, Decodable { var fill: String; var stroke: String; var text: String }
        var thisMac: Style
        var hop: Style
        var source: Style

        static let `default` = NodeColors(
            thisMac: Style(fill: "#d1fae5", stroke: "#059669", text: "#064e3b"),
            hop: Style(fill: "#dbeafe", stroke: "#2563eb", text: "#1e3a5f"),
            source: Style(fill: "#fef3c7", stroke: "#d97706", text: "#78350f")
        )
    }

    /// Builds the layered tiers plus the source nodes that collapse onto
    /// wherever the paths actually diverged. `distanceFromNMS` starts at 0
    /// (this Mac itself) — 1 is the frontside-only home router, 2 is the
    /// ISP edge (frontside hop 2 merged with every backside probe's last
    /// real hop before its own destination), and each distance beyond that
    /// is one more hop further out on the backside data alone, until the
    /// probes stop agreeing.
    static func build(
        frontsideHops: [TracerouteHop],
        backsideResults: [GlobalpingReverseTraceService.ProbeTraceResult],
        siblingAddresses: [String: [String: String]]
    ) -> (tiers: [Tier], sources: [Source]) {
        var tiers: [Tier] = [Tier(distanceFromNMS: 0, nodes: [Node(label: "This Mac", interfaces: [], sourceCount: 0)])]

        if let hop1 = frontsideHops.first(where: { $0.hopNumber == 1 }), let address = hop1.address {
            tiers.append(Tier(distanceFromNMS: 1, nodes: [
                singleNode(address: address, hostname: hop1.hostname, siblingAddresses: siblingAddresses)
            ]))
        }

        // Anchor every tier's index math to where each probe's own
        // destination (this Mac's public IP) actually sits in its hop
        // array — same lookup `hasGapBeforeDestination` already uses, just
        // generalized to every distance instead of only the one right
        // before it.
        let destinationIndices: [Int?] = backsideResults.map { probe in
            guard let destination = probe.resolvedAddress else { return nil }
            return probe.hops.firstIndex(where: { $0.address == destination })
        }

        // Which sources are still following the shared trunk -- narrows
        // whenever a tier splits into a majority and a minority, since
        // only the majority's own sources keep expanding outward past
        // that point.
        var activeSourceIndices = Set(backsideResults.indices)
        var connectDistance: [Int: Int] = [:]

        var distance = 2
        var lastAppendedDistance = tiers.last!.distanceFromNMS
        while true {
            var entries: [(hop: GlobalpingReverseTraceService.ProbeTraceResult.Hop, sourceIndex: Int)] = []
            for i in activeSourceIndices {
                guard let destinationIndex = destinationIndices[i] else { continue }
                let hopIndex = destinationIndex - (distance - 1)
                let probe = backsideResults[i]
                guard hopIndex >= 0, hopIndex < probe.hops.count else { continue }
                let hop = probe.hops[hopIndex]
                // A reply gap at this one tier isn't a fork -- it just
                // means this probe has no data here, the same tolerance
                // `hasGapBeforeDestination` already established for the
                // one tier it covered.
                guard hop.address != nil else { continue }
                entries.append((hop, i))
            }

            // Frontside only ever contributes at distance 2 (the ISP
            // edge) -- matching the spec's own wording exactly, and
            // frontside hops beyond it are rarely available from behind a
            // home NAT anyway.
            let frontsideHop = distance == 2 ? frontsideHops.first(where: { $0.hopNumber == 2 }) : nil

            guard !entries.isEmpty || frontsideHop != nil else { break }

            var groups = mergeIntoGroups(entries, siblingAddresses: siblingAddresses)
            if let frontsideHop, let address = frontsideHop.address {
                mergeFrontside(address: address, hostname: frontsideHop.hostname, into: &groups, siblingAddresses: siblingAddresses)
            }
            groups.sort { $0.node.label < $1.node.label }

            tiers.append(Tier(distanceFromNMS: distance, nodes: groups.map(\.node)))
            lastAppendedDistance = distance

            if groups.count == 1 {
                distance += 1
                continue
            }

            let totalSources = groups.reduce(0) { $0 + $1.sourceIndices.count }
            if totalSources > 0, let majority = groups.max(by: { $0.sourceIndices.count < $1.sourceIndices.count }),
               majority.sourceIndices.count * 2 > totalSources {
                for group in groups where group.sourceIndices != majority.sourceIndices {
                    for i in group.sourceIndices { connectDistance[i] = distance }
                }
                activeSourceIndices = majority.sourceIndices
                distance += 1
                continue
            }

            // No clean majority -- nothing left to call "the shared
            // trunk." Every source visible at this tier attaches directly
            // to its own node here instead of continuing further.
            for group in groups {
                for i in group.sourceIndices { connectDistance[i] = distance }
            }
            break
        }

        for i in backsideResults.indices where connectDistance[i] == nil {
            connectDistance[i] = lastAppendedDistance
        }

        let sources = backsideResults.enumerated().map { i, probe in
            Source(label: sourceLabel(probe), connectsToDistance: connectDistance[i] ?? lastAppendedDistance)
        }
        return (tiers, sources)
    }

    /// Renders `tiers`/`sources` as literal Mermaid `flowchart` text —
    /// bottom-to-top (`BT`), matching the layering's own "bottom line /
    /// keep expanding upwards" framing directly. A separate, equally pure
    /// function from `build` so the merge logic and the text format can be
    /// tested independently.
    ///
    /// Two things raised directly after actually looking at a real
    /// rendered diagram:
    /// - **Sources belong on the top row.** A `BT` layout places an edge's
    ///   *origin* toward the bottom and its *destination* toward the top —
    ///   the tier-chain edges below already follow that (`t0 --> t1 --> t2`,
    ///   NMS at the bottom), but the source edges had it backwards
    ///   (`source --> tier`, which pushed sources toward the bottom
    ///   instead). Flipped to `tier --> source` so sources render at top.
    /// - **Plain lines, not arrows** — `---` instead of `-->` throughout.
    ///   Still directional under the hood for Mermaid's own layout
    ///   purposes (the A/B order above still matters), just rendered
    ///   without an arrowhead.
    static func renderMermaid(tiers: [Tier], sources: [Source], colors: NodeColors = .default) -> String {
        func nodeID(_ distance: Int, _ index: Int) -> String { "t\(distance)n\(index)" }
        func classDefLine(_ name: String, _ style: NodeColors.Style) -> String {
            "  classDef \(name) fill:\(style.fill),stroke:\(style.stroke),color:\(style.text),stroke-width:2px"
        }

        var lines = ["flowchart BT"]
        lines.append(classDefLine("thisMac", colors.thisMac))
        lines.append(classDefLine("hop", colors.hop))
        lines.append(classDefLine("source", colors.source))

        for tier in tiers {
            for (index, node) in tier.nodes.enumerated() {
                let id = nodeID(tier.distanceFromNMS, index)
                lines.append("  \(id)[\"\(nodeText(node))\"]")
                lines.append("  class \(id) \(tier.distanceFromNMS == 0 ? "thisMac" : "hop")")
            }
        }

        for (lower, upper) in zip(tiers, tiers.dropFirst()) {
            for lowerIndex in lower.nodes.indices {
                for upperIndex in upper.nodes.indices {
                    lines.append("  \(nodeID(lower.distanceFromNMS, lowerIndex)) --- \(nodeID(upper.distanceFromNMS, upperIndex))")
                }
            }
        }

        for (index, source) in sources.enumerated() {
            let sourceID = "src\(index)"
            lines.append("  \(sourceID)[\"\(mermaidEscape(source.label))\"]")
            lines.append("  class \(sourceID) source")
            if tiers.contains(where: { $0.distanceFromNMS == source.connectsToDistance }) {
                lines.append("  \(nodeID(source.connectsToDistance, 0)) --- \(sourceID)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// One row per name-address combination — raised directly ("i think
    /// we need rows with name-ip for all combos"): an interface with two
    /// dns names and one address gets two rows, not one row with both
    /// names crammed together, matching the same "one row per hostname-
    /// address pair" shape the "Known addresses near the edge" table
    /// already uses elsewhere on this page. An interface with no known
    /// name at all still gets one row, just the bare address. Skips
    /// repeating the interface section entirely when there's exactly one
    /// interface, unnamed, already identical to the node's own label (the
    /// common "plain address, no stem resolved" case) — nothing new to
    /// say twice.
    private static func nodeText(_ node: Node) -> String {
        if node.interfaces.isEmpty { return mermaidEscape(node.label) }
        if node.interfaces.count == 1, node.interfaces[0].hostnames.isEmpty, node.interfaces[0].address == node.label {
            return mermaidEscape(node.label)
        }
        var rows: [String] = []
        for iface in node.interfaces.sorted(by: { $0.address < $1.address }) {
            if iface.hostnames.isEmpty {
                rows.append(iface.address)
            } else {
                for hostname in iface.hostnames.sorted() {
                    rows.append("\(hostname): \(iface.address)")
                }
            }
        }
        return ([node.label] + rows).map(mermaidEscape).joined(separator: "<br/>")
    }

    // MARK: - Merging

    private static func singleNode(address: String, hostname: String?, siblingAddresses: [String: [String: String]]) -> Node {
        let stem = hostname.flatMap { GlobalpingReverseTraceService.deviceStem(fromHostname: $0) }
        var interfaceHostnames: [String: Set<String>] = [:]
        addInterfaceHostname(hostname, forAddress: address, in: &interfaceHostnames)
        if let stem, let siblings = siblingAddresses[stem] {
            for (siblingHostname, siblingAddress) in siblings { addInterfaceHostname(siblingHostname, forAddress: siblingAddress, in: &interfaceHostnames) }
        }
        return Node(label: stem ?? address, interfaces: makeInterfaces(interfaceHostnames), sourceCount: 0)
    }

    /// Groups backside entries at one tier by device identity — a
    /// hostname's stem (`GlobalpingReverseTraceService.deviceStem`) when
    /// resolvable, otherwise the raw address itself. More than one group
    /// means the probes disagree on what's here; `build` decides from the
    /// returned `sourceIndices` whether that's a tolerable minority or a
    /// genuine fork. Returns the source indices alongside each node
    /// (rather than folding them into `Node` itself) since that's only
    /// needed internally for the majority decision, not part of the
    /// diagram's own public shape.
    private static func mergeIntoGroups(
        _ entries: [(hop: GlobalpingReverseTraceService.ProbeTraceResult.Hop, sourceIndex: Int)],
        siblingAddresses: [String: [String: String]]
    ) -> [(node: Node, sourceIndices: Set<Int>)] {
        struct Group { var interfaceHostnames: [String: Set<String>] = [:]; var stem: String?; var sourceIndices: Set<Int> = [] }
        var groups: [String: Group] = [:]

        for entry in entries {
            guard let address = entry.hop.address else { continue }
            let stem = entry.hop.hostname.flatMap { GlobalpingReverseTraceService.deviceStem(fromHostname: $0) }
            let key = stem ?? address
            var group = groups[key] ?? Group()
            addInterfaceHostname(entry.hop.hostname, forAddress: address, in: &group.interfaceHostnames)
            if group.stem == nil { group.stem = stem }
            group.sourceIndices.insert(entry.sourceIndex)
            groups[key] = group
        }

        return groups.values.map { group in
            var interfaceHostnames = group.interfaceHostnames
            if let stem = group.stem, let siblings = siblingAddresses[stem] {
                for (siblingHostname, siblingAddress) in siblings {
                    addInterfaceHostname(siblingHostname, forAddress: siblingAddress, in: &interfaceHostnames)
                }
            }
            let node = Node(
                label: group.stem ?? (interfaceHostnames.keys.sorted().first ?? "unknown"),
                interfaces: makeInterfaces(interfaceHostnames),
                sourceCount: group.sourceIndices.count
            )
            return (node, group.sourceIndices)
        }
    }

    /// Folds the frontside hop into whichever backside-derived node
    /// already shares its identity (same stem, or the exact same
    /// address) — this is the "interface" merge in the other direction:
    /// frontside's near-side view of the ISP edge joining backside's
    /// far-side view of the same physical device. If nothing already
    /// matches, it becomes its own node with an empty `sourceIndices` --
    /// real information (frontside saw a device no backside probe
    /// reached), not dropped, but it can never itself be "the majority"
    /// since nothing backs it.
    private static func mergeFrontside(address: String, hostname: String?, into groups: inout [(node: Node, sourceIndices: Set<Int>)], siblingAddresses: [String: [String: String]]) {
        let stem = hostname.flatMap { GlobalpingReverseTraceService.deviceStem(fromHostname: $0) }
        if let stem, let index = groups.firstIndex(where: { $0.node.label == stem }) {
            addInterface(hostname: hostname, address: address, to: &groups[index].node)
            return
        }
        if let index = groups.firstIndex(where: { $0.node.interfaces.contains(where: { $0.address == address }) }) {
            addInterface(hostname: hostname, address: address, to: &groups[index].node)
            return
        }
        var interfaceHostnames: [String: Set<String>] = [:]
        addInterfaceHostname(hostname, forAddress: address, in: &interfaceHostnames)
        if let stem, let siblings = siblingAddresses[stem] {
            for (siblingHostname, siblingAddress) in siblings { addInterfaceHostname(siblingHostname, forAddress: siblingAddress, in: &interfaceHostnames) }
        }
        groups.append((Node(label: stem ?? address, interfaces: makeInterfaces(interfaceHostnames), sourceCount: 0), []))
    }

    private static func addInterface(hostname: String?, address: String, to node: inout Node) {
        if let index = node.interfaces.firstIndex(where: { $0.address == address }) {
            if let hostname { node.interfaces[index].hostnames.insert(hostname) }
        } else {
            node.interfaces.append(Interface(hostnames: Set(hostname.map { [$0] } ?? []), address: address))
        }
    }

    /// Accumulates every distinct hostname seen for a given address —
    /// raised directly ("can each router node list all dns names...") —
    /// rather than keeping only the first one found. A `nil` hostname
    /// (nothing resolved for this particular sighting) is a no-op, not a
    /// reason to blank out names a different sighting of the same address
    /// already contributed.
    private static func addInterfaceHostname(_ hostname: String?, forAddress address: String, in map: inout [String: Set<String>]) {
        guard let hostname else {
            if map[address] == nil { map[address] = [] }
            return
        }
        map[address, default: []].insert(hostname)
    }

    private static func makeInterfaces(_ map: [String: Set<String>]) -> [Interface] {
        map.map { Interface(hostnames: $0.value, address: $0.key) }
    }

    private static func sourceLabel(_ probe: GlobalpingReverseTraceService.ProbeTraceResult) -> String {
        let location = [probe.city, probe.country].compactMap { $0 }.joined(separator: ", ")
        let network = [probe.network, probe.asn.map { "ASN \($0)" }].compactMap { $0 }.joined(separator: " · ")
        return [location, network].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func mermaidEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
    }
}
#endif
