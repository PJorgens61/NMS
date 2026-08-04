import SwiftUI

/// Mirrors `UserAddedSitesSection` almost exactly — same add/remove list
/// shape, just one `TextField` (a bare hostname, not a nickname+URL
/// pair) instead of two. The check-interval picker only appears once a
/// hostname is actually configured — same "only shown once relevant"
/// pattern `SaaSServicePickerSection`'s own conditional display in
/// `PreferencesView` uses.
///
/// Pulled out of `PreferencesView` into its own `View` type, with its
/// own `@State`, so typing in the hostname field (or an unrelated
/// preference elsewhere in the window changing) doesn't re-evaluate
/// this section's body, and vice versa — see `PUNCHLIST.md`'s
/// view-structure factoring entry. Fully self-contained: `PreferencesView`
/// only places it, never reads its state.
struct DDNSHostnamesSection: View {
    @State private var ddnsHostnames: [FeatureFlags.DDNSHostname] = FeatureFlags.ddnsHostnames
    @State private var newDDNSHostnameText = ""
    /// `@AppStorage`, not plain `@State` — a `TimeInterval` (`Double`) is
    /// one of `@AppStorage`'s supported types, so this can be live with
    /// no manual `UserDefaults` write needed.
    @AppStorage(FeatureFlags.ddnsCheckIntervalKey) private var ddnsCheckIntervalSeconds: Double = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ddnsHostnames) { entry in
                HStack {
                    Text(entry.hostname)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        remove(entry)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(entry.hostname)")
                    .accessibilityIdentifier("preferences.ddns.hostname.remove.\(entry.id)")
                    .help("Remove \(entry.hostname)")
                }
                .font(.system(size: 11))
            }

            HStack {
                TextField("myhome.example.com", text: $newDDNSHostnameText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("preferences.ddns.hostname.text")
                Button("Add") { add() }
                    .disabled(!isNewHostnameValid)
                    .accessibilityIdentifier("preferences.ddns.hostname.add")
                    .help(tooltip(
                        "Adds this hostname to the DDNS staleness check.",
                        technical: "Resolved via dig against Cloudflare's public resolver (1.1.1.1), bypassing this Mac's local DNS cache."
                    ))
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
    /// after trimming, same minimal bar `UserAddedSitesSection`'s own
    /// nickname field sets.
    private var isNewHostnameValid: Bool {
        !newDDNSHostnameText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        guard isNewHostnameValid else { return }
        ddnsHostnames.append(FeatureFlags.DDNSHostname(hostname: newDDNSHostnameText.trimmingCharacters(in: .whitespaces)))
        newDDNSHostnameText = ""
        persist()
    }

    private func remove(_ entry: FeatureFlags.DDNSHostname) {
        ddnsHostnames.removeAll { $0.id == entry.id }
        persist()
    }

    private func persist() {
        FeatureFlags.setDDNSHostnames(ddnsHostnames)
    }
}
