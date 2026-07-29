import SwiftUI

/// A compact latency trend for one Network Health layer, sized to sit
/// inline on an existing row.
///
/// **Hand-drawn rather than Swift Charts**, which DESIGN-NOTES.md
/// originally proposed. Two reasons, and the first is specific to this
/// app: `ImageRenderer` — which the screenshot tool depends on — has
/// already been caught mishandling four separate things here
/// (`ScrollView` content, native buttons, missing backgrounds,
/// `NSViewRepresentable`), and a charting framework is a much larger
/// unknown in that renderer than a `Path`. Second, a sparkline *is* a
/// polyline: Charts would contribute auto-scaling, which is three lines
/// of min/max, in exchange for that risk.
///
/// Sized to roughly one line of text so it adds no vertical height to
/// the row it joins. That matters more than it sounds — the popover
/// fits a 13" MacBook Air exactly, and the Events list was trimmed by
/// two rows to make it do so.
struct Sparkline: View {
    let samples: [LatencySample]

    private static let size = CGSize(width: 44, height: 11)

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }

            // Scaled per-instance, never shared across layers. DNS probes
            // run in single-digit ms and internet pings in tens, so one
            // axis across all five rows would flatten the faster ones
            // into an apparently dead line.
            let values = samples.compactMap(\.latencyMs)
            let lowest = values.min() ?? 0
            let highest = values.max() ?? 1
            // A flat line sits mid-height rather than at an arbitrary
            // edge, which is what a zero-range span would otherwise do.
            let span = highest - lowest
            let step = size.width / CGFloat(samples.count - 1)

            func point(_ index: Int, _ latency: Double) -> CGPoint {
                let x = CGFloat(index) * step
                let normalized = span > 0 ? (latency - lowest) / span : 0.5
                // Inverted: higher latency should read as higher on the
                // chart, and the canvas origin is top-left.
                let y = size.height - (CGFloat(normalized) * size.height)
                return CGPoint(x: x, y: y)
            }

            // The line is drawn only through successful checks, and
            // *broken* at failures rather than interpolated across them.
            // Bridging a gap would render an outage as a smooth line
            // between the checks either side of it — the one reading the
            // sparkline exists to prevent.
            var path = Path()
            var penDown = false
            for (index, sample) in samples.enumerated() {
                guard let latency = sample.latencyMs else {
                    penDown = false
                    continue
                }
                let location = point(index, latency)
                if penDown {
                    path.addLine(to: location)
                } else {
                    path.move(to: location)
                    penDown = true
                }
            }
            context.stroke(path, with: .color(.secondary), lineWidth: 1)

            // Failures marked explicitly, at the bottom of the range, in
            // the same red this app uses for failure everywhere else.
            for (index, sample) in samples.enumerated() where sample.latencyMs == nil {
                let x = CGFloat(index) * step
                let dot = CGRect(x: x - 1, y: size.height - 2, width: 2, height: 2)
                context.fill(Path(ellipseIn: dot), with: .color(.red))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Nothing to draw from a single point, and an empty box reads as
        // a rendering bug rather than as "no history yet".
        .opacity(samples.count > 1 ? 1 : 0)
        .accessibilityHidden(true)
    }
}
