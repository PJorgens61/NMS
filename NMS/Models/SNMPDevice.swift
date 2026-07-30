import Foundation

/// A device that answered an SNMP GET — by definition a managed device
/// (switch, AP, router, printer, UPS), which is exactly the network
/// infrastructure whose failure explains the outages this app already
/// tracks. Complements ARP discovery (only sees hosts we've exchanged
/// traffic with): a managed switch typically doesn't, but does answer
/// SNMP. See `PrinterDiscoveryService` for a third, printer-specific
/// source that finds a printer regardless of whether it speaks SNMP at
/// all — the user's own configured-printer list (`lpstat -v`), not
/// network-based discovery.
struct SNMPDevice: Equatable, Identifiable {
    var id: String { ipAddress }

    let ipAddress: String
    /// Other addresses that resolved to the *same MAC* as `ipAddress` — one
    /// physical interface answering at several addresses, which is what a
    /// VRRP virtual address looks like when the master answers it from its
    /// own hardware MAC. Populated by `SNMPViewModel`, not by SNMP itself:
    /// the evidence comes from the ARP table. Empty for the normal case.
    ///
    /// Kept rather than discarded so the merge stays honest — the device is
    /// genuinely reachable at all of these, and which one is "the real" one
    /// is not something ARP or SNMP can answer.
    var aliasAddresses: [String] = []
    /// `sysDescr.0` — vendor's own description, which in practice carries
    /// the model *and* the running software version (e.g. "Alta Route10
    /// 1.5b"). A change here means the device's software changed.
    let sysDescr: String
    /// `sysName.0` — the configured hostname, often more recognizable than
    /// the IP. `nil` if the device doesn't report one.
    let sysName: String?
    /// `sysUpTime.0` in hundredths of a second, as a raw counter (via
    /// `snmpget -Ot`) rather than the human-readable rendering, so it can
    /// be compared numerically across polls to detect restarts.
    let uptimeTicks: Int
    /// Which configured community string this device actually answered on.
    /// Remembered so routine re-polls query it directly instead of
    /// retrying strings it's already known to reject — wrong-community
    /// attempts typically show up as `authenticationFailure` entries in a
    /// managed device's own logs, so repeating them every 60s would be
    /// both wasteful and noisy on someone else's console.
    let community: String
    let polledAt: Date

    /// The name worth showing: hostname when the device reports one,
    /// otherwise the address.
    var displayName: String {
        guard let sysName, !sysName.isEmpty else { return ipAddress }
        return sysName
    }

    /// Every address this device answers at, primary first. One entry in the
    /// normal case; more when `aliasAddresses` caught a second address on
    /// the same MAC (a VRRP virtual address, typically).
    var allAddresses: [String] { [ipAddress] + aliasAddresses }

    /// Shown under the name so a merged device still reveals both addresses
    /// rather than silently presenting one — which address is the "real" one
    /// isn't knowable from ARP or SNMP, so the honest answer is to show all
    /// of them.
    var addressDescription: String { allAddresses.joined(separator: ", ") }

    var uptimeInterval: TimeInterval {
        TimeInterval(uptimeTicks) / 100
    }

    /// Coarse on purpose — "up 33d" is the useful signal in a menu bar
    /// popover; the exact seconds are not.
    var uptimeDescription: String {
        let totalSeconds = Int(uptimeInterval)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        if days > 0 { return "up \(days)d \(hours)h" }
        if hours > 0 { return "up \(hours)h \(minutes)m" }
        return "up \(minutes)m"
    }
}
