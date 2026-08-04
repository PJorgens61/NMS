import SwiftUI

/// A user's own sites, checked for plain reachability rather than a
/// real status page — see `SaaSMonitoringViewModel.checkUserAddedSites`'s
/// doc comment for why these are reported separately in the live UI, not
/// folded into the curated list: this is a weaker, network-dependent
/// signal ("is this domain answering right now"), not a real vendor
/// incident, and showing it identically to the curated table would
/// overstate its confidence. Indented under "SaaS Monitoring" the same
/// way `SaaSServicePickerSection` is, since it's a sub-preference of the
/// same toggle, not a separate feature.
///
/// Pulled out of `PreferencesView` into its own `View` type, with its
/// own `@State`, so typing in the nickname/URL fields (or an unrelated
/// preference elsewhere in the window changing) doesn't re-evaluate
/// this section's body, and vice versa — see `PUNCHLIST.md`'s
/// view-structure factoring entry. Fully self-contained: `PreferencesView`
/// only shows or hides it, never reads its state.
struct UserAddedSitesSection: View {
    @State private var userAddedSites: [FeatureFlags.UserAddedSaaSSite] = FeatureFlags.userAddedSaaSSites
    @State private var newSiteNickname = ""
    @State private var newSiteURLText = ""

    var body: some View {
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
                        remove(site)
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
                Button("Add") { add() }
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

    private func add() {
        guard isNewSiteValid else { return }
        userAddedSites.append(
            FeatureFlags.UserAddedSaaSSite(
                url: newSiteURLText.trimmingCharacters(in: .whitespaces),
                nickname: newSiteNickname.trimmingCharacters(in: .whitespaces)
            )
        )
        newSiteNickname = ""
        newSiteURLText = ""
        persist()
    }

    private func remove(_ site: FeatureFlags.UserAddedSaaSSite) {
        userAddedSites.removeAll { $0.id == site.id }
        persist()
    }

    private func persist() {
        FeatureFlags.setUserAddedSaaSSites(userAddedSites)
    }
}
