import SwiftUI

/// FW (github.com/PJorgens61/FW) scan history — what's actually reachable
/// on this Mac's own public IP from outside, tested from a real vantage
/// point beyond the NAT rather than inferred locally. Newest scan first,
/// same "newest row doubles as current state" shape `DHCPHistoryTile`
/// uses — each row is the open-port count plus when it ran; a scan with
/// nothing open shows that explicitly rather than an empty-looking row,
/// since "confirmed nothing's exposed" is itself the reassuring result
/// this section exists to show.
struct FirewallVisibilityTile: View {
    var firewallVisibility: FirewallVisibilityViewModel

    var body: some View {
        tile(
            title: "Firewall Visibility",
            fixedHeight: SectionLayout.firewallVisibility.boxHeight,
            trailing: {
                Button(firewallVisibility.isScanning ? "Scanning…" : "Scan Now") {
                    firewallVisibility.scanNow()
                }
                .disabled(firewallVisibility.isScanning)
                .accessibilityLabel(firewallVisibility.isScanning ? "Scanning" : "Scan Now")
                .accessibilityHint("Asks FW to test what's reachable on this Mac's own public IP from outside")
                .accessibilityIdentifier("firewallVisibility.scanNow")
                .help(tooltip(
                    "Tests what's actually reachable on this connection's public IP from outside — a real check from beyond your router, not a local guess.",
                    technical: "Requests a scan from FW (an internet-hosted companion service), then polls for the result. Only runs while the current network is marked home."
                ))
            }
        ) {
            if firewallVisibility.history.isEmpty {
                Text(firewallVisibility.isScanning ? "Scanning…" : "Not scanned yet")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                historyRows
            }

            if let error = firewallVisibility.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private var historyRows: some View {
        ForEach(firewallVisibility.history) { record in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(summary(for: record))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(record.openPorts.isEmpty ? .secondary : .primary)
                    Spacer()
                    Text(record.scannedAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                if let address = record.targetIPv4 ?? record.targetIPv6.first {
                    Text(address)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summary(for record: FirewallScanRecord) -> String {
        record.openPorts.isEmpty
            ? "Nothing open (\(record.results.count) ports checked)"
            : "Open: \(record.openPorts.map(String.init).joined(separator: ", "))"
    }
}
