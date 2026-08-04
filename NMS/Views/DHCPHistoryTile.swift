import SwiftUI

/// Every real DHCP lease change (server, address, or timing actually
/// differed — see `SnapshotStore.recordDHCPLeaseIfChanged`), newest first
/// — new rows appear at the top and push earlier ones down into the
/// scroll. The newest row doubles as "the current lease" — there's no
/// separate current-lease display now that this list exists. Two lines
/// per lease, every parsed field included across the two (see
/// `DHCPLeaseRecord.primaryDetail`/`secondaryDetail`) — a single
/// unbroken line was tried first, but the full field set (server,
/// address, broadcast, gateway, DNS, domain, lease/T1/T2, transaction
/// ID) measured out to roughly 950-1000pt to fit without truncating,
/// confirmed directly against a real lease — too wide for a menu-bar
/// popover. Wrapping to two lines fits comfortably at this popover's
/// current (doubled) width instead.
///
/// Last of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry) — holds only the one view model it actually
/// reads. The Renew-confirmation alert's `@State` moved here too, same
/// reasoning as `SNMPDevicesTile`'s community-editing state: purely
/// local UI state with no reason to live on `ContentView` once this
/// section is its own type.
struct DHCPHistoryTile: View {
    var dhcpLease: DHCPLeaseViewModel

    @State private var isShowingDHCPRenewConfirmation = false

    var body: some View {
        tile(
            title: "DHCP History",
            fixedHeight: SectionLayout.dhcpHistory.boxHeight,
            trailing: {
                Button(dhcpLease.isRenewing ? "Renewing…" : "Renew") {
                    if dhcpLease.hasConfirmedRenewBefore {
                        dhcpLease.renew()
                    } else {
                        isShowingDHCPRenewConfirmation = true
                    }
                }
                .disabled(dhcpLease.isRenewing || !DHCPLeaseService.isAvailable)
                .accessibilityLabel(dhcpLease.isRenewing ? "Renewing" : "Renew DHCP Lease")
                .accessibilityHint("Forces a fresh DHCP negotiation on this Mac's active interface. Briefly disrupts the connection and may prompt for an administrator password.")
                .accessibilityIdentifier("dhcpHistory.renew")
                .help(tooltip(
                    "Forces a fresh DHCP negotiation on this Mac's active interface. Briefly disrupts the connection and may prompt for an administrator password.",
                    technical: "Uses scutil --renew — the same mechanism System Settings' own \"Renew DHCP Lease\" button uses."
                ))
                // Attached directly to the button, same established
                // local-attachment pattern the Local Stress Test tile's
                // own confirmation alert uses.
                .alert("Renew DHCP Lease?", isPresented: $isShowingDHCPRenewConfirmation) {
                    Button("Continue") {
                        dhcpLease.markRenewConfirmed()
                        dhcpLease.renew()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This forces a fresh DHCP negotiation on this Mac's active interface, briefly disrupting the connection, and may prompt for an administrator password — continue?")
                }
            }
        ) {
            if !DHCPLeaseService.isAvailable {
                Text("ipconfig unavailable on this macOS version")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else if dhcpLease.history.isEmpty {
                Text("No DHCP lease observed yet")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                historyRows
            }
        }
    }

    private var historyRows: some View {
        ForEach(dhcpLease.history) { record in
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
                    // 2, not 1 -- with clientHardwareAddress added
                    // alongside the transaction ID, this line got long
                    // enough to truncate mid-word (e.g. "lease 24h"
                    // clipped to "l...4h") on a real, populated row.
                    // Letting it wrap to a second line instead reads
                    // cleanly; truncation is still the fallback if even
                    // two lines isn't enough.
                    .lineLimit(2)
                    .truncationMode(.middle)
                    // The densest jargon in the app, and the reason
                    // tooltips were built at all. Explains only the
                    // genuinely opaque parts — bcast/gw/dns need no
                    // gloss for this app's audience, while T1/T2 and a
                    // bare hex transaction ID do.
                    .help(DHCPLeaseRecord.transactionHelpText)
            }
        }
    }
}
