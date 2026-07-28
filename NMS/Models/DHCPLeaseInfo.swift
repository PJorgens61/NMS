import Foundation

/// A DHCP lease snapshot for one interface, read from the last successful
/// negotiation `configd` already has cached — see `DHCPLeaseService`. Zero
/// network I/O: this reflects the last successful lease, not "is the
/// server alive right now" (a server that died minutes after granting this
/// would still show a healthy-looking record). See DESIGN-NOTES.md's "DHCP
/// lease tracking" for why that tradeoff was accepted.
struct DHCPLeaseInfo: Equatable, Codable {
    let interfaceName: String
    let serverIdentifier: String
    let assignedAddress: String
    let subnetMask: String?
    let broadcastAddress: String?
    let router: String?
    let dnsServers: [String]
    let domainName: String?
    let leaseSeconds: Int
    let t1Seconds: Int
    let t2Seconds: Int
    /// The DHCP transaction ID (`xid`). A genuinely new transaction —
    /// initial grant, renewal, or rebind — always gets a fresh one, which
    /// is what lets the app tell "still the same lease" from "renewed"
    /// without an absolute grant timestamp from the protocol itself.
    let transactionID: String
    let checkedAt: Date

    /// Shared by the popover's DHCP History rows and
    /// `DHCPLeaseViewModel`'s change-event messages, so a duration reads
    /// identically in both places.
    static func durationText(_ seconds: Int) -> String {
        seconds >= 3600 ? "\(seconds / 3600)h" : "\(seconds / 60)m"
    }
}
