import SwiftUI

#if DEBUG
/// A separate window for debug-only action buttons — raised directly
/// ("we may need more action buttons in nms - i have lots of ideas"),
/// at the exact moment a second one (Path Discovery, alongside the
/// existing Diagnostic Log) was about to get crammed into the main
/// footer bar. Same reasoning `KnownNetworksView`'s own doc comment
/// already gives for pulling something out of the footer/popover: "a
/// dedicated place costs an extra click to reach, but keeps [everything
/// else] from also having to make room for [something] only relevant
/// occasionally" — debug tooling is exactly that, and a footer that
/// grows one button per future debug idea doesn't scale the way one
/// window with a growing button list does.
///
/// A plain `Window`, not a sheet or popover section — matches
/// `KnownNetworksView`/`PreferencesView`'s own established pattern for
/// "content that doesn't belong in the always-visible main window."
struct DebugToolsView: View {
    let diagnosticServer: LocalDiagnosticServer
    let globalpingService: GlobalpingReverseTraceService
    let snapshotStore: SnapshotStore
    let publicIP: PublicIPViewModel
    let traceroute: TracerouteViewModel
    let networkIdentity: NetworkIdentityViewModel
    let wifiSSID: WiFiSSIDViewModel

    /// A human-readable label for *this run's own network* — raised
    /// directly, live field testing across several locations in one
    /// session: "topology display should include the network name for
    /// reference later." Prefers the user's own `KnownNetwork.label` (set
    /// via Known Networks) over the raw SSID, since a label is a
    /// deliberate human choice and the SSID is just whatever the router
    /// happens to broadcast; falls back to the SSID when no label has been
    /// set; `nil` on Ethernet with no label (nothing meaningful to show).
    private var currentNetworkName: String? {
        networkIdentity.currentNetwork?.label ?? wifiSSID.currentSSID
    }

    @State private var isRunningPathDiscovery = false
    @State private var pathDiscoveryError: String?
    /// Re-checked in `.onAppear`, not on every render — a real `stat`
    /// call per `body` evaluation would be wasteful for something that
    /// only ever changes when the user runs a command in Terminal, well
    /// outside this window's own lifecycle.
    @State private var scamperAvailability: ScamperService.ScamperAvailability = .notInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug Tools")
                .font(.headline)

