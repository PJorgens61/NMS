import SwiftUI

/// The dot/label/icon/chart/detail shape every status row in
/// `NetworkTile`'s `Grid` uses — extracted after the third near-identical
/// hand-rolled `GridRow` (`ConnectionLayerRow`, `QuickCheckRow`,
/// `DHCPStatusRow` all built this same five-cell shape by hand) so each
/// row type is a few lines instead of copying the whole shape and its
/// column-alignment reasoning again.
///
/// A free function, not a method — every caller is now its own separate
/// `View` type (see `PUNCHLIST.md`'s view-structure factoring entry), so
/// there's no single enclosing type to attach this to; a plain function
/// callable from any `Grid`'s `@ViewBuilder` context is the natural
/// shape, matching how `GridRow` itself is used.
///
/// `icon`/`chart` are `@ViewBuilder` slots, not optionals — a caller with
/// nothing real for either passes `Color.clear.frame(width: 0, height:
/// 0)` explicitly (see that pattern's own reasoning below), rather than
/// this helper silently defaulting to `EmptyView()`, which doesn't
/// reliably reserve its `Grid` column.
@ViewBuilder
func statusGridRow<Icon: View, Chart: View>(
    color: Color,
    dotHelp: String? = nil,
    label: String,
    detail: String,
    detailColor: Color = .primary,
    @ViewBuilder icon: () -> Icon,
    @ViewBuilder chart: () -> Chart
) -> some View {
    let highlight = dotHelp != nil && FeatureFlags.tooltipHighlights
    GridRow {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(optional: dotHelp)
        // Plain — the highlight moved to the detail/result text below
        // instead (raised directly: "blue highlight for the result not
        // 'networkQuality'"). The result is what the tooltip actually
        // explains (an RPM number's good/fair/poor meaning), so it's the
        // more natural hover target than this row's fixed name.
        Text(label)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .gridColumnAlignment(.leading)
        icon()
        chart()
        // `minWidth` protects this column specifically — confirmed
        // necessary again on the second `Grid` attempt: sharing one
        // column width across every row means a long label ("ISP
        // Edge Router") squeezes this column on every row, not just
        // its own. A value truncated in the middle ("Hom...hernet")
        // is unreadable garble; a label truncated at the tail ("ISP
        // Edge…") still starts with its most identifying word — so
        // this column gets the guaranteed room, and the label
        // column absorbs whatever compression is left. 85pt
        // comfortably fits the longest real value seen here ("Home
        // Ethernet"). `maxWidth: .infinity` marks this column
        // flexible so `Grid` gives it the tile's leftover width
        // instead of shrink-wrapping the whole grid to its narrowest
        // fit — without it, a wide window left the grid (and this
        // "trailing"-aligned column) bunched at the tile's left edge
        // instead of flush against its real right edge. Confirmed
        // via user screenshot: looked fine in the narrower popover,
        // misaligned only in the window.
        Text(detail)
            .foregroundStyle(highlight ? .blue : detailColor)
            .underline(highlight)
            .help(optional: dotHelp)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(minWidth: 85, maxWidth: .infinity, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

/// One row in `NetworkTile`'s `Grid` for a single `ConnectionLayer` —
/// Network, Local Router, Public IP, ISP Edge Router, Internet, DNS, or
/// HTTP. Pulled out of `NetworkTile` into its own `View` type (see
/// `PUNCHLIST.md`'s view-structure factoring entry) with narrow, plain-
/// value inputs: `layer`/`rootCauseLayerID`/`sparklineValues` are all
/// `Equatable` values, not view-model references, so SwiftUI's own
/// struct diffing can skip re-rendering a row whose values didn't
/// actually change between two `NetworkTile.body` evaluations — even
/// though `NetworkTile.body` itself still reruns on every one of its
/// nine view models' changes (`connectionLayersLowToHigh` genuinely
/// synthesizes from most of them, so that computation can't be split
/// further without duplicating its logic).
///
/// `sparklineValues` -- `nil` renders the same `Color.clear` placeholder
/// the "always emit every cell" `Grid`-column rule below needs; non-`nil`
/// (however short) renders a `Sparkline`. Computed by `NetworkTile`
/// itself, since which values apply (Wi-Fi RSSI for the Network layer on
/// Wi-Fi, ping latency for every other layer) depends on `wifiSSID`/
/// `viewModel`/`latencyHistory`, none of which this row needs to hold
/// itself.
struct ConnectionLayerRow: View {
    let layer: ConnectionLayer
    let rootCauseLayerID: String?
    let sparklineValues: [Double?]?

    var body: some View {
        statusGridRow(
            color: color,
            dotHelp: layer.help,
            label: layer.label,
            detail: layer.detail + (layer.status == .unhealthy && layer.correlatedWithChange ? " *" : ""),
            detailColor: layer.status == .unhealthy ? color : .primary
        ) {
            // Not `EmptyView()` — confirmed by direct testing that a
            // literal `EmptyView()` cell doesn't reliably reserve its
            // `Grid` column, so rows with an empty icon/sparkline
            // silently collapsed a column relative to rows with real
            // content there (Router's icon pushed its sparkline right
            // of every ping row's). `Color.clear` measures as a real
            // zero-color view and keeps every row's cell count *and*
            // column position honest.
            if let url = layer.url {
                externalLinkIcon(
                    url: url,
                    accessibilityLabel: "\(layer.label) admin page",
                    accessibilityHint: "Opens \(layer.label)'s web interface in your browser"
                )
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        } chart: {
            if let sparklineValues {
                Sparkline(values: sparklineValues)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        // `.contain`, not `.combine` — turns this row into one element
        // whose frame spans its children (what both VoiceOver grouping and
        // `reportFrameForFieldTest` below need), while keeping the
        // Router/ISP Edge Router rows' real `externalLinkIcon` link
        // individually reachable. `.combine` would merge everything into
        // one opaque element and silently swallow that link.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("networkHealth.row.\(layer.id)")
        .reportFrameForFieldTest("networkHealth.row.\(layer.id)")
    }

    private var color: Color {
        switch layer.status {
        case .healthy: return .green
        case .unknown: return .gray
        case .unhealthy:
            // Full red for the actual root cause; a dimmed red for
            // anything failing above it, which is probably just a
            // consequence rather than its own separate problem.
            return layer.id == rootCauseLayerID ? .red : Color.red.opacity(0.4)
        }
    }
}
