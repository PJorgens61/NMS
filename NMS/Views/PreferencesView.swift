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
    // same key names (via `FeatureFlags.snmpDevicesKey`/etc.), so toggling
    // here and reading via `FeatureFlags` elsewhere agree on the same
    // value.
    @AppStorage(FeatureFlags.snmpDevicesKey) private var snmpDevicesEnabled = false
    // Default `true`, not `false` like its neighbors — see
    // `FeatureFlags.saasMonitoring`'s doc comment for why this one's on
    // by default. `@AppStorage`'s default only applies to a genuinely
    // unset key (same as that property's own `defaults.object` check),
    // so this and `FeatureFlags.saasMonitoring` agree for every case,
    // including a prior explicit opt-out.
    @AppStorage(FeatureFlags.saasMonitoringKey) private var saasMonitoringEnabled = true
    /// Plain `@State`, not `@AppStorage` — `[String]` isn't one of
    /// `@AppStorage`'s supported types, so this is read once at view
    /// creation and written straight to `UserDefaults` on every change
    /// instead (see `saasServiceBinding`/`setAllSaaSServices` below).
    /// Initialized from `FeatureFlags.saasEnabledServices`, defaulting to
    /// "every service checked" when that preference has never been
    /// customized — see that property's doc comment for why `nil` means
    /// that rather than "none."
    @State private var enabledSaaSServices: Set<String> =
        FeatureFlags.saasEnabledServices ?? Set(SaaSStatusService.monitoredServices.map(\.name))

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Experimental Features")
                    .font(.headline)
                caption("Off by default for a fresh install — everything below is opt-in.")
            }

            feature(
                "SNMP Devices",
                isOn: $snmpDevicesEnabled,
                description: "Active SNMP network probing against whatever LAN this Mac is on. Only turn this on if you're comfortable with that on your own network."
            )

            feature(
                "SaaS Monitoring",
                isOn: $saasMonitoringEnabled,
                description: "Periodically checks the public status pages of Slack, Claude, ChatGPT, Jira/Confluence, Zendesk, Zoom, Trello, Asana, Notion, Dropbox, Discord, Google Cloud, and Google Workspace. Reaches out to those services directly, not just your own network."
            )

            // Only shown once the feature itself is on — a per-service
            // list for a disabled feature would just be confusing. Not
            // its own `feature(...)` row since it isn't a single on/off
            // switch — a real sub-preference under the one above.
            if saasMonitoringEnabled {
                saasServicePicker
            }

            // Both toggles apply live as of `FeatureFlags.snmpDevices`/
            // `.saasMonitoring`/`.saasEnabledServices` observing
            // `UserDefaults` changes directly — no restart caveat needed
            // anymore now that "Open in Window" (the one thing that did
            // need one, since it gated a whole SwiftUI `Scene`) is a
            // permanent, always-on part of the app rather than a toggle
            // here at all. See `ContentView`'s "Expert Mode" footer button.
            caption("Changes here apply immediately, no restart needed.")
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

    /// One checkbox per `SaaSStatusService.monitoredServices` entry, plus
    /// Select All / Clear All for quickly narrowing to (or clearing) a
    /// single service — useful when only one or two of the thirteen
    /// actually matter to you, or when isolating one for testing.
    /// Indented under the "SaaS Monitoring" toggle above, same visual
    /// nesting a sub-preference implies without a second `.headline`.
    ///
    /// Two columns, not one long list — requested directly once the list
    /// grew past what fit comfortably in a single glance (13 services as
    /// of the Discord/Google Cloud/Google Workspace additions, up from
    /// the original 10). `LazyVGrid` over a plain `HStack` of two
    /// `VStack`s: a fixed name-based split would need rebalancing by hand
    /// every time a service is added or removed, where the grid just
    /// reflows on its own.
    @ViewBuilder
    private var saasServicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Services to monitor")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Select All") { setAllSaaSServices(enabled: true) }
                    .font(.system(size: 11))
                Button("Clear All") { setAllSaaSServices(enabled: false) }
                    .font(.system(size: 11))
            }
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(SaaSStatusService.monitoredServices, id: \.name) { service in
                    Toggle(service.name, isOn: saasServiceBinding(for: service.name))
                        .font(.system(size: 11))
                        // Truncate rather than wrap — "Jira/Confluence" and
                        // "Google Workspace" are the longest names, and at
                        // half the pane's already-fixed 380pt width, a wrap
                        // would misalign the checkbox column between rows.
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 16)
    }

    private func saasServiceBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { enabledSaaSServices.contains(name) },
            set: { isOn in
                if isOn {
                    enabledSaaSServices.insert(name)
                } else {
                    enabledSaaSServices.remove(name)
                }
                persistSaaSServices()
            }
        )
    }

    private func setAllSaaSServices(enabled: Bool) {
        enabledSaaSServices = enabled ? Set(SaaSStatusService.monitoredServices.map(\.name)) : []
        persistSaaSServices()
    }

    /// `UserDefaults.set(_:forKey:)`, not `@AppStorage`, since `[String]`
    /// isn't a type `@AppStorage` supports directly — see
    /// `enabledSaaSServices`'s own doc comment.
    private func persistSaaSServices() {
        UserDefaults.standard.set(Array(enabledSaaSServices), forKey: FeatureFlags.saasEnabledServicesKey)
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
