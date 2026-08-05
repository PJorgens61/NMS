import SwiftUI

/// Server URL (plain `UserDefaults`, see `FeatureFlags.firewallServerURL`)
/// and device bearer token (Keychain, see `FWKeychain`) for FW
/// (github.com/PJorgens61/FW). Only the URL lives in `@AppStorage` — the
/// token deliberately never touches `UserDefaults`, unlike every other
/// preference in this window.
///
/// No self-serve registration exists yet (single-user scope, see FW's own
/// design notes): the token is generated server-side from `FW_TOKENS` and
/// pasted in here by hand, one paste-and-save rather than saved on every
/// keystroke — same reasoning `DDNSHostnamesSection`'s explicit "Add"
/// button gives for not persisting the in-progress text field live.
struct FirewallVisibilityServerSection: View {
    @AppStorage(FeatureFlags.firewallServerURLKey) private var firewallServerURLString = ""

    @State private var tokenFieldText = ""
    @State private var hasStoredToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("https://your-fw-server.example.com", text: $firewallServerURLString)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("preferences.firewall.serverURL")

            HStack {
                SecureField(hasStoredToken ? "Token saved — paste a new one to replace it" : "Device token", text: $tokenFieldText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("preferences.firewall.token")
                Button("Save") { saveToken() }
                    .disabled(tokenFieldText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("preferences.firewall.token.save")
                    .help("Saves this token to the Keychain — never stored in plain preferences.")
            }

            if hasStoredToken {
                Text("Device token saved to Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .onAppear {
            hasStoredToken = FWKeychain.token() != nil
        }
    }

    private func saveToken() {
        let trimmed = tokenFieldText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, FWKeychain.setToken(trimmed) else { return }
        hasStoredToken = true
        tokenFieldText = ""
    }
}
