import SwiftUI

/// A separate window (not a popover section) listing every network this
/// Mac has connected to before, with a way to forget one entirely. Kept
/// out of the main popover/window deliberately — see the "Known Networks
/// UI" decision in the conversation this shipped from: a dedicated place
/// costs an extra click to reach, but keeps Events/SNMP Devices/DHCP
/// History from also having to make room for a list that's only relevant
/// occasionally.
struct KnownNetworksView: View {
    var networkIdentity: NetworkIdentityViewModel
    let snapshotStore: SnapshotStore

    /// The network currently shown in the Review sheet — `nil` when
    /// closed. A `.sheet(item:)` rather than a new `Window` scene:
    /// Known Networks is already a separate, resizable window, and a new
    /// Scene for a single on-demand view is exactly the kind of
    /// conditional-Scene machinery that has twice crashed this project's
    /// compiler (see DESIGN-NOTES.md's "Feature flags" section) — a sheet
    /// sidesteps that class of bug entirely.
    @State private var reviewingNetwork: KnownNetwork?

    /// In-progress label edits, keyed by fingerprint. Held separately from
    /// the stored `KnownNetwork.label` so a save happens once per edit
    /// rather than once per keystroke — `setLabel` calls
    /// `refreshKnownNetworks()`, which reassigns the array this `List` is
    /// built from, and doing that mid-typing fights the text field for
    /// focus. An entry is cleared once committed, so the binding falls
    /// back to the stored value.
    @State private var draftLabels: [String: String] = [:]
    /// Which row's field has focus, so losing focus commits the edit —
    /// `.onSubmit` alone would silently discard a label the user typed and
    /// then clicked away from.
    @FocusState private var focusedFingerprint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Known Networks")
                .font(.headline)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 2)

            // The name field is deliberately borderless, so it reads as a
            // label until clicked — which makes renaming invisible without
            // saying so once, here, rather than adding a control to every
            // row.
            Text("Click a name to rename it. Clearing it restores the Wi-Fi network name.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            if networkIdentity.knownNetworks.isEmpty {
                Text("No networks recorded yet.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .padding(12)
            } else {
                List {
                    ForEach(networkIdentity.knownNetworks, id: \.fingerprint) { network in
                        row(for: network)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 240)
        .onAppear { networkIdentity.refreshKnownNetworks() }
        // Commits the row that *just lost* focus, which is the common way
        // an edit ends — clicking another row, or anywhere else in the
        // window. Without this, only pressing Return would save.
        .onChange(of: focusedFingerprint) { previous, _ in
            guard
                let previous,
                let network = networkIdentity.knownNetworks.first(where: { $0.fingerprint == previous })
            else { return }
            commitLabel(for: network)
        }
        // `.sheet(isPresented:)`, not `.sheet(item:)` -- `KnownNetwork`'s
        // `@Model`-synthesized `Identifiable` conformance stopped
        // resolving for `.sheet(item:)`'s stricter `SendableMetatype`
        // requirement once enough unrelated files were deleted elsewhere
        // in the popover conversion's Phase 4 (confirmed directly:
        // reproducible on a clean build, a real if unexplained Swift/
        // SwiftData compiler quirk, not a logic error). `ForEach` above
        // already sidesteps the same dependency via `id: \.fingerprint`
        // rather than relying on `Identifiable` -- this does the
        // equivalent for the sheet.
        .sheet(isPresented: Binding(
            get: { reviewingNetwork != nil },
            set: { if !$0 { reviewingNetwork = nil } }
        )) {
            if let network = reviewingNetwork {
                NetworkReviewView(network: network, snapshotStore: snapshotStore)
            }
        }
    }

    @ViewBuilder
    private func row(for network: KnownNetwork) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                // The placeholder is the same fallback the row used to
                // show as static text, so an unlabelled network still
                // reads as "Thistle (Wi-Fi)" or "Ethernet" — just greyed,
                // which is honest: that name is derived, not stored.
                // Typing replaces it; clearing the field restores it.
                TextField(displayName(for: network), text: labelBinding(for: network))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($focusedFingerprint, equals: network.fingerprint)
                    .onSubmit { commitLabel(for: network) }
                    .accessibilityLabel("Name for \(displayName(for: network))")
                    .accessibilityHint("Type a name for this network; leave empty to use the Wi-Fi network name or connection type")
                    .accessibilityIdentifier("knownNetworks.rename.\(network.fingerprint)")
                Text("\(network.routerMAC) on \(network.subnet)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("seen \(network.timesSeen)× · last \(network.lastSeenAt, format: .dateTime.month().day().hour().minute())")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if networkIdentity.currentNetwork?.fingerprint == network.fingerprint {
                Text("Current")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Button {
                networkIdentity.setHome(!network.isHome, for: network)
            } label: {
                Image(systemName: network.isHome ? "house.fill" : "house")
            }
            .buttonStyle(.plain)
            .foregroundStyle(network.isHome ? Color.accentColor : Color.secondary)
            .accessibilityLabel(network.isHome ? "Home network" : "Mark as home network")
            .accessibilityHint("DDNS hostname checks (Preferences → DDNS Hostnames) only run and report while connected to whichever network is marked home")
            .accessibilityIdentifier("knownNetworks.home.\(network.fingerprint)")
            .help(tooltip(
                network.isHome ? "This is your home network." : "Mark as your home network.",
                technical: "DDNS hostname checks only run while connected to whichever network is marked home — elsewhere the DDNS section stays empty instead of comparing a home hostname against the wrong network's public IP."
            ))
            Button {
                reviewingNetwork = network
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Review \(network.label ?? network.routerMAC)")
            .accessibilityHint("Opens a read-only view of this network's recorded events, SNMP devices, DHCP history, and Wi-Fi telemetry")
            .accessibilityIdentifier("knownNetworks.review.\(network.fingerprint)")
            .help("Opens a read-only view of this network's recorded events, SNMP devices, DHCP history, and Wi-Fi telemetry")
            Button(role: .destructive) {
                networkIdentity.deleteNetwork(network)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forget \(network.label ?? network.routerMAC)")
            .accessibilityHint("Deletes this network and every event, DHCP lease, SNMP device, and Wi-Fi reading recorded on it")
            .accessibilityIdentifier("knownNetworks.delete.\(network.fingerprint)")
            .help("Deletes this network and every event, DHCP lease, SNMP device, and Wi-Fi reading recorded on it")
        }
        .padding(.vertical, 2)
    }

    /// Reads the in-progress draft if there is one, else whatever's
    /// stored. Writing only touches the draft — see `commitLabel` for when
    /// that reaches the store.
    private func labelBinding(for network: KnownNetwork) -> Binding<String> {
        Binding(
            get: { draftLabels[network.fingerprint] ?? network.label ?? "" },
            set: { draftLabels[network.fingerprint] = $0 }
        )
    }

    /// Persists a row's edited label, if it actually changed. Clearing the
    /// draft afterwards is what hands display back to the stored value
    /// (and, when the label is emptied, to `displayName`'s fallback).
    private func commitLabel(for network: KnownNetwork) {
        guard let draft = draftLabels[network.fingerprint] else { return }
        draftLabels[network.fingerprint] = nil
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (network.label ?? "") else { return }
        networkIdentity.setLabel(trimmed, for: network)
    }

    /// User label, else the most recent Wi-Fi SSID seen on this network,
    /// else "Ethernet" — mirrors `ContentView.networkDisplay(_:)`'s
    /// fallback chain for the *current* network, but `KnownNetwork` itself
    /// has no persisted SSID or connection-type field to fall back to, so
    /// this reads the one most recent `WiFiSampleRecord` for the
    /// fingerprint instead (same query `NetworkReviewViewModel` uses, just
    /// capped to the single newest row). No Wi-Fi sample ever recorded on
    /// this network is taken as "it's Ethernet" — `WiFiSSIDViewModel`
    /// samples every 60s for as long as a network stays on Wi-Fi, so a
    /// genuinely Wi-Fi network wouldn't have zero samples for long.
    ///
    /// Previously just "Unlabeled network" whenever `label` was nil,
    /// which was *every* network before this row's `TextField` existed to
    /// set one — this fallback means a nil label still doesn't read as
    /// "no information available" when the SSID or connection type is
    /// already known, for the networks a user simply hasn't bothered to
    /// name yet.
    private func displayName(for network: KnownNetwork) -> String {
        if let label = network.label, !label.isEmpty {
            return label
        }
        if let ssid = snapshotStore.fetchWiFiSampleHistory(for: network.fingerprint, limit: 1).first?.ssid,
           !ssid.isEmpty {
            return "\(ssid) (Wi-Fi)"
        }
        return "Ethernet"
    }
}
