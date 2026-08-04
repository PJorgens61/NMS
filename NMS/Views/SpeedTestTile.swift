import SwiftUI

/// The "Speed Test" tile's full content: the data-cost note, any error,
/// then the recent-runs list. Cloudflare-only — Apple's `networkQuality`
/// has its own tile (`AppleNetworkQualityTile`) once it stopped sharing
/// `isRunning`/`lastError` display state that could belong to either
/// test (see `NetworkQualityViewModel.runningSource`). `lastError` is
/// still one shared property underneath — the two tests still can't run
/// concurrently — but since only one can ever be in flight at a time,
/// showing it under whichever tile's test actually produced it is
/// unambiguous in practice, not a display bug waiting to happen.
///
/// Seventh of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry) — holds only the one view model it actually
/// reads.
struct SpeedTestTile: View {
    var networkQuality: NetworkQualityViewModel

    var body: some View {
        tile(title: "Speed Test", fixedHeight: ContentView.tileHeight, trailing: {
            // `runningSource == .cloudflareEndpoint`, not the shared
            // `isRunning` — so this button only claims "Testing…" when
            // *this* tile's own test is the one running, not whenever
            // Apple networkQuality's tile is. `.disabled(isRunning)`
            // still uses the shared flag: the two tests can't run
            // concurrently either way (see
            // `NetworkQualityViewModel.runningSource`'s doc comment), so
            // this button is inert while the other tile's test is in
            // flight too, just without claiming to be the one doing the
            // work.
            Button(networkQuality.runningSource == .cloudflareEndpoint ? "Testing…" : "Run Speed Test") {
                networkQuality.run()
            }
            .disabled(networkQuality.isRunning)
            .accessibilityLabel(networkQuality.runningSource == .cloudflareEndpoint ? "Testing" : "Run Speed Test")
            .accessibilityHint("Measures download and upload throughput using Cloudflare's public speed-test endpoint. Uses your data plan, up to roughly 50MB total, less on a slow connection.")
            .accessibilityIdentifier("speedTest.runCloudflare")
        }) {
            Text("up to ~50MB per run")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if networkQuality.cloudflareRuns.isEmpty {
                Text(networkQuality.runningSource == .cloudflareEndpoint ? "Testing…" : "No speed test run yet")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                runRows
            }
            if let error = networkQuality.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    /// One line per run: "750 Mbps down, 550 Mbps up" plus a time-only
    /// (no date) timestamp. Every row here is Cloudflare-sourced by
    /// construction (`cloudflareRuns`), so there's no per-row source
    /// check needed — this list never has an Apple-sourced RPM/latency
    /// line to decide whether to show.
    private var runRows: some View {
        ForEach(networkQuality.cloudflareRuns) { run in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(run.throughputText)
                    Spacer()
                    Text(run.testedAt, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                if let dataUsed = run.dataUsedText {
                    Text(dataUsed)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
