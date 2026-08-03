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
    /// A user's own added sites — separate list, separate interaction
    /// shape from the checkbox picker above (add/remove new entries
    /// rather than toggle existing ones). Same plain-`@State`-plus-manual-
    /// `UserDefaults`-write reasoning as `enabledSaaSServices`.
    @State private var userAddedSites: [FeatureFlags.UserAddedSaaSSite] = FeatureFlags.userAddedSaaSSites
    @State private var newSiteNickname = ""
    @State private var newSiteURLText = ""
    /// Same plain-`@State`-plus-manual-`UserDefaults`-write reasoning as
    /// `userAddedSites` — `[Codable]` isn't an `@AppStorage`-supported
    /// type either.
    @State private var ddnsHostnames: [FeatureFlags.DDNSHostname] = FeatureFlags.ddnsHostnames
    @State private var newDDNSHostnameText = ""
    /// `@AppStorage`, not plain `@State` — a `TimeInterval` (`Double`) is
    /// one of `@AppStorage`'s supported types, so this can be live the
    /// same way `snmpDevicesEnabled`/`saasMonitoringEnabled` are, no
    /// manual `UserDefaults` write needed.
    @AppStorage(FeatureFlags.ddnsCheckIntervalKey) private var ddnsCheckIntervalSeconds: Double = 300

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
                description: "Active SNMP network probing against whatever LAN this Mac is on. Only turn this on if you're comfortable with that on your own network.",
                identifier: "preferences.snmpDevices"
            )

            feature(
                "SaaS Monitoring",
                isOn: $saasMonitoringEnabled,
                description: "Periodically checks the public status pages of Slack, Claude, ChatGPT, Jira/Confluence, Zendesk, Zoom, Trello, Asana, Notion, Dropbox, Discord, GitHub, Cloudflare, Figma, HubSpot, Docusign, Google Cloud, and Google Workspace. Reaches out to those services directly, not just your own network.",
                identifier: "preferences.saasMonitoring"
            )

            // Only shown once the feature itself is on — a per-service
            // list for a disabled feature would just be confusing. Not
            // its own `feature(...)` row since it isn't a single on/off
            // switch — a real sub-preference under the one above.
            if saasMonitoringEnabled {
                saasServicePicker
                userAddedSitesSection
            }

            // Its own top-level section, not nested under a toggle like
            // `userAddedSitesSection` is — there's no parent on/off flag
            // here (see `FeatureFlags.ddnsHostnames`'s doc comment): an
            // empty list is already fully inert, so entering a hostname
            // below is itself the opt-in.
            VStack(alignment: .leading, spacing: 4) {
                Text("DDNS Hostnames")
                    .font(.headline)
                caption("Watches a hostname you rely on for inbound access (a VPN endpoint, a port-forwarded service) and logs it if it stops matching this Mac's public IP — a sign your DDNS client has stopped updating.")
            }
            ddnsHostnamesSection

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
    private func feature(_ title: String, isOn: Binding<Bool>, description: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .accessibilityIdentifier(identifier)
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
                    .accessibilityIdentifier("preferences.saas.selectAll")
                Button("Clear All") { setAllSaaSServices(enabled: false) }
                    .font(.system(size: 11))
                    .accessibilityIdentifier("preferences.saas.clearAll")
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
                        .accessibilityIdentifier("preferences.saas.service.\(service.name)")
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

    /// A user's own sites, checked for plain reachability rather than a
    /// real status page — see `SaaSMonitoringViewModel
    /// .checkUserAddedSites`'s doc comment for why these are reported
    /// separately in the live UI, not folded into the curated list above:
    /// this is a weaker, network-dependent signal ("is this domain
    /// answering right now"), not a real vendor incident, and showing it
    /// identically to the curated table would overstate its confidence.
    /// Indented under "SaaS Monitoring" the same way the curated picker
    /// is, since it's a sub-preference of the same toggle, not a separate
    /// feature.
    @ViewBuilder
    private var userAddedSitesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your own sites")
                .font(.system(size: 11, weight: .semibold))
            caption("Checked for plain reachability only — not a real status page, just \"did it answer.\"")

            ForEach(userAddedSites) { site in
                HStack {
                    Text(site.nickname)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(site.url)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        removeUserAddedSite(site)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(site.nickname)")
                    .accessibilityIdentifier("preferences.saas.userSite.remove.\(site.id)")
                }
                .font(.system(size: 11))
            }

            HStack {
                TextField("Nickname", text: $newSiteNickname)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("preferences.saas.userSite.nickname")
                TextField("https://example.com", text: $newSiteURLText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("preferences.saas.userSite.url")
                Button("Add") { addUserAddedSite() }
                    .disabled(!isNewSiteValid)
                    .accessibilityIdentifier("preferences.saas.userSite.add")
            }
            .font(.system(size: 11))
        }
        .padding(.leading, 16)
    }

    /// A real `http`/`https` URL specifically — `URL(string:)` alone
    /// accepts far more than that (a bare word with no scheme parses
    /// successfully as a relative reference), which would silently save
    /// something `URLSession` can't actually fetch.
    private var isNewSiteValid: Bool {
        !newSiteNickname.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: newSiteURLText)?.scheme.map { $0 == "http" || $0 == "https" } == true
    }

    private func addUserAddedSite() {
        guard isNewSiteValid else { return }
        userAddedSites.append(
            FeatureFlags.UserAddedSaaSSite(
                url: newSiteURLText.trimmingCharacters(in: .whitespaces),
                nickname: newSiteNickname.trimmingCharacters(in: .whitespaces)
            )
        )
        newSiteNickname = ""
        newSiteURLText = ""
        persistUserAddedSites()
    }

    private func removeUserAddedSite(_ site: FeatureFlags.UserAddedSaaSSite) {
        userAddedSites.removeAll { $0.id == site.id }
        persistUserAddedSites()
    }

    private func persistUserAddedSites() {
        FeatureFlags.setUserAddedSaaSSites(userAddedSites)
    }

    /// Mirrors `userAddedSitesSection` almost exactly — same add/remove
    /// list shape, just one `TextField` (a bare hostname, not a
    /// nickname+URL pair) instead of two. The check-interval picker only
    /// appears once a hostname is actually configured — same "only shown
    /// once relevant" pattern `saasServicePicker` uses for its own
    /// sub-preference.
    @ViewBuilder
    private var ddnsHostnamesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ddnsHostnames) { entry in
                HStack {
                    Text(entry.hostname)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        removeDDNSHostname(entry)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(entry.hostname)")
                    .accessibilityIdentifier("preferences.ddns.hostname.remove.\(entry.id)")
                }
                .font(.system(size: 11))
            }

            HStack {
                TextField("myhome.example.com", text: $newDDNSHostnameText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("preferences.ddns.hostname.text")
                Button("Add") { addDDNSHostname() }
                    .disabled(!isNewDDNSHostnameValid)
                    .accessibilityIdentifier("preferences.ddns.hostname.add")
            }
            .font(.system(size: 11))

            if !ddnsHostnames.isEmpty {
                Picker("Check every", selection: $ddnsCheckIntervalSeconds) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                }
                .pickerStyle(.segmented)
                .font(.system(size: 11))
                .accessibilityIdentifier("preferences.ddns.checkInterval")
            }
        }
    }

    /// A bare hostname, not a URL — no scheme, no path. Just non-empty
    /// after trimming, same minimal bar `isNewSiteValid` sets for its own
    /// nickname field.
    private var isNewDDNSHostnameValid: Bool {
        !newDDNSHostnameText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addDDNSHostname() {
        guard isNewDDNSHostnameValid else { return }
        ddnsHostnames.append(FeatureFlags.DDNSHostname(hostname: newDDNSHostnameText.trimmingCharacters(in: .whitespaces)))
        newDDNSHostnameText = ""
        persistDDNSHostnames()
    }

    private func removeDDNSHostname(_ entry: FeatureFlags.DDNSHostname) {
        ddnsHostnames.removeAll { $0.id == entry.id }
        persistDDNSHostnames()
    }

    private func persistDDNSHostnames() {
        FeatureFlags.setDDNSHostnames(ddnsHostnames)
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
