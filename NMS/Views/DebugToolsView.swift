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

                if let confirmedAddress = traceroute.monitoredHopAddress {
                    let corroboratingCount = results.filter {
                        TracerouteViewModel.reverseTraceCorroborates($0.hops, destination: $0.resolvedAddress, confirmedAddress: confirmedAddress)
                    }.count
                    snapshotStore.recordPathDiscoveryRun(address: confirmedAddress, probeCount: results.count, corroboratingCount: corroboratingCount)
                }

                if let url = await diagnosticServer.start(reverseTraceTarget: target, results: results) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                pathDiscoveryError = "Path Discovery failed: \(error.localizedDescription)"
            }
        }
    }
}
#endif
