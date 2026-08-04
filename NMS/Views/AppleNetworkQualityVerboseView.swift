import SwiftUI

/// A read-only look at Apple's own full `networkQuality -v` report for the
/// most recently completed run — raised directly, for an expert who wants
/// more than this app's own summary (idle-latency/responsiveness broken
/// down by transport layer, protocol mix, ECN/L4S status, endpoint) shows.
/// Displayed verbatim, not parsed into structured fields — see
/// `AppleNetworkQualityService.Measurement.verboseOutput`'s doc comment
/// for why interpreting Apple's own prose programmatically isn't worth
/// the fragility.
struct AppleNetworkQualityVerboseView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apple networkQuality — Full Report")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("appleNetworkQuality.verboseReport.done")
                    .help("Closes the full report")
            }

            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 400, idealHeight: 560)
    }
}
