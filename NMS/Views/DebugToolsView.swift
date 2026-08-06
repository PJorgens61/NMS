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

            Spacer()
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 200, alignment: .topLeading)
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
                let results = await enrichBacksideHostnames(rawResults)

                var confirmedAddress: String?
                if let address = traceroute.monitoredHopAddress {
                    confirmedAddress = address
                    // Gap-aware -- see `corroboratingSummary`'s own doc
                    // comment: a probe that hit a reply gap right before
                    // its destination is excluded, not counted as a
                    // non-match.
                    let summary = TracerouteViewModel.corroboratingSummary(results, confirmedAddress: address)
                    snapshotStore.recordPathDiscoveryRun(
                        address: address,
                        probeCount: summary.effectiveProbeCount,
                        corroboratingCount: summary.corroboratingCount,
                        isKnownComplexTopology: TracerouteViewModel.includesConfirmedCGNAT(traceroute.hops)
                    )
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

                if let url = await diagnosticServer.showReverseTrace(
                    target: target,
                    results: results,
                    confirmedAddress: confirmedAddress,
                    siblingAddresses: siblingAddresses,
                    frontsideHops: traceroute.hops,
                    networkName: currentNetworkName
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
