import SwiftUI

/// A real SwiftUI `Settings` scene now (popover conversion, Phase 2,
/// 2026-08-12) — this used to be a plain `Window` instead, because
/// `Settings`'s automatic Preferences-menu/⌘, wiring didn't reliably
/// apply to the app's then-current `.regular` activation policy (a
/// standard Dock icon and app menu bar, but no `MenuBarExtra` for
/// `Settings` to hook into the way it expects). `.accessory` +
/// `MenuBarExtra` is exactly the configuration `Settings` was designed
/// for, so that reasoning no longer applies — opened via
/// `MenuBarView`'s "Preferences…" button calling
/// `@Environment(\.openSettings)`, same `NSApp.activate()` foreground
/// fix `ContentView.openWindowInFront` already needed.
///
/// Deliberately narrow in scope: only `FeatureFlags`-shaped settings live
/// here — a real on/off toggle, not a list — plus each toggle's own
/// contextual sub-preferences (`SNMPCommunityStringsSection`,
/// `SaaSServicePickerSection`/`UserAddedSitesSection`,
/// `FirewallVisibilityServerSection`, `DDNSHostnamesSection`). Known
/// Networks keeps its own window (a list with delete, not a toggle) — see
/// DESIGN-NOTES.md's "Feature flags, now that friends are installing this
/// too" for the reasoning on what does and doesn't belong here. SNMP's
/// community-string field used to stay inline in the popover instead
/// (contextual, where you'd notice you need it) — that field was deleted
/// along with the rest of the old popover's tiles in the menu bar popover
/// conversion and, until `PJorgens61/NMS#19`, never rebuilt anywhere;
/// landed here rather than back in the popover since the popover has no
/// budget left for a text field and this window already hosts every
/// other feature-gated sub-preference.
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
    @AppStorage(FeatureFlags.firewallVisibilityKey) private var firewallVisibilityEnabled = false
    @AppStorage(FeatureFlags.autoBaselineNetworkQualityKey) private var autoBaselineNetworkQualityEnabled = false
    // Default `true` — see `FeatureFlags.tooltipHighlights`'s own doc
    // comment for why this one's also a deliberate on-by-default
    // exception, same shape as `saasMonitoringEnabled` above.
    @AppStorage(FeatureFlags.tooltipHighlightsKey) private var tooltipHighlightsEnabled = true
    // Default `true`, same on-by-default exception as the two above —
    // see `FeatureFlags.tooltipTechnicalDetail`'s own doc comment.
    @AppStorage(FeatureFlags.tooltipTechnicalDetailKey) private var tooltipTechnicalDetailEnabled = true

    var body: some View {
        // Content-driven height with no scroll container used to mean the
        // window locked to its full content height and couldn't be
        // resized by dragging at all (`NMSApp`'s
        // `.windowResizability(.contentSize)`) -- fine when this view was
        // short, but it grew (13 SaaS services, DDNS hostnames, several
        // feature toggles) past what fits on a MacBook Air's screen, the
        // same failure `ContentView.body`'s own outer `ScrollView`
        // already exists to prevent for the main window. Same fix here:
        // a scroll container plus a genuinely resizable window, rather
        // than one locked to content size.
        ScrollView {
            preferencesContent
        }
    }

    private var preferencesContent: some View {
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

            // Same "only shown once the parent feature is on" reasoning as
            // the SaaS/Firewall sub-sections below.
            if snmpDevicesEnabled {
                SNMPCommunityStringsSection()
            }

            feature(
                "SaaS Monitoring",
                isOn: $saasMonitoringEnabled,
                description: "Periodically checks the public status pages of Slack, Claude, ChatGPT, Jira/Confluence, Zendesk, Zoom, Trello, Asana, Notion, Dropbox, Discord, GitHub, Cloudflare, Figma, HubSpot, Docusign, Google Cloud, and Google Workspace. Reaches out to those services directly, not just your own network.",
                identifier: "preferences.saasMonitoring"
            )

            // Only shown once the feature itself is on — a per-service
            // list for a disabled feature would just be confusing. Not
            // its own `feature(...)` row since it isn't a single on/off
            // switch — a real sub-preference under the one above. Each
            // is its own `View` type with its own `@State` now, so
            // toggling this flag (or any other preference in this
            // window) doesn't re-evaluate either section's body — see
            // `PUNCHLIST.md`'s view-structure factoring entry.
            if saasMonitoringEnabled {
                SaaSServicePickerSection()
                UserAddedSitesSection()
            }

            feature(
                "Firewall Visibility",
                isOn: $firewallVisibilityEnabled,
                description: "Requests scans from FW, a separate internet-hosted companion service, to test what's actually reachable on this connection's public IP from outside. Reaches out to that server directly, not just your own network — and being on is also the consent for the scheduled and SNMP-triggered scans this runs automatically, not just the manual button.",
                identifier: "preferences.firewallVisibility"
            )

            // Same "only shown once the parent feature is on" reasoning
            // `SaaSServicePickerSection`/`UserAddedSitesSection` follow
            // above — a server URL and token field are meaningless noise
            // while this is off.
            if firewallVisibilityEnabled {
                FirewallVisibilityServerSection()
            }

            feature(
                "Auto-Baseline Network Quality",
                isOn: $autoBaselineNetworkQualityEnabled,
                description: "Runs Network Health's ~5 second networkQuality check automatically when you reconnect to a network you've already seen before, so the status dot has a real color instead of staying gray until you press it yourself. This is a genuine responsiveness test under load, not a ping — it uses your data plan, same as pressing the button manually. Never runs on the very first time this Mac sees a network.",
                identifier: "preferences.autoBaselineNetworkQuality"
            )

            feature(
                "Tooltip Highlights",
                isOn: $tooltipHighlightsEnabled,
                description: "Colors any row's label blue and underlines it when hovering shows more detail — otherwise a tooltip gives no visual sign it's there at all. Turn off to compare against plain labels.",
                identifier: "preferences.tooltipHighlights"
            )

            // A Picker, not a `feature(...)` Toggle — "Concise"/"Technical"
            // doesn't read naturally as on/off the way every other
            // preference here does. Same segmented-Picker shape
            // `DDNSHostnamesSection`'s own check-interval preference
            // already uses.
            VStack(alignment: .leading, spacing: 4) {
                Picker("Tooltip Detail", selection: $tooltipTechnicalDetailEnabled) {
                    Text("Concise").tag(false)
                    Text("Technical").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("preferences.tooltipTechnicalDetail")
                caption("Whether tooltips include the extra mechanism-level detail (which command runs, which resolver, what's in or out of scope) on top of the plain explanation.")
            }

            // Its own top-level section, not nested under a toggle like
            // `UserAddedSitesSection` is — there's no parent on/off flag
            // here (see `FeatureFlags.ddnsHostnames`'s doc comment): an
            // empty list is already fully inert, so entering a hostname
            // below is itself the opt-in.
            VStack(alignment: .leading, spacing: 4) {
                Text("DDNS Hostnames")
                    .font(.headline)
                caption("Watches a hostname you rely on for inbound access (a VPN endpoint, a port-forwarded service) and logs it if it stops matching this Mac's public IP — a sign your DDNS client has stopped updating.")
            }
            DDNSHostnamesSection()

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
        // Width fixed, height not -- content determines the scroll
        // view's natural extent, and the window itself is now genuinely
        // resizable (see `NMSApp`'s `Window("Preferences", ...)`), so a
        // shorter window just scrolls rather than either truncating
        // (the original `height: 260` guess did that) or locking the
        // window to an unresizable full-content height (what
        // `.windowResizability(.contentSize)` did before this).
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
}

/// `.fixedSize(horizontal: false, vertical: true)` is the load-bearing
/// part, not styling. Without it these truncated mid-sentence with an
/// ellipsis — wrapping to one line where three were needed — because
/// in a fixed-height stack containing a `Spacer`, SwiftUI hands the
/// slack to the spacer and gives each `Text` only its *ideal* height.
/// This forces a `Text` to claim the full height its wrapped content
/// needs, and is what makes the content-sized window measure correctly.
///
/// A free function, not a method — shared by `PreferencesView` and the
/// section types it composes (`SaaSServicePickerSection`,
/// `UserAddedSitesSection`, `DDNSHostnamesSection`), which have no
/// common enclosing type to attach it to since each is now its own
/// `View` with its own `@State` — see `PUNCHLIST.md`'s view-structure
/// factoring entry.
func caption(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}
