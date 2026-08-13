import AppKit
import SwiftUI

/// The popover conversion's real replacement for `ContentView`'s ten
/// window tiles — glance status plus action triggers only, everything
/// data-dense pushed to the web pages `LocalDiagnosticServer` renders.
/// See the plan doc ("Popover design: Simple/Expert modes") for the full
/// reasoning; this is Phase 3's real view-model wiring, on top of Phase
/// 0's placeholder layout and Phase 2's scene-level plumbing.
struct MenuBarView: View {
    var viewModel: NetworkMonitorViewModel
    var connectivity: ConnectivityViewModel
    var wifiSSID: WiFiSSIDViewModel
    var ethernetLink: EthernetLinkViewModel
    var dhcpLease: DHCPLeaseViewModel
    var traceroute: TracerouteViewModel
    var networkQuality: NetworkQualityViewModel
    var wifiStressTest: WiFiStressTestViewModel
    var snmp: SNMPViewModel
    var saasMonitoring: SaaSMonitoringViewModel
    var firewallVisibility: FirewallVisibilityViewModel
    var pathDiscoveryRunner: PathDiscoveryRunner
    /// For the footer's store-size line (`footerText`) — `StoreSizeService`
    /// itself was untouched by the popover conversion, but nothing called
    /// it anymore once `ContentView`'s footer was deleted in Phase 4
    /// (`PJorgens61/NMS#22`). Passed in rather than read via some shared
    /// app-state object, matching every other view model here.
    var storeURL: URL

    /// Opens a diagnostic-server page in the system browser — see
    /// `NMSApp.openDiagnostics(path:)`. A plain closure, not a direct
    /// `LocalDiagnosticServer` reference, same "keep this view decoupled
    /// from app-level wiring it doesn't own" reasoning RoonWatch's own
    /// `MenuBarView` already established for the identical shape.
    var openDiagnostics: (String) -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @AppStorage("isExpertMode") private var isExpertMode = false

