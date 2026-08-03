import SwiftUI
import AppKit

/// A read-only look at a past network's recorded Events/SNMP Devices/DHCP
/// History/Wi-Fi telemetry — opened from `KnownNetworksView`'s "Review"
/// button, for a field technician revisiting a site who wants to see what
/// this Mac last saw there without being on that network right now. No
/// Scan or Refresh here, deliberately: those verbs only mean something
/// while actually connected to the network in question. See
/// `NetworkReviewViewModel` for why this reads via explicit-fingerprint
/// `SnapshotStore` overloads rather than the live `currentNetworkFingerprint`
/// path every other view in this app uses.
struct NetworkReviewView: View {
    @StateObject private var viewModel: NetworkReviewViewModel
    @Environment(\.dismiss) private var dismiss

    init(network: KnownNetwork, snapshotStore: SnapshotStore) {
        _viewModel = StateObject(wrappedValue: NetworkReviewViewModel(network: network, snapshotStore: snapshotStore))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                sections
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("networkReview.close")
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 420)
        .onAppear { viewModel.load() }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Events", isEmpty: viewModel.events.isEmpty, emptyText: "No events recorded on this network") {
                eventRows
            }
            section("SNMP Devices", isEmpty: viewModel.snmpDevices.isEmpty, emptyText: "No SNMP devices recorded on this network") {
                snmpRows
            }
            section("DHCP History", isEmpty: viewModel.dhcpHistory.isEmpty, emptyText: "No DHCP leases recorded on this network") {
                dhcpRows
            }
            section("Wi-Fi", isEmpty: viewModel.wifiSamples.isEmpty, emptyText: "No Wi-Fi samples recorded on this network") {
                wifiRows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .font(.title3.weight(.semibold))
            Text("\(viewModel.network.routerMAC) on \(viewModel.network.subnet)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("seen \(viewModel.network.timesSeen)× · last \(viewModel.network.lastSeenAt, format: .dateTime.month().day().year().hour().minute())")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Same label → Wi-Fi SSID → "Ethernet" fallback as
    /// `KnownNetworksView.displayName(for:)`, reading `viewModel.wifiSamples`
    /// (already fetched, newest-first) instead of a second store query.
    private var displayName: String {
        if let label = viewModel.network.label, !label.isEmpty {
            return label
        }
        if let ssid = viewModel.wifiSamples.first?.ssid, !ssid.isEmpty {
            return "\(ssid) (Wi-Fi)"
        }
        return "Ethernet"
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        isEmpty: Bool,
        emptyText: String,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                rows()
            }
        }
    }

    private var eventRows: some View {
        ForEach(viewModel.events) { event in
            HStack {
                Text(event.message)
                    .font(.system(size: 12))
                    .foregroundStyle(eventColor(for: event))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func eventColor(for event: AppEventRecord) -> Color {
        guard let kind = AppEventKind(rawValue: event.kind) else { return .primary }
        switch kind.polarity {
        case .positive: return .green
        case .negative: return .red
        case .neutral: return .primary
        }
    }

    private var snmpRows: some View {
        ForEach(viewModel.snmpDevices) { device in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(device.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(device.uptimeDescription)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                Text(device.sysDescr)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dhcpRows: some View {
        ForEach(viewModel.dhcpHistory) { record in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(record.primaryDetail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(record.observedAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                Text(record.secondaryDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(DHCPLeaseRecord.transactionHelpText)
            }
        }
    }

    private var wifiRows: some View {
        ForEach(viewModel.wifiSamples) { sample in
            HStack {
                Text(sample.ssid ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(wifiDetail(sample))
                    .foregroundStyle(.secondary)
                Text(sample.sampledAt, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
    }

    private func wifiDetail(_ sample: WiFiSampleRecord) -> String {
        var parts: [String] = []
        if let rssi = sample.rssi { parts.append("\(rssi) dBm") }
        if let band = sample.channelBand, let channel = sample.channelNumber {
            parts.append("\(band) ch \(channel)")
        }
        if let phyRateMbps = sample.phyRateMbps { parts.append("\(Int(phyRateMbps)) Mbps") }
        return parts.joined(separator: " · ")
    }
}
