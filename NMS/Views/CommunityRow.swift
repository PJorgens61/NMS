import SwiftUI

/// The SNMP Devices tile's community-string inline editor. Community
/// strings are shared read-only passwords, not per-user secrets, and
/// "public" is the near-universal default — so they're editable inline
/// rather than hidden behind a settings window this app doesn't have.
/// Comma-separated, and the order shown is the order they're tried in.
///
/// Pulled out of `SNMPDevicesTile` into its own `View` type, with its own
/// `@State` — see `PUNCHLIST.md`'s view-structure factoring entry. Typing
/// in the draft text field used to re-evaluate `SNMPDevicesTile`'s whole
/// body, including its unrelated device `ForEach`, on every keystroke;
/// now only this row's own body reruns.
struct CommunityRow: View {
    var snmp: SNMPViewModel

    @State private var draft: String = ""
    @State private var isEditing = false

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    TextField("public, private", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { commit() }
                    Button("Set") { commit() }
                        .accessibilityLabel("Set community strings")
                        .accessibilityIdentifier("snmpDevices.setCommunity")
                        .help("Saves these community strings and closes the editor")
                        .font(.system(size: 11))
                }
                Text("Comma-separated, tried in order — put the most common first.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        } else if snmp.isAvailable {
            HStack {
                Text("Community: \(snmp.communities.joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change") {
                    draft = snmp.communities.joined(separator: ", ")
                    isEditing = true
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Change community strings")
                .accessibilityHint("Edits the SNMP community strings used for discovery")
                .accessibilityIdentifier("snmpDevices.changeCommunity")
                .help("Edits the SNMP community strings used for discovery")
            }
        }
    }

    private func commit() {
        snmp.setCommunities(draft)
        isEditing = false
    }
}