            Text("Local, on-demand diagnostic pages — see each button's tooltip for what it opens.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()

            Button("Diagnostic Log…") {
                Task {
                    if let url = await diagnosticServer.start(snapshotStore: snapshotStore) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .accessibilityLabel("Diagnostic Log")
            .accessibilityHint("Opens a local web page listing recent events and test results, for reviewing a field-testing session. Reload the page to see anything since it opened.")
            .accessibilityIdentifier("debugTools.diagnosticLog")
            .help("Opens a local web page listing recent events and test results, for reviewing a field-testing session. Reload the page to see anything since it opened. Loopback-only, stops itself after 10 minutes idle.")

            Button(isRunningPathDiscovery ? "Running Path Discovery…" : "Path Discovery…") {
                runPathDiscovery()
            }
            .disabled(isRunningPathDiscovery || publicIP.currentIP == nil)
            .accessibilityLabel("Path Discovery")
            .accessibilityHint("Runs a reverse traceroute from several external vantage points back toward this Mac's own public IP, via the free Globalping service, and opens the result as a local web page. Also checks whether any vantage point corroborates the confirmed ISP edge router.")
            .accessibilityIdentifier("debugTools.pathDiscovery")
            .help(tooltip(
                "Runs a reverse traceroute from several external vantage points back toward this Mac's own public IP, and opens the result as a local web page.",
                technical: "Uses Globalping (api.globalping.io), unauthenticated. Also checks whether any vantage point's last hop before reaching this Mac matches the confirmed ISP Edge Router hop in Path to Internet, and records the result there if so."
            ))

            if let pathDiscoveryError {
                Text(pathDiscoveryError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Divider()

            scamperStatusSection

            Spacer()
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 320, alignment: .topLeading)
        .onAppear { scamperAvailability = ScamperService.checkAvailability() }
    }

    /// Setup-status-only, deliberately — see `ScamperService`'s own doc
    /// comment for why there's no "run scamper" button here at all: once
    /// `.ready`, the check itself runs from the *existing* "Path
    /// Discovery…" button above (`runPathDiscovery()`), not a second
    /// trigger. This section exists purely so the one-time setup step
    /// (which NMS deliberately never automates — see `checkAvailability`'s
    /// doc comment) is easy to get right on the first try: a real,
    /// already-detected path handed back with one click, not a command
    /// the user has to adapt themselves for their own Mac's architecture.
    @ViewBuilder
    private var scamperStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scamper (optional)")
                .font(.system(size: 12, weight: .semibold))
            switch scamperAvailability {
            case .notInstalled:
                Text("Not installed — used for a rigorous second opinion on Path Discovery's \u{201c}same device, different interface\u{201d} calls.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                copyCommandButton(label: "Copy Install Command", command: "brew install scamper")
            case .notPrivileged(let path):
                Text("Installed, but needs a one-time setup step before NMS can use it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                copyCommandButton(label: "Copy Setup Command", command: "sudo chown root:wheel \(path) && sudo chmod u+s \(path)")
            case .ready:
                Text("Ready — used automatically by Path Discovery.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .help(tooltip(
            "Scamper is a free, separately-installed tool (not part of NMS) that gives a rigorous second opinion on whether two addresses are really the same router.",
            technical: "GPL-2.0-licensed, invoked as a subprocess only — never bundled or linked, so it never changes NMS's own license. Needs a one-time setuid step Homebrew doesn't set automatically, since it needs the same raw-socket access traceroute gets for free from macOS."
        ))
    }

    private func copyCommandButton(label: String, command: String) -> some View {
        Button(label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        .accessibilityHint("Copies \u{201c}\(command)\u{201d} to the clipboard, to paste into Terminal.")
        .help("Copies: \(command)")
    }

    /// Runs the actual Globalping round trip, then feeds the result both
    /// to the local web page (`LocalDiagnosticServer`) and back into
    /// Path to Internet's own corroboration state
    /// (`SnapshotStore.recordPathDiscoveryRun`) — the whole point raised
    /// alongside the original idea ("the info collected should inform
    /// the path to internet function"), not just a standalone viewer.
    private func runPathDiscovery() {
        guard let target = publicIP.currentIP else { return }
        isRunningPathDiscovery = true
        pathDiscoveryError = nil
        Task {
            defer { isRunningPathDiscovery = false }
            do {
                let measurementID = try await globalpingService.createMeasurement(target: target)
                let rawResults = try await globalpingService.fetchResult(measurementID: measurementID)
                var results = await enrichBacksideHostnames(rawResults)

                // FW as a stable, always-present vantage point alongside
                // Globalping's randomly-drawn pool -- see PJorgens61/NMS#6
                // and PJorgens61/FW#1. Reuses the same `firewallVisibility`
                // flag + `FWClient`/`FWKeychain` exactly as
                // `FirewallVisibilityViewModel.scanNow()` does, no new
                // feature flag. Deliberately not gated on
                // `snapshotStore.isCurrentNetworkHome()` the way port-
                // scanning is -- a trace back to this Mac's current public
                // IP is meaningful from any network, exactly like
                // Globalping's own trace already is. Silently no-ops if FW
                // isn't configured or the trace fails -- a broken/
                // unconfigured FW should never break the Globalping-only
                // path that already works.
                if FeatureFlags.firewallVisibility,
                   let fwClient = FWClient(baseURLString: FeatureFlags.firewallServerURL, token: FWKeychain.token()),
                   let fwResult = try? await FWTraceService.run(client: fwClient, target: target) {
                    results.append(fwResult)
                }

                // Falls back to the persisted `ProviderEdgeRecord` the
                // same way `monitoredHopAddress` itself does (see that
                // property's own doc comment) -- an outage that blanks
                // the live hop shouldn't also lose the device-stem
                // fallback this feeds `reverseTraceCorroborates`.
                let confirmedHostname = traceroute.monitoredHop?.hostname ?? snapshotStore.latestProviderEdge()?.hostname

                var confirmedAddress: String?
                if let address = traceroute.monitoredHopAddress {
                    confirmedAddress = address
                    // Gap-aware -- see `corroboratingSummary`'s own doc
                    // comment: a probe that hit a reply gap right before
                    // its destination is excluded, not counted as a
                    // non-match.
                    let summary = TracerouteViewModel.corroboratingSummary(results, confirmedAddress: address, confirmedHostname: confirmedHostname)
                    snapshotStore.recordPathDiscoveryRun(
                        address: address,
                        probeCount: summary.effectiveProbeCount,
                        corroboratingCount: summary.corroboratingCount,
                        isKnownComplexTopology: TracerouteViewModel.includesConfirmedCGNAT(traceroute.hops)
                    )
                }

                // Scamper's Ally technique, a real second opinion on
                // exactly the "same device, different interface" guess
                // `reverseTraceCorroborates`'s stem fallback makes below
                // -- runs only for the specific candidate addresses that
                // fallback already flagged as a stem match, not for an
                // exact match (nothing to double-check) or a genuine
                // non-match (not in question). No-ops entirely when
                // scamper isn't `.ready` -- see `ScamperService`'s own
                // doc comment for why this is the one place it's ever
                // triggered from, no separate button.
                var scamperVerdicts: [String: Bool] = [:]
                if case .ready(let scamperPath) = ScamperService.checkAvailability(), let confirmedAddress {
                    for probe in results {
                        guard let hop = TracerouteViewModel.lastHopBeforeDestination(probe.hops, destination: probe.resolvedAddress),
                              let candidateAddress = hop.address,
                              candidateAddress != confirmedAddress,
                              scamperVerdicts[candidateAddress] == nil
                        else { continue }
                        let isStemMatch = TracerouteViewModel.reverseTraceCorroborates(
                            probe.hops,
                            destination: probe.resolvedAddress,
                            confirmedAddress: confirmedAddress,
                            confirmedHostname: confirmedHostname
                        )
                        guard isStemMatch,
                              let verdict = try? ScamperService.confirmAlias(confirmedAddress, candidateAddress, scamperPath: scamperPath)
                        else { continue }
                        scamperVerdicts[candidateAddress] = verdict
                    }
                }

                // The focus, raised directly, is the ISP edge specifically
                // -- so only look up siblings for whichever device stem(s)
                // actually show up as an edge candidate (the last real hop
                // before each probe's own destination), not every device
                // in every probe's full path.
                let edgeStems = Set(results.compactMap { probe -> String? in
                    guard let hostname = TracerouteViewModel.lastHopBeforeDestination(probe.hops, destination: probe.resolvedAddress)?.hostname else { return nil }
                    return GlobalpingReverseTraceService.deviceStem(fromHostname: hostname)
                })
                let siblingAddresses = await lookUpSiblingAddresses(deviceStems: edgeStems)

                // Every hostname seen anywhere in this run -- both sides
                // of the topology diagram (this Mac's own frontside trace
                // and every probe's backside hops) -- gathered once and
                // sent to Hoiho in a single bulk call, matching its own
                // "use POST for bulk requests" guidance. `try?`: a Hoiho
                // outage or timeout should never break the Path Discovery
                // page that already worked fine before this existed, it
                // should just render without location hints, same
                // tolerance `lookUpSiblingAddresses`'s own dig lookups get.
                let allHostnames = Set(results.flatMap { $0.hops.compactMap(\.hostname) } + traceroute.hops.compactMap(\.hostname))
                let geoInfo = (try? await HoihoService.lookup(hostnames: Array(allHostnames))) ?? [:]
                let geoHints = geoInfo.compactMapValues(\.displayLabel)

                if let url = await diagnosticServer.showReverseTrace(
                    target: target,
                    results: results,
                    confirmedAddress: confirmedAddress,
                    siblingAddresses: siblingAddresses,
                    frontsideHops: traceroute.hops,
                    networkName: currentNetworkName,
                    geoHints: geoHints,
                    scamperVerdicts: scamperVerdicts
                ) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                pathDiscoveryError = "Path Discovery failed: \(error.localizedDescription)"
            }
        }
    }

    /// A local reverse-DNS fallback for backside hops Globalping itself
    /// left unresolved -- a confirmed gap, not a guess: `grep` across
    /// `TopologyBuilder.swift`/this file showed `ReverseDNSService` was
    /// never called anywhere in the Path Discovery flow, so a hop
    /// Globalping's own `resolvedHostname` left `nil` showed as a bare IP
    /// in the diagram permanently, even when a plain local `dig -x`/
    /// `getnameinfo` against it would resolve fine. Raised directly
    /// ("topology display doesn't have a dns name for every hop. is it
    /// checking?" / "nms topology discovery should check dns for every ip
    /// ... to reconcile and combine them into logical routers") --
    /// `TopologyBuilder` already merges hops sharing a resolved hostname
    /// into one logical router, so filling in more real hostnames here is
    /// what actually improves that merge, not a separate step.
    ///
    /// Same blocking-call-off-the-cooperative-pool pattern as
    /// `lookUpSiblingAddresses` below -- `ReverseDNSService.hostname(for:)`
    /// blocks its calling thread on `getnameinfo` (bounded to 2s via its
    /// own semaphore/timeout), so every lookup here runs inside one
    /// `DispatchQueue.global` dispatch, never called directly inside this
    /// `Task`.
    private func enrichBacksideHostnames(_ results: [GlobalpingReverseTraceService.ProbeTraceResult]) async -> [GlobalpingReverseTraceService.ProbeTraceResult] {
        let missingAddresses = Set(results.flatMap(\.hops).compactMap { hop -> String? in
            guard hop.hostname == nil else { return nil }
            return hop.address
        })
        guard !missingAddresses.isEmpty else { return results }

        let resolved: [String: String] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let service = ReverseDNSService()
                var found: [String: String] = [:]
                for address in missingAddresses {
                    if let hostname = service.hostname(for: address) {
                        found[address] = hostname
                    }
                }
                continuation.resume(returning: found)
            }
        }
        guard !resolved.isEmpty else { return results }

        return results.map { probe in
            let enrichedHops = probe.hops.map { hop -> GlobalpingReverseTraceService.ProbeTraceResult.Hop in
                guard hop.hostname == nil, let address = hop.address, let hostname = resolved[address] else { return hop }
                return GlobalpingReverseTraceService.ProbeTraceResult.Hop(hopNumber: hop.hopNumber, address: hop.address, hostname: hostname, roundTripTimesMs: hop.roundTripTimesMs)
            }
            return GlobalpingReverseTraceService.ProbeTraceResult(city: probe.city, country: probe.country, network: probe.network, asn: probe.asn, status: probe.status, resolvedAddress: probe.resolvedAddress, hops: enrichedHops)
        }
    }

    /// Supplementary `dig` lookups for a device stem's own bare name and
    /// its `lo0.` prefix — the two patterns confirmed live (2026-08-04)
    /// to reliably resolve for a real device, on top of whatever sibling
    /// addresses the results page finds just by cross-referencing hops
    /// already present in this same run's own data. Deliberately not
    /// guessing numbered interfaces (e.g. `305.ae0...`) here — that's
    /// only trustworthy when already observed as a real hop somewhere,
    /// not blindly enumerable (see `PUNCHLIST.md`'s alias-resolution
    /// entry).
    ///
    /// Runs off `DispatchQueue.global`, not directly inside this `Task`
    /// — `DDNSResolutionService.resolve` blocks its calling thread on a
    /// subprocess (`Process.waitUntilExit()`), and calling that straight
    /// from a plain `Task { ... }` risks blocking one of Swift
    /// Concurrency's own small cooperative-pool threads. Same "dispatch
    /// the blocking call to a GCD queue instead" pattern
    /// `DDNSViewModel.checkAll()` already uses for the exact same
    /// service, bridged back into `async` with a checked continuation.
    private func lookUpSiblingAddresses(deviceStems: Set<String>) async -> [String: [String: String]] {
        guard !deviceStems.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let service = DDNSResolutionService()
                var found: [String: [String: String]] = [:]
                for stem in deviceStems {
                    var entries: [String: String] = [:]
                    for candidate in [stem, "lo0.\(stem)"] {
                        if case .success(let address) = service.resolve(hostname: candidate) {
                            entries[candidate] = address
                        }
                    }
                    if !entries.isEmpty { found[stem] = entries }
                }
                continuation.resume(returning: found)
            }
        }
    }
}
#endif
