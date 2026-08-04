import SwiftUI

/// The "Apple networkQuality" tile — same shape as `SpeedTestTile`, split
/// out alongside it. See `PUNCHLIST.md`'s "Give Apple's networkQuality
/// its own tile."
///
/// Eighth of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry) — reads two `@ObservedObject`s (`networkQuality` for
/// the test itself, `viewModel` only to read the current interface name
/// for the run button). The verbose-report sheet's `@State` moved here
/// too — purely local UI state with no reason to live on `ContentView`
/// once this section is its own type.
struct AppleNetworkQualityTile: View {
    @ObservedObject var networkQuality: NetworkQualityViewModel
    @ObservedObject var viewModel: NetworkMonitorViewModel

    @State private var isShowingAppleVerboseOutput = false

    var body: some View {
        tile(title: "Apple networkQuality", fixedHeight: ContentView.tileHeight, trailing: {
            Button(networkQuality.runningSource == .appleNetworkQuality ? "Testing…" : "Run Test") {
                networkQuality.runAppleTest(interfaceName: viewModel.currentInterface?.interfaceName)
            }
            .disabled(networkQuality.isRunning)
            .accessibilityLabel(networkQuality.runningSource == .appleNetworkQuality ? "Testing" : "Run Apple networkQuality")
            .accessibilityHint("Runs Apple's own network quality test: throughput plus responsiveness under load. Uses your data plan and takes about 30 seconds.")
            .accessibilityIdentifier("appleNetworkQuality.run")
        }) {
            // "~30s" alone understated this badly — confirmed live via
            // `networkQuality`'s own real byte counts (`dl_bytes_transferred`/
            // `ul_bytes_transferred`, undocumented in the man page but present
            // in every real run): 1-2GB *per direction* on a fast connection,
            // not a rounding error against the Cloudflare test's ~50MB. The
            // test moves as much data as the link can carry in its measurement
            // window (see DESIGN-NOTES.md's "Network Quality" section on why
            // it's time-limited, not data-limited) — the faster the
            // connection, the more it actually costs, which is the opposite
            // of what "~30s" implies. Each completed run shows its own exact
            // figure below (`NetworkQualityRecord.dataUsedText`); this is the
            // honest heads-up before that first run exists.
            Text("uses your data plan — often 1+ GB on a fast connection, ~30s")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // Explains RPM's own convention up front, rather than avoiding
            // the term — real confusion reported ("RPMs confused me at
            // first"), plus the more important correction: RPM's
            // "higher is better" convention isn't an accident to work
            // around, it's the whole reason RPM exists as its own metric
            // rather than just reporting a latency number. So this
            // doesn't convert RPM into a derived ms figure — it states
            // the convention in words instead, right where a reader will
            // meet the number itself.
            Text("Higher RPM means a more responsive connection under load.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if networkQuality.appleRuns.isEmpty {
                Text(networkQuality.runningSource == .appleNetworkQuality ? "Testing…" : "No test run yet")
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
            // Only once a run exists to show — for an expert who wants
            // Apple's own full `-v` report rather than this tile's
            // summary. Plain-styled, secondary: "one first-class action
            // per tile."
            if let verboseOutput = networkQuality.latestAppleVerboseOutput, !verboseOutput.isEmpty {
                Button("View Full Report…") {
                    isShowingAppleVerboseOutput = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
                .accessibilityHint("Shows Apple's own full networkQuality verbose report for the most recent run")
                .accessibilityIdentifier("appleNetworkQuality.viewFullReport")
                .sheet(isPresented: $isShowingAppleVerboseOutput) {
                    AppleNetworkQualityVerboseView(text: verboseOutput)
                }
            }
        }
    }

    /// Same throughput/timestamp line `SpeedTestTile` shows, plus a
    /// second line every row here always has: RPM under load, split by
    /// direction — the signal this whole second source exists for — and
    /// idle base latency, the one other figure `networkQuality` measures
    /// that Cloudflare's plain file transfer has no equivalent of.
    /// Unconditional (no per-row source check) since every row here is
    /// Apple-sourced by construction (`appleRuns`).
    ///
    /// Built as separate `Text`s in an `HStack`, not one interpolated
    /// string — `.help(_:)` attaches to a specific view, and `Text`
    /// concatenation (`+`) merges into a single `Text` with no per-segment
    /// view identity to attach to, so reaching `QuickCheckDisplay
    /// .rpmThresholdHelp` onto just the RPM figures (not the idle-latency
    /// figure beside them) needs each to stay its own view.
    private var runRows: some View {
        ForEach(networkQuality.appleRuns) { run in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(run.throughputText)
                    Spacer()
                    Text(run.testedAt, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                HStack(spacing: 4) {
                    if let dl = run.downloadResponsivenessRPM, let ul = run.uploadResponsivenessRPM {
                        // RPM leads, spelled out with "down"/"up" rather
                        // than ↓/↑ arrows — kept as the actual published
                        // metric rather than converted to a derived
                        // latency figure. No "Apple" prefix on the
                        // string itself: the tile title already says
                        // "Apple networkQuality," so repeating it on
                        // every row would be redundant.
                        //
                        // Two dots, not one merged verdict — this tile
                        // is specifically for a reader who wants the
                        // per-direction detail a single "worst of the
                        // two" dot would erase (a real bufferbloat
                        // problem in only one direction is a genuinely
                        // different diagnosis than one in both). The
                        // Network tile's quick check collapses to one
                        // dot on purpose, for the opposite audience.
                        Circle()
                            .fill(QuickCheckDisplay.color(forRPM: dl))
                            .frame(width: 6, height: 6)
                            .help(QuickCheckDisplay.rpmThresholdHelp)
                        Text("\(dl) RPM down")
                        Circle()
                            .fill(QuickCheckDisplay.color(forRPM: ul))
                            .frame(width: 6, height: 6)
                            .help(QuickCheckDisplay.rpmThresholdHelp)
                        Text("\(ul) RPM up")
                        if run.baseRTTMs != nil {
                            Text("·")
                        }
                    }
                    // Idle base latency — a real reported figure, not
                    // derived — stays alongside RPM as a separate
                    // reference point, not folded into the same number.
                    if let rtt = run.baseRTTMs {
                        Text(String(format: "%.0fms idle latency", rtt))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                // Its own line, not folded into the RPM/latency line
                // above — a distinct concern (data cost, not connection
                // quality). Genuinely important here specifically:
                // confirmed live, a single run can use 1-2GB per
                // direction, far more than "uses your data plan, ~30s"
                // alone conveys.
                if let dataUsed = run.dataUsedText {
                    Text(dataUsed)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
