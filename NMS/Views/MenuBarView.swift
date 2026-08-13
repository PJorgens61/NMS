import AppKit
import SwiftUI

/// Phase 0 spike content — placeholder data throughout, wired to real
/// view models in Phase 3. Exists right now to de-risk three things
/// before the real popover conversion proceeds (see the plan's Phase 0):
/// whether `.help()` tooltips render inside `MenuBarExtra(.window)`
/// (they didn't in NMS's own pre-rebuild popover), whether the ported
/// icon-tint fix still works, and whether the real proposed row count
/// (Simple: 9, Expert: 10) actually fits without overflow.
struct MenuBarView: View {
    @State private var isExpertMode = false
    /// Real for Phase 2's `Settings` scene conversion, unlike everything
    /// else in this file (still Phase 0's placeholder content) — a plain
    /// SwiftUI environment value, available in any view once the app
    /// declares a `Settings {}` scene, so this doesn't need threading
    /// through from `NMSApp` the way `openDiagnostics` will in Phase 3.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NMS")
                .font(.headline)
            Text("Last refreshed just now")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()

            statusLine(color: .green, label: "MyApps", detail: "All systems operational")
            statusLine(color: .yellow, label: "Internet", detail: "DNS degraded")
                // Spike target for the historical ".help() renders
                // nothing inside MenuBarExtra(.window)" risk.
                .help("DNS resolution is slower than usual — click for details.")
            statusLine(color: .green, label: "MyWifi", detail: "Thistle · -52dBm · Ch 44")

            Text("Wi-Fi -52dBm · Ch 44 · WPA3")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Picker("", selection: $isExpertMode) {
                Text("Simple").tag(false)
                Text("Expert").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("View Network Summary") {}
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            Button("Run Quick Check") {}
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

            if isExpertMode {
                Menu("Run Test") {
                    Button("Trace Now") {}
                    Button("Check DNS") {}
                    Button("Check DHCP Status") {}
                    Button("Run Speed Test") {}
                    Button("Run Apple Test") {}
                    Button("Run Wi-Fi Stress Test") {}
                    Button("Scan") {}
                    Button("Scan Now") {}
                    Button("Renew") {}
                }
            }

            Divider()

            Button("Known Networks…") {}
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            Button("Preferences…") {
                openSettings()
                // Deferred one run-loop turn, same confirmed-working fix
                // `ContentView.openWindowInFront` already needed:
                // `NSApp.activate(ignoringOtherApps:)` is deprecated
                // since macOS 14 and confirmed to actually stop doing
                // anything after that; the modern, no-parameter
                // `NSApplication.activate()` needs no availability guard
                // since this app's deployment target is already 14+.
                DispatchQueue.main.async {
                    NSApp.activate()
                }
            }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

            Text("Build 28d6896 · spike")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(width: 280)
    }

    @ViewBuilder
    private func statusLine(color: Color, label: String, detail: String) -> some View {
        Button {} label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text("\(label): \(detail)")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
