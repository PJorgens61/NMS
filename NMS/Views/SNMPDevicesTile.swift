import SwiftUI

/// SNMP-discovered infrastructure: each row is name + software descriptor
/// + uptime, since those are what identify the device and reveal a
/// restart. The leading dot is live reachability (see
/// `deviceReachability`) — added because a device that restarted and
/// already recovered could otherwise only be told apart from one that's
/// still down by reading Events log ordering, which can itself lag (the
/// slower SNMP-restart detection can log *after* the ping-based recovery
/// for the same episode). This dot answers "is it up right now" directly
/// instead.
///
/// Fifth of the ten window tiles pulled out of `ContentView`'s single
/// body into its own `View` type (see `PUNCHLIST.md`'s `ContentView`
/// fan-in entry) — reads three view models (`snmp` for the device
/// list itself, `viewModel`/`connectivity` only for
/// `deviceReachability`'s router-label lookup), narrower than
/// `ContentView`'s original seventeen but not down to one the way the
/// simpler tiles managed. The community-string inline editor is its own
/// `View` type now too (`CommunityRow`), with its own `@State` — see
/// `PUNCHLIST.md`'s view-structure factoring entry.
struct SNMPDevicesTile: View {
    var snmp: SNMPViewModel
    var viewModel: NetworkMonitorViewModel
    var connectivity: ConnectivityViewModel

    var body: some View {
        tile(
            title: "SNMP Devices",
            fixedHeight: SectionLayout.snmpDevices.boxHeight,
            trailing: {
                // No longer the only way to populate this list —
                // `SNMPViewModel.activate()` now sweeps automatically
                // the first time this feature has nothing rehydrated
                // from history. This stays for the case that leaves:
                // forcing a fresh sweep to find a device added to the
                // LAN after that first discovery, which nothing else
                // triggers.
                Button(snmp.isScanning ? "Scanning…" : "Scan") {
                    snmp.scan()
                }
                .disabled(snmp.isScanning || !snmp.isAvailable)
                .accessibilityLabel(snmp.isScanning ? "Scanning" : "Scan")
                .accessibilityHint("Clears the SNMP device list and sweeps the subnet again")
                .accessibilityIdentifier("snmpDevices.scan")
                .help("Clears the SNMP device list and sweeps the subnet again")
            }
        ) {
            if !snmp.isAvailable {
                Text("snmpget unavailable on this macOS version")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else if snmp.devices.isEmpty {
                Text(snmp.isScanning ? "Sweeping subnet…" : (snmp.lastScanAt == nil ? "Not scanned yet" : "No SNMP devices found"))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                deviceRows
            }

            if let error = snmp.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            CommunityRow(snmp: snmp)
        }
    }

    private var deviceRows: some View {
        ForEach(snmp.devices) { device in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Circle()
                        .fill(statusColor(reachability(device)))
                        .frame(width: 8, height: 8)
                        // Gray is the case this exists for: it means
                        // "no ping result yet," which looks identical to
                        // trouble at a glance and gets misread exactly
                        // when someone is scanning this list during an
                        // outage.
                        .help(Self.reachabilityHelp(reachability(device)))
                    Text(device.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(device.uptimeDescription)
                        .foregroundStyle(.secondary)
                    // After the text, not before — `uptimeDescription`'s
                    // width varies per device ("up 41d 4h" vs "up 4d 0h"),
                    // and this HStack's trailing group is flush-right, so
                    // an icon placed *before* varying-width text shifts
                    // horizontally row to row. Trailing-most keeps it at a
                    // constant position, matching the SaaS section's own
                    // (already correct) icon-after-text order.
                    if let webURL = device.webURL {
                        externalLinkIcon(
                            url: webURL,
                            accessibilityLabel: "\(device.displayName) admin page",
                            accessibilityHint: "Opens \(device.displayName)'s web interface in your browser"
                        )
                    }
                }
                .font(.system(size: 12))
                // No lineLimit here, deliberately — sysDescr (a raw
                // SNMP-provided string, no length guarantee) wraps to as
                // many lines as it needs instead of truncating, unlike
                // the single-line convention used elsewhere in this
                // popover.
                // Always shown, not just when there's more than one
                // address — requested directly ("list the domain name
                // and IP address for each... useful for network
                // engineers"): `displayName` above is often just
                // `sysName`, a short SNMP-configured label ("router"),
                // not the device's actual DNS identity or IP.
                Text(device.addressLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // `aliasAddresses` non-empty means this identity answers
                // at more than one address on the same MAC -- see
                // `SNMPDevice.aliasAddresses`'s own doc comment, which
                // already names VRRP as the case this exists for.
                // "Suspected," not a certainty: ARP evidence alone can't
                // distinguish a VRRP virtual address from other
                // shared-MAC shapes (a router trunking several VLANs,
                // say), so this is a hint pointing at the addresses just
                // shown above, not an assertion.
                if !device.aliasAddresses.isEmpty {
                    // Was plain, unconditional blue with no tooltip at
                    // all — the only such case in the app, and a real
                    // collision once blue started meaning "hover for
                    // more" elsewhere (raised directly: "is this a BLUE
                    // conflict?"). Resolved by giving this label the
                    // tooltip it always should have had — the doc
                    // comment above already had the real "why suspected,
                    // not certain" explanation, just never surfaced in
                    // the UI — rather than picking a different color.
                    // After this, blue-and-underlined means "has a
                    // tooltip" with no exceptions anywhere in the app.
                    let vrrpHelp = "ARP evidence alone can't distinguish a VRRP virtual address from other shared-MAC shapes, like a router trunking several VLANs — a hint pointing at the addresses above, not a certainty."
                    let highlight = FeatureFlags.tooltipHighlights
                    Text("VRRP suspected")
                        .font(.system(size: 10))
                        .foregroundStyle(highlight ? .blue : .secondary)
                        .underline(highlight)
                        .help(vrrpHelp)
                }
                // Split into up to two *fixed-height* lines rather than
                // one auto-wrapping `Text` — deliberately, not the
                // obvious approach. See `ContentView.sysDescrLines`'s own
                // doc comment for why (a real device's sysDescr needing
                // two lines reliably truncated to one inside this
                // section's `ScrollView` box specifically, and every fix
                // tried for that reintroduced a worse bug — see
                // `BUGS.md`'s "SNMP device sysDescr truncates" entry).
                ForEach(Array(ContentView.sysDescrLines(device.sysDescr).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private func reachability(_ device: SNMPDevice) -> LayerStatus {
        let label = device.ipAddress == viewModel.currentInterface?.routerAddress
            ? OverallStatus.routerLabel
            : device.displayName
        guard let check = connectivity.checks.first(where: { $0.label == label }) else {
            return .unknown
        }
        return check.success ? .healthy : .unhealthy
    }

    /// Only the `.unknown` case really needs explaining — green and red
    /// read themselves — but all three are worded so hovering any dot
    /// answers the same question rather than leaving one silent.
    private static func reachabilityHelp(_ status: LayerStatus) -> String {
        switch status {
        case .healthy:
            return "Reachable — answered the most recent ping."
        case .unhealthy:
            return "Unreachable — did not answer the most recent ping."
        case .unknown:
            return """
                Not checked yet — this device has no ping result in the \
                current round, which is not the same as being down. The \
                router is checked under its own Network Health row, and \
                only the first few discovered devices are pinged each \
                round.
                """
        }
    }

    private func statusColor(_ status: LayerStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .unknown: return .gray
        case .unhealthy: return .red
        }
    }

}
