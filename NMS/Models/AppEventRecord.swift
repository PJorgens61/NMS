import Foundation
import SwiftData

/// The kinds of events worth logging to the app's event timeline. Deliberately
/// narrow — this is for "something worth noticing happened," not a catch-all
/// debug log. Each bad-state kind has a matching recovery kind, so an outage
/// is bracketed by two events (start and end) rather than only ever showing
/// when things broke.
enum AppEventKind: String, Codable {
    case interfaceDown
    case interfaceUp
    case interfaceChanged
    /// Moved between two named Wi-Fi networks. Deliberately distinct from
    /// `interfaceChanged`, which only fires when the *physical* interface
    /// changes (Ethernet ↔ Wi-Fi) — roaming from one SSID to another keeps
    /// the same `en1`, so nothing in `NetworkInterfaceInfo` identifies it
    /// and no event was logged at all. Confirmed against a real session
    /// switching Thistle → ThistleGuest: the network changed subnet,
    /// router and DNS server, and the only events were a generic
    /// interfaceDown/interfaceUp pair that named neither network.
    case wifiNetworkChanged
    case routerUnreachable
    case routerReachable
    case internetUnreachable
    case internetReachable
    case dnsUnreachable
    case dnsReachable
    case httpUnreachable
    case httpReachable
    case peRouterUnreachable
    case peRouterReachable
    case publicIPChanged
    /// Pinging the router's own public/WAN address, not a change in what
    /// that address *is* — see `publicIPChanged` for that. Distinct from
    /// `internetUnreachable`/`Reachable` (a real remote host) and
    /// `routerUnreachable`/`Reachable` (the router's LAN-side address).
    case publicIPUnreachable
    case publicIPReachable
    case infrastructureUnreachable
    case infrastructureReachable
    /// An SNMP device's uptime counter went *backwards* — it restarted.
    /// Logged only when nothing explains it (see
    /// `snmpDeviceSoftwareChanged`), so this is the genuinely unplanned
    /// case worth alarming about.
    case snmpDeviceRestarted
    /// An SNMP device's `sysDescr` changed, meaning its software/firmware
    /// version did. Also covers a restart that happened *together* with
    /// such a change — a reboot that follows an upgrade is explained, not
    /// mysterious, so it's deliberately not the alarming
    /// `snmpDeviceRestarted`.
    case snmpDeviceSoftwareChanged
    /// A DHCP renewal or rebind succeeded and the lease's content actually
    /// differs from before (new server, address, or timing) — not logged
    /// for a renewal that returns the exact same values, and not for the
    /// very first-ever observation (nothing to compare against yet).
    case dhcpLeaseChanged
    /// The interface fell back to a self-assigned (APIPA, 169.254.x.x)
    /// address — DHCP has genuinely failed, not just gone quiet. See
    /// DESIGN-NOTES.md's "DHCP lease tracking," Signal 1.
    case dhcpFellBackToLinkLocal
    case dhcpAddressRestored
    /// The DHCP transaction ID hasn't changed past its own lease's T2
    /// (rebinding) deadline — the client should have started renewing by
    /// now and hasn't. See DESIGN-NOTES.md's "DHCP lease tracking",
    /// Signal 2.
    case dhcpRenewalOverdue
    case dhcpRenewalRecovered
    /// A user-triggered popover screenshot, not a state transition —
    /// logged specifically so the file it produced can be found later by
    /// reading the event log instead of guessing which file on disk is
    /// the relevant one (or worse, which file with a name containing
    /// spaces is the relevant one — see `ScreenshotService`'s fixed,
    /// space-free filename format). See DESIGN-NOTES.md.
    case screenshotCaptured
    /// A configured printer's own CUPS-reported fault state
    /// (`printer-state-reasons` — out of paper, cover open, toner low,
    /// etc.) went from clear to non-empty. Distinct from
    /// `infrastructureUnreachable`: a printer can report this while still
    /// fully reachable on the network — this is about the physical
    /// device's state, not connectivity. See
    /// `PrinterDiscoveryService.printerAlerts()`.
    case printerAlert
    case printerAlertCleared

    enum Polarity {
        case positive, negative, neutral
    }

    /// Recoveries render as positive (green), bad states as negative (red);
    /// a public IP change, an interface failover, or an SNMP device's
    /// software changing is neither — it's just information, not a problem
    /// or a fix — so those render neutral. See `ContentView.eventColor`.
    var polarity: Polarity {
        switch self {
        case .interfaceUp, .routerReachable, .internetReachable, .dnsReachable, .httpReachable, .peRouterReachable,
             .infrastructureReachable, .publicIPReachable, .dhcpAddressRestored, .dhcpRenewalRecovered, .printerAlertCleared:
            return .positive
        case .interfaceDown, .routerUnreachable, .internetUnreachable, .dnsUnreachable, .httpUnreachable, .peRouterUnreachable,
             .infrastructureUnreachable, .snmpDeviceRestarted, .publicIPUnreachable, .dhcpFellBackToLinkLocal, .dhcpRenewalOverdue,
             .printerAlert:
            return .negative
        case .publicIPChanged, .interfaceChanged, .wifiNetworkChanged, .snmpDeviceSoftwareChanged, .dhcpLeaseChanged,
             .screenshotCaptured:
            return .neutral
        }
    }
}

/// A single entry in the app's event log. Logged only on state transitions
/// (see `NetworkMonitorViewModel` and `ConnectivityViewModel`), not
/// repeatedly while a condition persists — otherwise a router that's down
/// for an hour would produce one row per connectivity-check cycle.
@Model
final class AppEventRecord {
    var kind: String
    var message: String
    var occurredAt: Date
    /// Which `KnownNetwork.fingerprint` this happened on — see
    /// `SnapshotStore.currentNetworkFingerprint`. `nil` only when the
    /// network genuinely hadn't been recognized yet at the moment this was
    /// logged (e.g. right at launch, before the first LAN scan resolves
    /// the router's MAC); such a row won't match any specific network's
    /// filter and so simply won't show under any of them, rather than
    /// risking it showing under whichever network happens to be current
    /// later. See DESIGN-NOTES.md's "Per-network device scoping."
    var networkFingerprint: String?

    init(kind: AppEventKind, message: String, occurredAt: Date = Date(), networkFingerprint: String? = nil) {
        self.kind = kind.rawValue
        self.message = message
        self.occurredAt = occurredAt
        self.networkFingerprint = networkFingerprint
    }
}

/// Needed because this is a `@Model` *class*: unlike the struct-backed
/// values elsewhere in the UI state log, its default `String(describing:)`
/// output is just the bare type name, which would make every logged event
/// list read `[NMS.AppEventRecord, NMS.AppEventRecord]`. Debug-only
/// tooling; see `UIStateLogger`.
extension AppEventRecord: UIStateLoggable {
    var uiStateDescription: String {
        "\(kind): \(message)"
    }
}
