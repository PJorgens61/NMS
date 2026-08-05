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
                let results = try await globalpingService.fetchResult(measurementID: measurementID)

                var confirmedAddress: String?
                if let address = traceroute.monitoredHopAddress {
                    confirmedAddress = address
                    let corroboratingCount = results.filter {
                        TracerouteViewModel.reverseTraceCorroborates($0.hops, destination: $0.resolvedAddress, confirmedAddress: address)
                    }.count
                    snapshotStore.recordPathDiscoveryRun(address: address, probeCount: results.count, corroboratingCount: corroboratingCount)
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

                if let url = await diagnosticServer.start(
                    reverseTraceTarget: target,
                    results: results,
                    confirmedAddress: confirmedAddress,
                    siblingAddresses: siblingAddresses
                ) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                pathDiscoveryError = "Path Discovery failed: \(error.localizedDescription)"
            }
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