    @AppStorage("hasConfirmedWifiStressTest") private var hasConfirmedWifiStressTest = false
    @AppStorage("hasConfirmedSpeedTest") private var hasConfirmedSpeedTest = false
    @AppStorage("hasConfirmedAppleTest") private var hasConfirmedAppleTest = false
    @AppStorage("hasConfirmedDHCPRenew") private var hasConfirmedDHCPRenew = false
    @AppStorage("hasConfirmedQuickCheck") private var hasConfirmedQuickCheck = false
    @State private var pendingConfirmation: NetworkTestCatalog.Test?
    @State private var isShowingQuickCheckConfirmation = false
    @State private var isRunningQuickCheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NMS")
                .font(.headline)
            Text("Last refreshed \(Date().formatted(.relative(presentation: .named)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()

            if FeatureFlags.saasMonitoring {
                statusLine(color: myAppsStatus.color, label: "MyApps", detail: myAppsDetail, path: "saas")
            }
            statusLine(color: internetStatus.color, label: "Internet", detail: internetDetail, path: "network")
            statusLine(color: localStatus.color, label: localLabel, detail: localDetail, path: "network")
            Text(glanceText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Picker("", selection: $isExpertMode) {
                Text("Simple").tag(false)
                Text("Expert").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("View Network Summary") { openDiagnostics("network") }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            Button(isRunningQuickCheck ? "Running Quick Check…" : "Run Quick Check") {
                if hasConfirmedQuickCheck {
                    runQuickCheck()
                } else {
                    isShowingQuickCheckConfirmation = true
                }
            }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(isRunningQuickCheck)
                .confirmationDialog(
                    "Quick Check runs a bundle of network tests, including real traffic (a ping burst, a speed probe, and an Apple networkQuality check).",
                    isPresented: $isShowingQuickCheckConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Run Quick Check") {
                        hasConfirmedQuickCheck = true
                        runQuickCheck()
                    }
                    Button("Cancel", role: .cancel) {}
                }

            if isExpertMode {
                Menu("Run Test") {
                    ForEach(NetworkTestCatalog.tests) { test in
                        Button(test.label) { trigger(test) }
                    }
                }
                .confirmationDialog(
                    pendingConfirmation?.confirmationText ?? "",
                    isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
                    titleVisibility: .visible
                ) {
                    Button(pendingConfirmation?.label ?? "Run") {
                        if let test = pendingConfirmation {
                            markConfirmed(test)
                            dispatch(test)
                        }
                        pendingConfirmation = nil
                    }
                    Button("Cancel", role: .cancel) { pendingConfirmation = nil }
                }
            }

            Divider()

            Button("Known Networks…") { openWindow(id: "known-networks") }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            Button("Preferences…") {
                openSettings()
                DispatchQueue.main.async {
                    NSApp.activate()
                }
            }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(width: 280)
    }

    // MARK: - Status lines

    private var myAppsStatus: OverallStatus {
        let indicators = saasMonitoring.statuses.map(\.indicator)
        if indicators.contains(where: { $0 == .major || $0 == .critical }) { return .critical }
        if indicators.contains(where: { $0 == .minor || $0 == .maintenance }) { return .marginal }
        return .normal
    }
    private var myAppsDetail: String {
        saasMonitoring.statuses.isEmpty ? "no services monitored" : (myAppsStatus == .normal ? "all systems operational" : "degraded")
    }

    private var internetStatus: OverallStatus {
        OverallStatus.computeInternet(checks: connectivity.checks)
    }
    private var internetDetail: String {
        let failing = connectivity.checks.first { !$0.success && OverallStatus.internetOnlyLabels.contains($0.label) }
        return failing.map { "\($0.label) degraded" } ?? "normal"
    }

    private var dhcpIsAbnormal: Bool {
        dhcpLease.isFallenBackToLinkLocal || dhcpLease.isRenewalOverdue
    }
    private var localStatus: OverallStatus {
        OverallStatus.computeLocal(interfaceIsDown: viewModel.currentInterface == nil, checks: connectivity.checks, dhcpIsAbnormal: dhcpIsAbnormal)
    }
    /// "MyWifi" on Wi-Fi, "Ethernet" when wired — same `currentSSID != nil`
    /// condition `glanceText`/`localDetail` already branch on, kept as its
    /// own property since the label needs it independently of either
    /// (`PJorgens61/NMS#21` — this row used to say "MyWifi" even on
    /// Ethernet, since the popover conversion's design called for the
    /// swap but the follow-up never landed).
    private var localLabel: String {
        wifiSSID.currentSSID != nil ? "MyWifi" : "Ethernet"
    }

    private var localDetail: String {
        if viewModel.currentInterface == nil { return "down" }
        if dhcpIsAbnormal { return "DHCP issue" }
        if let ssid = wifiSSID.currentSSID {
            return "\(ssid)\(wifiSSID.currentRSSI.map { " · \($0)dBm" } ?? "")"
        }
        return "normal"
    }

    private var glanceText: String {
        if let ssid = wifiSSID.currentSSID {
            let channel = wifiSSID.currentChannelNumber.map { "Ch \($0)" } ?? "—"
            let security = wifiSSID.currentSecurity ?? "—"
            return "Wi-Fi \(ssid) · \(channel) · \(security)"
        } else if let speed = ethernetLink.currentSpeedMbps {
            return "Ethernet \(Int(speed)) Mbps"
        }
        return "No active link"
    }

    /// Build hash plus real on-disk store size, read fresh on every
    /// popover open — same "observable rather than theoretical" reasoning
    /// the retention-pruning docs already give for why this line matters
    /// (`README.md`'s "Network activity and privacy" section).
    private var footerText: String {
        let build = BuildInfoService.current().map { "Build \($0.shortHash)" }
        let size = StoreSizeService.formattedSize(at: storeURL)
        return [build, size].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Status line row

    @ViewBuilder
    private func statusLine(color: Color, label: String, detail: String, path: String) -> some View {
        Button {
            openDiagnostics(path)
        } label: {
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

    // MARK: - Run Test dispatch

    private func trigger(_ test: NetworkTestCatalog.Test) {
        if test.requiresConfirmation, !hasAlreadyConfirmed(test) {
            pendingConfirmation = test
        } else {
            dispatch(test)
        }
    }

    private func hasAlreadyConfirmed(_ test: NetworkTestCatalog.Test) -> Bool {
        switch test.id {
        case "wifiStressTest": return hasConfirmedWifiStressTest
        case "speedTest": return hasConfirmedSpeedTest
        case "appleNetworkQuality": return hasConfirmedAppleTest
        case "dhcpRenew": return hasConfirmedDHCPRenew
        default: return true
        }
    }

    private func markConfirmed(_ test: NetworkTestCatalog.Test) {
        switch test.id {
        case "wifiStressTest": hasConfirmedWifiStressTest = true; wifiStressTest.markConfirmed()
        case "speedTest": hasConfirmedSpeedTest = true
        case "appleNetworkQuality": hasConfirmedAppleTest = true
        case "dhcpRenew": hasConfirmedDHCPRenew = true; dhcpLease.markRenewConfirmed()
        default: break
        }
    }

    /// Dispatches to each test's real underlying call — the catalog
    /// supplies the label/confirmation/Quick-Check membership, not the
    /// trigger logic itself (see `NetworkTestCatalog`'s own doc comment).
    /// Every one of these already exists and is already used by a native
    /// tile being retired elsewhere in this migration; this just gives
    /// each one a second caller.
    private func dispatch(_ test: NetworkTestCatalog.Test) {
        let interfaceName = viewModel.currentInterface?.interfaceName
        switch test.id {
        case "traceroute":
            traceroute.run()
        case "pathDiscovery":
            pathDiscoveryRunner.run()
        case "dnsCheck":
            // No standalone "just DNS" trigger exists -- `runDNSCheck` is
            // private to `ConnectivityViewModel`. Runs the full check
            // round instead (DNS included); more than the label promises,
            // but the honest available option rather than exposing new
            // plumbing for a narrower one right now.
            connectivity.runChecks()
        case "dhcpStatus":
            dhcpLease.check()
        case "speedTest":
            networkQuality.run()
        case "appleNetworkQuality":
            networkQuality.runAppleTest(interfaceName: interfaceName)
        case "wifiStressTest":
            if let routerAddress = viewModel.currentInterface?.routerAddress {
                wifiStressTest.run(routerAddress: routerAddress, isWiFi: viewModel.currentInterface?.isWiFi == true)
            }
        case "snmpScan":
            snmp.scan()
        case "firewallScan":
            firewallVisibility.scanNow()
        case "dhcpRenew":
            dhcpLease.renew()
        default:
            break
        }
    }

    private func runQuickCheck() {
        isRunningQuickCheck = true
        let interfaceName = viewModel.currentInterface?.interfaceName
        traceroute.run()
        connectivity.runChecks()
        dhcpLease.check()
        networkQuality.run()
        networkQuality.runQuickCheck(interfaceName: interfaceName)
        if let routerAddress = viewModel.currentInterface?.routerAddress {
            wifiStressTest.run(routerAddress: routerAddress, isWiFi: viewModel.currentInterface?.isWiFi == true)
        }
        // Each test above is fire-and-forget against its own view model
        // (matching how every native tile already triggers these) --
        // there's no single shared "all done" signal to await, so this
        // just opens the summary page rather than blocking the button on
        // a synchronized multi-service completion this app has no
        // existing mechanism for. Results land on /network and /log as
        // each test's own view model finishes, same as clicking each
        // button individually would.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isRunningQuickCheck = false
        }
        openDiagnostics("network")
    }
}
