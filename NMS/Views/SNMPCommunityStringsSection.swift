import SwiftUI

/// The SNMP community-string editor — dropped when `SNMPDevicesTile` (the
/// old popover's inline field) was deleted in the menu bar popover
/// conversion and never rebuilt, confirmed as a real, previously-unfiled
/// gap (`PJorgens61/NMS#19`) rather than a deliberate cut.
///
/// Fully self-contained, same "`PreferencesView` only places it, never
/// reads its state" convention `DDNSHostnamesSection`/
/// `SaaSServicePickerSection` already establish — but unlike those, this
/// one has a live counterpart (`SNMPViewModel`) actually running in a
/// *different* scene instance (the popover's `MenuBarExtra`, not this
/// `Settings` scene), so there's no object reference to bind directly.
/// Writes `SNMPViewModel.communitiesDefaultsKey` straight to
/// `UserDefaults` instead — `SNMPViewModel.observeUserDefaultsChanges`
/// is what picks the change up and re-scans.
struct SNMPCommunityStringsSection: View {
    @State private var communitiesText: String = SNMPCommunityStringsSection.currentText()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("public", text: $communitiesText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("preferences.snmp.communities.text")
                    .onSubmit(commit)
                Button("Save") { commit() }
                    .accessibilityIdentifier("preferences.snmp.communities.save")
            }
            Text("Comma-separated, tried in order. Editing this re-scans with the new strings.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func commit() {
        let resolved = SNMPViewModel.resolvedCommunities(from: communitiesText)
        UserDefaults.standard.set(resolved, forKey: SNMPViewModel.communitiesDefaultsKey)
        // Reflect back whatever was actually resolved (trimmed, deduped,
        // defaulted-if-empty) rather than leaving the field showing raw
        // input that doesn't match what got saved.
        communitiesText = resolved.joined(separator: ", ")
    }

    /// Mirrors `SNMPViewModel.init`'s own fallback chain (current key,
    /// then the pre-multi-string legacy key, then the default) so this
    /// field shows the real effective value on first open rather than a
    /// blank field when only the legacy key has ever been set.
    private static func currentText() -> String {
        let defaults = UserDefaults.standard
        if let stored = defaults.stringArray(forKey: SNMPViewModel.communitiesDefaultsKey), !stored.isEmpty {
            return stored.joined(separator: ", ")
        }
        if let legacy = defaults.string(forKey: SNMPViewModel.legacyCommunityDefaultsKey), !legacy.isEmpty {
            return legacy
        }
        return SNMPViewModel.defaultCommunity
    }
}
