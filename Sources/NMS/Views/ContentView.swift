import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @ObservedObject var lanDiscovery: LANDiscoveryViewModel
    @ObservedObject var connectivity: ConnectivityViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NMS")
                .font(.headline)

            if let info = viewModel.currentInterface {
                Group {
                    row("Interface", info.displayName ?? info.interfaceName)
                    row("Type", info.isWiFi ? "Wi-Fi" : "Ethernet")
                    row("IP Address", info.ipAddress ?? "—")
                    row("Subnet Mask", info.subnetMask ?? "—")
                    row("Router", info.routerAddress ?? "—")
                }
            } else {
                Text("No active network connection")
                    .foregroundStyle(.secondary)
            }

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
