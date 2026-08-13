import Foundation
import AppKit

/// Runs a Globalping reverse-trace and opens the result as a local web
/// page — ported directly from the now-deleted `DebugToolsView
/// .runPathDiscovery()` (popover conversion, Phase 5), unchanged in
/// substance, just moved out of a `#if DEBUG`-only window's view body
/// into its own always-available type the popover's Run Test ▾ menu can
/// call. Extracted into its own service (not inlined into
/// `MenuBarView`) because of its real size and dependency count — the
/// same "pull complex logic out of a view into its own type" convention
/// this codebase already uses throughout (see `PUNCHLIST.md`'s
/// `ContentView` fan-in entries).
@MainActor
@Observable
final class PathDiscoveryRunner {
    private(set) var isRunning = false
    private(set) var lastError: String?

    private let globalpingService: GlobalpingReverseTraceService
    private let diagnosticServer: LocalDiagnosticServer
    private let snapshotStore: SnapshotStore
    private let publicIP: PublicIPViewModel
    private let traceroute: TracerouteViewModel
    private let networkIdentity: NetworkIdentityViewModel
    private let wifiSSID: WiFiSSIDViewModel

    init(
        globalpingService: GlobalpingReverseTraceService,
        diagnosticServer: LocalDiagnosticServer,
        snapshotStore: SnapshotStore,
        publicIP: PublicIPViewModel,
        traceroute: TracerouteViewModel,
        networkIdentity: NetworkIdentityViewModel,
        wifiSSID: WiFiSSIDViewModel
    ) {
        self.globalpingService = globalpingService
        self.diagnosticServer = diagnosticServer
        self.snapshotStore = snapshotStore
        self.publicIP = publicIP
        self.traceroute = traceroute
        self.networkIdentity = networkIdentity
        self.wifiSSID = wifiSSID
    }

    /// A human-readable label for *this run's own network* — prefers the
    /// user's own `KnownNetwork.label` over the raw SSID, falls back to
    /// the SSID when no label has been set, `nil` on Ethernet with no
    /// label.
    private var currentNetworkName: String? {
        networkIdentity.currentNetwork?.label ?? wifiSSID.currentSSID
    }

    /// Runs the actual Globalping round trip, then feeds the result both
    /// to the local web page (`LocalDiagnosticServer`) and back into
    /// Path to Internet's own corroboration state
    /// (`SnapshotStore.recordPathDiscoveryRun`).
    func run() {
        guard let target = publicIP.currentIP, !isRunning else { return }
        isRunning = true
        lastError = nil
        Task {
            defer { isRunning = false }
            do {
                let measurementID = try await globalpingService.createMeasurement(target: target)
                let rawResults = try await globalpingService.fetchResult(measurementID: measurementID)
                var results = await enrichBacksideHostnames(rawResults)

                // FW as a stable, always-present vantage point alongside
                // Globalping's randomly-drawn pool -- see PJorgens61/NMS#6
                // and PJorgens61/FW#1. Reuses the same `firewallVisibility`
                // flag + `FWClient`/`FWKeychain` exactly as
                // `FirewallVisibilityViewModel.scanNow()` does, no new
                // feature flag. Silently no-ops if FW isn't configured or
                // the trace fails -- a broken/unconfigured FW should never
                // break the Globalping-only path that already works.
                if FeatureFlags.firewallVisibility,
                   let fwClient = FWClient(baseURLString: FeatureFlags.firewallServerURL, token: FWKeychain.token()),
                   let fwResult = try? await FWTraceService.run(client: fwClient, target: target) {
                    results.append(fwResult)
                }

                // Falls back to the persisted `ProviderEdgeRecord` the
                // same way `monitoredHopAddress` itself does -- an outage
                // that blanks the live hop shouldn't also lose the
                // device-stem fallback this feeds
                // `reverseTraceCorroborates`.
                let confirmedHostname = traceroute.monitoredHop?.hostname ?? snapshotStore.latestProviderEdge()?.hostname

                var confirmedAddress: String?
                if let address = traceroute.monitoredHopAddress {
                    confirmedAddress = address
                    let summary = TracerouteViewModel.corroboratingSummary(results, confirmedAddress: address, confirmedHostname: confirmedHostname)
                    snapshotStore.recordPathDiscoveryRun(
                        address: address,
                        probeCount: summary.effectiveProbeCount,
                        corroboratingCount: summary.corroboratingCount,
                        isKnownComplexTopology: TracerouteViewModel.includesConfirmedCGNAT(traceroute.hops)
                    )
                }

                // Scamper's Ally technique, a real second opinion on the
                // "same device, different interface" guess
                // `reverseTraceCorroborates`'s stem fallback makes below
                // -- runs only for candidate addresses that fallback
                // already flagged as a stem match. No-ops entirely when
                // scamper isn't `.ready`.
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

                // The focus is the ISP edge specifically -- so only look
                // up siblings for device stem(s) that actually show up as
                // an edge candidate, not every device in every probe's
                // full path.
                let edgeStems = Set(results.compactMap { probe -> String? in
                    guard let hostname = TracerouteViewModel.lastHopBeforeDestination(probe.hops, destination: probe.resolvedAddress)?.hostname else { return nil }
                    return GlobalpingReverseTraceService.deviceStem(fromHostname: hostname)
                })
                let siblingAddresses = await lookUpSiblingAddresses(deviceStems: edgeStems)

                // Every hostname seen anywhere in this run, sent to Hoiho
                // in one bulk call. `try?`: a Hoiho outage should never
                // break the page that already worked fine before this
                // existed.
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
                lastError = "Path Discovery failed: \(error.localizedDescription)"
            }
        }
    }

    /// A local reverse-DNS fallback for backside hops Globalping itself
    /// left unresolved. Blocking calls dispatched off the cooperative
    /// pool, same pattern `lookUpSiblingAddresses` below uses.
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
    /// its `lo0.` prefix. Runs off `DispatchQueue.global`, not directly
    /// inside this `Task` -- `DDNSResolutionService.resolve` blocks its
    /// calling thread on a subprocess.
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
