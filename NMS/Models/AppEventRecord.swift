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
    /// A user-triggered bug report: the same screenshot/state-dump bundle
    /// as `screenshotCaptured`, plus a free-text comment describing what
    /// the user actually observed — the one thing the automated capture
    /// can't infer on its own. Deliberately a distinct kind rather than
    /// folding into `screenshotCaptured`: the two buttons have different
    /// purposes (fast, no-prompt capture vs. "something's wrong, here's
    /// context"), and collapsing them would make it impossible to tell,
    /// from the event log alone, which screenshots were ever meant to be
    /// read as reports. `message` carries the comment itself, so this
    /// event is directly useful in the Events list, not just a pointer to
    /// a file — see `ScreenshotViewModel.captureBugReport`.
    case bugReportCaptured
    /// A configured printer's own CUPS-reported fault state
    /// (`printer-state-reasons` — out of paper, cover open, toner low,
    /// etc.) went from clear to non-empty. Distinct from
    /// `infrastructureUnreachable`: a printer can report this while still
    /// fully reachable on the network — this is about the physical
    /// device's state, not connectivity. See
    /// `PrinterDiscoveryService.printerAlerts()`.
    case printerAlert
    case printerAlertCleared
    /// More than one non-internet hop precedes the real internet on the
    /// traced path — either the customer's own router chained behind
    /// another NAT'ing device, or the ISP's own carrier-grade NAT.
    /// Informational, like `publicIPChanged`, not a failure: this is
    /// about what "Public IP" means for this connection (shared with
    /// other customers, or not directly reachable from outside), not a
    /// health problem. One kind covers both directions, message text
    /// differs — same shape as `interfaceChanged`. See
    /// `TracerouteViewModel.leadingNonInternetHopCount`.
    case multipleNATLayersDetected
    /// A monitored business SaaS service's status-page indicator moved
    /// off/onto "none" — see `SaaSMonitoringViewModel`. One generic pair
    /// for any of the monitored services (Slack, Claude, ChatGPT, ...),
    /// not one pair per service, same shape as `infrastructureUnreachable`/
    /// `infrastructureReachable` covering any number of SNMP devices —
    /// the service's own name and the fetched status description are
    /// carried in `message` instead.
    ///
    /// **Known limitation, accepted for this prototype**: unlike a LAN
    /// check, a vendor's status-page result is a *global* fact, not tied
    /// to whichever network happens to be current — but this is tagged
    /// with `currentNetworkFingerprint` like every other event, since
    /// there's no "genuinely global, never adopt" fingerprint concept
    /// today (a permanently-`nil` tag would collide with
    /// `SnapshotStore.adoptUntaggedRecords`, which already treats `nil`
    /// as "not yet recognized, retag me once you know"). So an outage
    /// event logged at home won't show in the Events tab while at a
    /// coffee shop, even though the outage itself is universal. See
    /// DESIGN-NOTES.md's "Business SaaS monitoring" for the full
    /// reasoning.
    case saasServiceDown
    case saasServiceRecovered
    /// The current network's subnet has more usable host addresses than
    /// `SubnetCalculator.maxSweepHosts` — a full sweep would be too slow
    /// (or, at the extreme end, a /8's 16 million addresses) to run
    /// automatically. SNMP discovery falls back to just the gateway
    /// address instead of silently doing nothing. Informational like
    /// `multipleNATLayersDetected`, not a failure — this is a fact about
    /// how the network is addressed, not something broken. No paired
    /// "recovered" kind: unlike an outage, there's nothing to recover
    /// from, and rejoining a normally-sized network afterward simply
    /// doesn't log this again, the same way `wifiNetworkChanged` doesn't
    /// need a "wifiNetworkChangedBack." Logged once per network
    /// recognition (see `SNMPViewModel.rebuildDeviceList`'s
    /// `lastFingerprintForCaches` guard), not on every scan.
    case subnetTooLargeToScan

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
             .infrastructureReachable, .publicIPReachable, .dhcpAddressRestored, .dhcpRenewalRecovered, .printerAlertCleared,
             .saasServiceRecovered:
            return .positive
        case .interfaceDown, .routerUnreachable, .internetUnreachable, .dnsUnreachable, .httpUnreachable, .peRouterUnreachable,
             .infrastructureUnreachable, .snmpDeviceRestarted, .publicIPUnreachable, .dhcpFellBackToLinkLocal, .dhcpRenewalOverdue,
             .printerAlert, .saasServiceDown:
            return .negative
        case .publicIPChanged, .interfaceChanged, .wifiNetworkChanged, .snmpDeviceSoftwareChanged, .dhcpLeaseChanged,
             .screenshotCaptured, .bugReportCaptured, .multipleNATLayersDetected, .subnetTooLargeToScan:
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
    /// A clickable link for this event, when it has one — currently only
    /// `.saasServiceDown` (see `SaaSMonitoringViewModel.apply`). Plain
    /// optional, same no-migration-risk shape as `SNMPDeviceRecord.webURL`.
    /// Added after direct feedback: the URL used to be baked into
    /// `message` as trailing "(https://...)" text, which `eventRows`
    /// truncates to one line — unreadable, let alone clickable. A real
    /// field lets the UI render it as an actual link instead of asking
    /// someone to select-and-copy truncated text.
    var url: String?

    init(kind: AppEventKind, message: String, occurredAt: Date = Date(), networkFingerprint: String? = nil, url: String? = nil) {
        self.kind = kind.rawValue
        self.message = message
        self.occurredAt = occurredAt
        self.networkFingerprint = networkFingerprint
        self.url = url
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
