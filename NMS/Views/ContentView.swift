import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @ObservedObject var lanDiscovery: LANDiscoveryViewModel
    @ObservedObject var connectivity: ConnectivityViewModel
    @ObservedObject var networkIdentity: NetworkIdentityViewModel
    @ObservedObject var publicIP: PublicIPViewModel
    @ObservedObject var wifiSSID: WiFiSSIDViewModel

    @State private var labelDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NMS")
                .font(.headline)

            if let info = viewModel.currentInterface {
                Group {
                    if let label = networkIdentity.currentNetwork?.label, !label.isEmpty {
                        row("Network", label)
                    } else if let ssid = wifiSSID.currentSSID {
                        row("Network", ssid)
                    } else {
                        row("Interface", info.displayName ?? info.interfaceName)
                    }
                    row("Type", info.isWiFi ? "Wi-Fi" : "Ethernet")
                    row("IP Address", info.ipAddress ?? "—")
                    row("Subnet Mask", info.subnetMask ?? "—")
                    row("Router", info.routerAddress ?? "—")
                    row("Public IP", publicIP.currentIP ?? (publicIP.isChecking ? "Checking…" : "—"))
                }
            } else {
                Text("No active network connection")
                    .foregroundStyle(.secondary)
            }

            if let error = publicIP.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            networkIdentitySection

            Divider()

            HStack {
                Text("LAN Devices")
                    .font(.headline)
                Spacer()
                Button("Scan") {
                    lanDiscovery.scan()
                }
            }

            deviceList

            if let error = lanDiscovery.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Text("Connectivity")
                    .font(.headline)
                Spacer()
                Button("Check Now") {
                    connectivity.runChecks()
                }
                .disabled(connectivity.isChecking)
            }

            connectivityList

            Divider()

            HStack {
                Button("Refresh") {
                    viewModel.refresh()
                    publicIP.check()
                    wifiSSID.refresh(isWiFi: viewModel.currentInterface?.isWiFi ?? false)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    @ViewBuilder
    private var networkIdentitySection: some View {
        if let network = networkIdentity.currentNetwork {
            HStack {
                Text(networkIdentity.isNewNetwork ? "New network" : "Known network")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("seen \(network.timesSeen)×")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            TextField(wifiSSID.currentSSID ?? "Label this network (e.g. Home)", text: $labelDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit {
                    networkIdentity.setLabel(labelDraft)
                }
                .onChange(of: network.fingerprint, initial: true) {
                    labelDraft = network.label ?? ""
                }
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        if lanDiscovery.devices.isEmpty {
            Text(lanDiscovery.lastScanAt == nil ? "Not scanned yet" : "No devices found")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lanDiscovery.devices) { device in
                        row(device.hostname ?? device.ipAddress, device.hostname == nil ? (device.macAddress ?? "—") : device.ipAddress)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    @ViewBuilder
    private var connectivityList: some View {
        if connectivity.checks.isEmpty {
            Text(connectivity.isChecking ? "Checking…" : "Not checked yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(connectivity.checks) { check in
                    HStack {
                        Text(check.label)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(statusText(for: check))
                            .foregroundStyle(statusColor(for: check))
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 12))
                }
            }

            if connectivity.checks.contains(where: { $0.correlatedWithChange }) {
                Text("* possibly related to a recent network change")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func statusText(for check: ConnectivityCheck) -> String {
        guard check.success else {
            return check.correlatedWithChange ? "unreachable *" : "unreachable"
        }
        return String(format: "%.0f ms", check.latencyMs ?? 0)
    }

    private func statusColor(for check: ConnectivityCheck) -> Color {
        guard !check.success else { return .primary }
        return check.correlatedWithChange ? .orange : .red
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}
