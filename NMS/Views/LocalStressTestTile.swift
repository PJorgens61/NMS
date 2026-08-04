import SwiftUI

/// The "Local Stress Test" tile's full content. Packet loss is the
/// headline line (the primary metric — see `PUNCHLIST.md`'s "local Wi-Fi
/// stress test" entry), RTT min/avg/max/stddev and this Mac's own CPU
/// load during the burst (see `CPULoadSampler`) are smaller supporting
/// lines underneath.
///
/// Not Wi-Fi-exclusive, despite the underlying idea starting there — the
/// mechanism (repeatedly ping the local router under load) is identical
/// over Ethernet, and a wired connection can have its own real problems
/// (a marginal cable, a flaky switch port) worth exposing the same way.
/// Gated only on a known router address; "Local," not "Wi-Fi," in the
/// title so it doesn't mislead on an Ethernet-connected Mac.
///
/// Ninth of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry) — reads two view models (`wifiStressTest` for
/// the test itself, `viewModel` only for the router-address gate/isWiFi
/// flag). The confirmation alert's `@State` moved here too — purely
/// local UI state with no reason to live on `ContentView` once this
/// section is its own type. Renders nothing at all when there's no known
/// router address, same "the tile decides its own visibility" pattern
/// `EthernetTile`/`WiFiTile` already use.
struct LocalStressTestTile: View {
    var wifiStressTest: WiFiStressTestViewModel
    var viewModel: NetworkMonitorViewModel

    @State private var isShowingWiFiStressTestConfirmation = false

    var body: some View {
        if let routerAddress = viewModel.currentInterface?.routerAddress {
            let isWiFi = viewModel.currentInterface?.isWiFi == true
            tile(title: "Local Stress Test", fixedHeight: ContentView.tileHeight, trailing: {
                Button(wifiStressTest.isRunning ? "Testing…" : "Run Test") {
                    if wifiStressTest.hasConfirmedBefore {
                        wifiStressTest.run(routerAddress: routerAddress, isWiFi: isWiFi)
                    } else {
                        isShowingWiFiStressTestConfirmation = true
                    }
                }
                .disabled(wifiStressTest.isRunning)
                .accessibilityLabel(wifiStressTest.isRunning ? "Testing" : "Run Local Stress Test")
                .accessibilityHint("Fires many concurrent ping streams at the local router for about 1-2 seconds to check for packet loss under load. Generates real network traffic.")
                .accessibilityIdentifier("wifiStressTest.run")
                // Attached directly to the button, not hoisted to
                // `body` — same established local-attachment pattern
                // `.sheet(isPresented: $isShowingAppleVerboseOutput)`
                // uses on the Apple networkQuality tile's own button.
                .alert("Run Local Stress Test?", isPresented: $isShowingWiFiStressTestConfirmation) {
                    Button("Continue") {
                        wifiStressTest.markConfirmed()
                        wifiStressTest.run(routerAddress: routerAddress, isWiFi: isWiFi)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will generate real network traffic for about 1-2 seconds — continue?")
                }
            }) {
                Text("many concurrent MTU-sized pings, ~1-2s, real traffic")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if wifiStressTest.recentRuns.isEmpty {
                    Text(wifiStressTest.isRunning ? "Testing…" : "No stress test run yet")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else {
                    runRows
                }
                if let error = wifiStressTest.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Every run, newest first — a genuine time series, not deduplicated
    /// against the previous one.
    private var runRows: some View {
        ForEach(wifiStressTest.recentRuns) { run in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(String(format: "%.1f%% loss", run.packetLossPercent))
                        .foregroundStyle(run.packetLossPercent > 0 ? .red : .primary)
                    Spacer()
                    Text(run.testedAt, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                if let min = run.minRTTMs, let avg = run.avgRTTMs, let max = run.maxRTTMs, let stddev = run.stddevRTTMs {
                    Text(String(format: "%.1f/%.1f/%.1f/%.1f ms (min/avg/max/stddev)", min, avg, max, stddev))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let peakCPU = run.peakCPUPercent, let avgCPU = run.avgCPUPercent {
                    Text(String(format: "CPU %.0f%% avg, %.0f%% peak · %d streams", avgCPU, peakCPU, run.streamCount))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                // Attempted send rate, not received -- "how hard did
                // this run actually drive the link," the figure worth
                // watching live on a field test to judge whether a run
                // pushed enough load to be meaningful on the network in
                // front of it. See `WiFiStressTestAggregator.aggregate`'s
                // own comment.
                Text(String(format: "%.0f pkt/s · %.1f Mbps attempted", run.packetsPerSecond, run.megabitsPerSecond))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
