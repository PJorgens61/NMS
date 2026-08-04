import SwiftUI

/// One checkbox per `SaaSStatusService.monitoredServices` entry, plus
/// Select All / Clear All for quickly narrowing to (or clearing) a
/// single service — useful when only one or two of the thirteen
/// actually matter to you, or when isolating one for testing.
/// Indented under `PreferencesView`'s "SaaS Monitoring" toggle, same
/// visual nesting a sub-preference implies without a second `.headline`.
///
/// Two columns, not one long list — requested directly once the list
/// grew past what fit comfortably in a single glance (13 services as
/// of the Discord/Google Cloud/Google Workspace additions, up from
/// the original 10). `LazyVGrid` over a plain `HStack` of two
/// `VStack`s: a fixed name-based split would need rebalancing by hand
/// every time a service is added or removed, where the grid just
/// reflows on its own.
///
/// Pulled out of `PreferencesView` into its own `View` type, with its
/// own `@State`, so toggling an unrelated preference (SNMP Devices, the
/// DDNS hostname list) doesn't re-evaluate this picker's body too — see
/// `PUNCHLIST.md`'s view-structure factoring entry. Fully self-contained
/// (no inputs at all): `PreferencesView` only shows or hides it, never
/// reads its state.
struct SaaSServicePickerSection: View {
    /// Initialized from `FeatureFlags.saasEnabledServices`, defaulting to
    /// "every service checked" when that preference has never been
    /// customized — see that property's doc comment for why `nil` means
    /// that rather than "none."
    @State private var enabledSaaSServices: Set<String> =
        FeatureFlags.saasEnabledServices ?? Set(SaaSStatusService.monitoredServices.map(\.name))

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Services to monitor")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Select All") { setAll(enabled: true) }
                    .font(.system(size: 11))
                    .accessibilityIdentifier("preferences.saas.selectAll")
                Button("Clear All") { setAll(enabled: false) }
                    .font(.system(size: 11))
                    .accessibilityIdentifier("preferences.saas.clearAll")
            }
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(SaaSStatusService.monitoredServices, id: \.name) { service in
                    Toggle(service.name, isOn: binding(for: service.name))
                        .font(.system(size: 11))
                        // Truncate rather than wrap — "Jira/Confluence" and
                        // "Google Workspace" are the longest names, and at
                        // half the pane's already-fixed 380pt width, a wrap
                        // would misalign the checkbox column between rows.
                        .lineLimit(1)
                        .accessibilityIdentifier("preferences.saas.service.\(service.name)")
                }
            }
        }
        .padding(.leading, 16)
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { enabledSaaSServices.contains(name) },
            set: { isOn in
                if isOn {
                    enabledSaaSServices.insert(name)
                } else {
                    enabledSaaSServices.remove(name)
                }
                persist()
            }
        )
    }

    private func setAll(enabled: Bool) {
        enabledSaaSServices = enabled ? Set(SaaSStatusService.monitoredServices.map(\.name)) : []
        persist()
    }

    /// `UserDefaults.set(_:forKey:)`, not `@AppStorage`, since `[String]`
    /// isn't a type `@AppStorage` supports directly — see
    /// `enabledSaaSServices`'s own doc comment.
    private func persist() {
        UserDefaults.standard.set(Array(enabledSaaSServices), forKey: FeatureFlags.saasEnabledServicesKey)
    }
}
