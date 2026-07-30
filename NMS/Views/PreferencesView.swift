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
            Text("Experimental Features")
                .font(.headline)

            Text("Off by default for a fresh install — everything below is opt-in.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Open in Window", isOn: $comparisonWindowEnabled)
                Text("A resizable, scrollable alternative to the popover. Still genuinely experimental — not yet a replacement for it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("SNMP Devices", isOn: $snmpDevicesEnabled)
                Text("Active SNMP network probing against whatever LAN this Mac is on. Only turn this on if you're comfortable with that on your own network.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Changes here take effect after restarting NMS.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380, height: 260, alignment: .topLeading)
    }
}
