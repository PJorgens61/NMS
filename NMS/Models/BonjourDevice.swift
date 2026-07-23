import Foundation

/// A device discovered via Bonjour (mDNS/DNS-SD) — complements
/// `LANDiscoveryService`'s ARP-based discovery, which only sees hosts the
/// Mac has already exchanged traffic with. Bonjour surfaces devices that
/// actively advertise a service even if nothing has talked to them yet,
/// and tells you *what kind* of device it is (a printer, an AirPlay
/// receiver, etc.) — something ARP can never provide.
struct BonjourDevice: Equatable, Codable, Identifiable {
    var id: String { "\(name)|\(serviceType)" }

    /// The service instance name, e.g. "Office Printer" or "rock".
    let name: String
    /// Raw Bonjour service type, e.g. "_ipp._tcp".
    let serviceType: String
    /// Human-friendly label for `serviceType`, e.g. "Printer".
    let serviceLabel: String
    /// `nil` if resolution didn't complete in time — the service was still
    /// genuinely discovered, just without a confirmed reachable address.
    let ipAddress: String?
    let discoveredAt: Date
}
