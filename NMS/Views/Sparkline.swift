import SwiftUI

/// A compact trend line for a value that changes over time — Network
/// Health's per-layer latency originally, now also reused for Wi-Fi RSSI
/// history — sized to sit inline on an existing row.
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
///
/// **`[Double?]`, not `[LatencySample]`** — this used to take
/// `LatencySample` directly, but every use of a sample here was really
/// just its `latencyMs`; nothing about the drawing logic cares what the
/// value *means*, only where it sits between the series' own min/max and
/// where it's `nil` (a gap, not a zero). Generalizing the input type let
/// Wi-Fi RSSI reuse this outright instead of a second, parallel
/// mini-chart — `nil` means "no signal reading that round" for RSSI, the
/// same "gap, not a failure rendered as zero" meaning it had for a failed
/// ping.
struct Sparkline: View {
    let values: [Double?]

    private static let size = CGSize(width: 44, height: 11)

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }

            // Scaled per-instance, never shared across layers/series. DNS
            // probes run in single-digit ms and internet pings in tens
            // (and RSSI is a third, unrelated scale entirely), so one axis
            // across all of them would flatten the smaller-range ones into
            // an apparently dead line.
            let present = values.compactMap { $0 }
            let lowest = present.min() ?? 0
            let highest = present.max() ?? 1
            // A flat line sits mid-height rather than at an arbitrary
            // edge, which is what a zero-range span would otherwise do.
            let span = highest - lowest
            let step = size.width / CGFloat(values.count - 1)

            func point(_ index: Int, _ value: Double) -> CGPoint {
                let x = CGFloat(index) * step
                let normalized = span > 0 ? (value - lowest) / span : 0.5
                // Inverted: a higher value should read as higher on the
                // chart, and the canvas origin is top-left.
                let y = size.height - (CGFloat(normalized) * size.height)
                return CGPoint(x: x, y: y)
            }

            // The line is drawn only through present values, and *broken*
            // at gaps rather than interpolated across them. Bridging a gap
            // would render a real outage (or a missed Wi-Fi sample) as a
            // smooth line between the points either side of it — the one
            // reading the sparkline exists to prevent.
            var path = Path()
            var penDown = false
            for (index, value) in values.enumerated() {
                guard let value else {
                    penDown = false
                    continue
                }
                let location = point(index, value)
                if penDown {
                    path.addLine(to: location)
                } else {
                    path.move(to: location)
                    penDown = true
                }
            }
            context.stroke(path, with: .color(.secondary), lineWidth: 1)

            // Gaps marked explicitly, at the bottom of the range, in the
            // same red this app uses for failure everywhere else.
            for (index, value) in values.enumerated() where value == nil {
                let x = CGFloat(index) * step
                let dot = CGRect(x: x - 1, y: size.height - 2, width: 2, height: 2)
                context.fill(Path(ellipseIn: dot), with: .color(.red))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Nothing to draw from a single point, and an empty box reads as
        // a rendering bug rather than as "no history yet".
        .opacity(values.count > 1 ? 1 : 0)
        .accessibilityHidden(true)
    }
}
