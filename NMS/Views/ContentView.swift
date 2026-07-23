import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @ObservedObject var lanDiscovery: LANDiscoveryViewModel
    @ObservedObject var connectivity: ConnectivityViewModel
    @ObservedObject var networkIdentity: NetworkIdentityViewModel
    @ObservedObject var publicIP: PublicIPViewModel
    @ObservedObject var wifiSSID: WiFiSSIDViewModel
    @ObservedObject var eventLog: EventLogViewModel
    @ObservedObject var traceroute: TracerouteViewModel
    @ObservedObject var bonjourDiscovery: BonjourDiscoveryViewModel

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
                Text("Bonjour Devices")
                    .font(.headline)
                Spacer()
                Button("Scan") {
                    bonjourDiscovery.scan()
                }
                .disabled(bonjourDiscovery.isScanning)
            }

            bonjourDeviceList

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

            Text("Events")
                .font(.headline)

            eventList

            Divider()

            HStack {
                Text("Path to Internet")
                    .font(.headline)
                Spacer()
                Button("Trace Now") {
                    traceroute.run()
                }
                .disabled(traceroute.isRunning)
            }

            tracerouteSection

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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A fixed (not max) height — as with the event log earlier,
            // `maxHeight` alone can collapse this ScrollView to zero
            // visible height in this MenuBarExtra popover even with real
            // content (confirmed directly: a screenshot showed this
            // section completely blank while the same devices were
            // visibly in use elsewhere in the popover, proving the
            // underlying data wasn't actually empty).
            .frame(height: 140)
        }
    }

    @ViewBuilder
    private var bonjourDeviceList: some View {
        if bonjourDiscovery.devices.isEmpty {
            Text(bonjourDiscovery.isScanning ? "Scanning…" : (bonjourDiscovery.lastScanAt == nil ? "Not scanned yet" : "No devices found"))
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bonjourDiscovery.devices) { device in
                        HStack {
                            Text(device.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(device.serviceLabel)
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Same fixed-height fix as `deviceList` above.
            .frame(height: 140)
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

    @ViewBuilder
    private var eventList: some View {
        if eventLog.events.isEmpty {
            Text("No events yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .frame(height: 300, alignment: .top)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(eventLog.events) { event in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.message)
                                .font(.system(size: 12))
                                .foregroundStyle(eventColor(for: event))
                            Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A fixed (not max) height — `maxHeight` alone lets the
            // ScrollView shrink to fit however few rows currently exist,
            // which is why a single event looked identical to before.
            .frame(height: 300)
        }
    }

    @ViewBuilder
    private var tracerouteSection: some View {
        if let monitored = traceroute.monitoredHop {
            row("ISP Edge Router", monitored.hostname ?? monitored.address ?? "—")
            Button("Stop monitoring hop \(monitored.hopNumber)") {
                traceroute.monitorHop(nil)
            }
            .font(.system(size: 11))
        } else if let suggested = traceroute.suggestedEdgeHop {
            row("Suggested (unconfirmed)", suggested.hostname ?? suggested.address ?? "—")
            Text("Tap ★ next to the real ISP hop below to confirm — the first non-local hop isn't always right on networks with their own public IP space (e.g. campus/enterprise).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if traceroute.isRunning {
            Text("Tracing…")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else if traceroute.hops.isEmpty {
            Text("Not traced yet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }

        if let error = traceroute.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }

        if !traceroute.hops.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(displayedHops) { hop in
                        HStack {
                            Text("\(hop.hopNumber)")
                                .foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .trailing)
                            Text(hopLabel(for: hop))
                                .foregroundStyle(hopColor(for: hop))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(hopRTT(for: hop))
                                .foregroundStyle(.secondary)
                            Button {
                                let isMonitored = traceroute.monitoredHopNumber == hop.hopNumber
                                traceroute.monitorHop(isMonitored ? nil : hop.hopNumber)
                            } label: {
                                Image(systemName: traceroute.monitoredHopNumber == hop.hopNumber ? "star.fill" : "star")
                            }
                            .buttonStyle(.plain)
                            .disabled(hop.address == nil)
                        }
                        .font(.system(size: 11))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
        }
    }

    /// Once a hop is confirmed as the one to monitor, hops beyond it (closer
    /// to the actual destination, e.g. `1.1.1.1`) aren't relevant to "the
    /// path to my ISP" and just add noise — so they're hidden. Before
    /// confirmation, the full path still shows, since you need to see hops
    /// beyond the auto-suggested one to pick a different, correct one on
    /// networks where the suggestion doesn't hold (see `suggestedEdgeHop`).
    private var displayedHops: [TracerouteHop] {
        guard let monitoredHopNumber = traceroute.monitoredHopNumber else { return traceroute.hops }
        return traceroute.hops.filter { $0.hopNumber <= monitoredHopNumber }
    }

    private func hopLabel(for hop: TracerouteHop) -> String {
        guard let address = hop.address else { return "* (no response)" }
        return hop.hostname ?? address
    }

    private func hopColor(for hop: TracerouteHop) -> Color {
        if traceroute.monitoredHopNumber == hop.hopNumber {
            return .blue
        }
        switch hop.isLocal {
        case true: return .secondary
        case false: return .primary
        case nil: return .secondary
        }
    }

    private func hopRTT(for hop: TracerouteHop) -> String {
        guard let rtt = hop.roundTripMs else { return "—" }
        return String(format: "%.0f ms", rtt)
    }

    private func eventColor(for event: AppEventRecord) -> Color {
        guard let kind = AppEventKind(rawValue: event.kind) else { return .primary }
        return kind.isPositive ? .green : .red
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
