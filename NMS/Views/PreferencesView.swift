import SwiftUI

/// A plain `Window`, not a SwiftUI `Settings` scene — `Settings` normally
/// wires itself to the app's Preferences menu item and ⌘,, but that
/// wiring doesn't reliably apply to `NMSApp`'s `.accessory` activation
/// policy (no Dock icon, no standard app menu bar to attach a "Preferences…"
/// item to). Opened via a footer button instead, the same pattern already
/// proven for `KnownNetworksView`.
///
/// Deliberately narrow in scope: only `FeatureFlags`-shaped settings live
/// here — a real on/off toggle, not a list. SNMP's community-string field
/// stays inline in the popover (contextual, where you'd notice you need
/// it), and Known Networks keeps its own window (a list with delete, not
/// a toggle) — see DESIGN-NOTES.md's "Feature flags, now that friends are
/// installing this too" for the reasoning on what does and doesn't belong
/// here.
struct PreferencesView: View {
    // `@AppStorage`, not `FeatureFlags`' own plain `UserDefaults` reads —
    // this is the one place these values need to be *live*, so a toggle
    // updates immediately rather than requiring the view to be told to
    // re-render. Same underlying `UserDefaults.standard` store and the
    // same key names (via `FeatureFlags.comparisonWindowKey`/
    // `snmpDevicesKey`), so toggling here and reading via `FeatureFlags`
    // elsewhere agree on the same value.
    @AppStorage(FeatureFlags.comparisonWindowKey) private var comparisonWindowEnabled = false
    @AppStorage(FeatureFlags.snmpDevicesKey) private var snmpDevicesEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Experimental Features")
                    .font(.headline)
                caption("Off by default for a fresh install — everything below is opt-in.")
            }

            feature(
                "Open in Window",
                isOn: $comparisonWindowEnabled,
                description: "A resizable, scrollable alternative to the popover. Still genuinely experimental — not yet a replacement for it."
            )

            feature(
                "SNMP Devices",
                isOn: $snmpDevicesEnabled,
                description: "Active SNMP network probing against whatever LAN this Mac is on. Only turn this on if you're comfortable with that on your own network."
            )

            caption("Changes here take effect after restarting NMS.")
                .fontWeight(.semibold)
        }
        .padding(16)
        // Width fixed, height deliberately not: the window sizes to
        // whatever the text actually needs (see `NMSApp`'s
        // `.windowResizability(.contentSize)` on this scene). The previous
        // `height: 260` was a guess, and both descriptions outgrew it —
        // reported as text being "cut off".
        .frame(width: 380, alignment: .topLeading)
    }

    /// A toggle and its explanation as one unit, so the description reads
    /// as belonging to the switch above it rather than floating between
    /// two of them at equal spacing.
    @ViewBuilder
    private func feature(_ title: String, isOn: Binding<Bool>, description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
            caption(description)
        }
    }

    /// `.fixedSize(horizontal: false, vertical: true)` is the load-bearing
    /// part, not styling. Without it these truncated mid-sentence with an
    /// ellipsis — wrapping to one line where three were needed — because
    /// in a fixed-height stack containing a `Spacer`, SwiftUI hands the
    /// slack to the spacer and gives each `Text` only its *ideal* height.
    /// This forces a `Text` to claim the full height its wrapped content
    /// needs, and is what makes the content-sized window measure
    /// correctly.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
