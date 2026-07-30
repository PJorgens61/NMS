import SwiftUI

/// A separate window (not a popover section) listing every network this
/// Mac has connected to before, with a way to forget one entirely. Kept
/// out of the main popover/window deliberately — see the "Known Networks
/// UI" decision in the conversation this shipped from: a dedicated place
/// costs an extra click to reach, but keeps Events/SNMP Devices/DHCP
/// History from also having to make room for a list that's only relevant
/// occasionally.
struct KnownNetworksView: View {
    @ObservedObject var networkIdentity: NetworkIdentityViewModel
    let snapshotStore: SnapshotStore

    /// The network currently shown in the Review sheet — `nil` when
    /// closed. A `.sheet(item:)` rather than a new `Window` scene:
    /// Known Networks is already a separate, resizable window, and a new
    /// Scene for a single on-demand view is exactly the kind of
    /// conditional-Scene machinery that has twice crashed this project's
    /// compiler (see DESIGN-NOTES.md's "Feature flags" section) — a sheet
    /// sidesteps that class of bug entirely.
    @State private var reviewingNetwork: KnownNetwork?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Known Networks")
                .font(.headline)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 6)

            if networkIdentity.knownNetworks.isEmpty {
                Text("No networks recorded yet.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .padding(12)
            } else {
                List {
                    ForEach(networkIdentity.knownNetworks, id: \.fingerprint) { network in
                        row(for: network)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 240)
        .onAppear { networkIdentity.refreshKnownNetworks() }
        .sheet(item: $reviewingNetwork) { network in
            NetworkReviewView(network: network, snapshotStore: snapshotStore)
        }
    }

    @ViewBuilder
    private func row(for network: KnownNetwork) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(network.label?.isEmpty == false ? network.label! : "Unlabeled network")
                    .font(.system(size: 13, weight: .medium))
                Text("\(network.routerMAC) on \(network.subnet)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("seen \(network.timesSeen)× · last \(network.lastSeenAt, format: .dateTime.month().day().hour().minute())")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if networkIdentity.currentNetwork?.fingerprint == network.fingerprint {
                Text("Current")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Button {
                reviewingNetwork = network
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Review \(network.label ?? network.routerMAC)")
            .accessibilityHint("Opens a read-only view of this network's recorded events, SNMP devices, DHCP history, and Wi-Fi telemetry")
            Button(role: .destructive) {
                networkIdentity.deleteNetwork(network)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forget \(network.label ?? network.routerMAC)")
            .accessibilityHint("Deletes this network and every event, DHCP lease, and SNMP device recorded on it")
        }
        .padding(.vertical, 2)
    }
}
