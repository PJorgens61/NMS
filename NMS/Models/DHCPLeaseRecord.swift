import Foundation
import SwiftData

/// Persisted history of DHCP lease changes — mirrors `PublicIPRecord`: a
/// new row only when the lease's transaction ID actually changes (see
/// `SnapshotStore.recordDHCPLeaseIfChanged`), so this is a timeline of real
/// renewals, not a per-poll log. `firstObservedAt` is the one field that
/// doesn't mirror that pattern: it's the anchor Signal 2 (renewal-overdue
/// detection) computes an expected T2 deadline from, since `ipconfig
/// getpacket` only reports lease *durations*, never an absolute grant
/// timestamp — see DESIGN-NOTES.md.
@Model
final class DHCPLeaseRecord {
    var interfaceName: String
    var serverIdentifier: String
    var assignedAddress: String
    var subnetMask: String?
    var broadcastAddress: String?
    var router: String?
    var dnsServers: [String]
    var domainName: String?
    var leaseSeconds: Int
    var t1Seconds: Int
    var t2Seconds: Int
    var transactionID: String
    var clientHardwareAddress: String?
    var observedAt: Date
    var firstObservedAt: Date
    /// See `AppEventRecord.networkFingerprint` — same scoping, same `nil`
    /// meaning ("not recognized yet," not "belongs to every network").
    var networkFingerprint: String?

    init(from info: DHCPLeaseInfo, firstObservedAt: Date, networkFingerprint: String? = nil) {
        self.networkFingerprint = networkFingerprint
        interfaceName = info.interfaceName
        serverIdentifier = info.serverIdentifier
        assignedAddress = info.assignedAddress
        subnetMask = info.subnetMask
        broadcastAddress = info.broadcastAddress
        router = info.router
        dnsServers = info.dnsServers
        domainName = info.domainName
        leaseSeconds = info.leaseSeconds
        t1Seconds = info.t1Seconds
        t2Seconds = info.t2Seconds
        transactionID = info.transactionID
        clientHardwareAddress = info.clientHardwareAddress
        observedAt = info.checkedAt
        self.firstObservedAt = firstObservedAt
    }

    /// "server · address[/prefix]" — moved here from `ContentView` so
    /// Network Review can render the same line for a past network's
    /// history without duplicating the subnet-mask-to-prefix logic.
    var primaryDetail: String {
        var address = assignedAddress
        if let subnetMask, let prefix = SubnetCalculator.prefixLength(subnetMask: subnetMask) {
            address += "/\(prefix)"
        }
        return "\(serverIdentifier) · \(address)"
    }

    /// Every other field `DHCPLeaseService` parses, joined into one line —
    /// deliberately not a curated subset, since the point is seeing
    /// everything about a lease, not a guess at what's most interesting.
    /// Moved here alongside `primaryDetail` for the same reason.
    var secondaryDetail: String {
        var parts: [String] = []
        if let broadcastAddress { parts.append("bcast \(broadcastAddress)") }
        if let router { parts.append("gw \(router)") }
        if !dnsServers.isEmpty { parts.append("dns \(dnsServers.joined(separator: ","))") }
        if let domainName, !domainName.isEmpty { parts.append(domainName) }
        parts.append("lease \(DHCPLeaseInfo.durationText(leaseSeconds))")
        parts.append("T1 \(DHCPLeaseInfo.durationText(t1Seconds))")
        parts.append("T2 \(DHCPLeaseInfo.durationText(t2Seconds))")
        // Before transactionID, not after -- transactionHelpText below
        // specifically describes "the trailing hex value" as the
        // transaction ID, so it needs to stay last.
        if let clientHardwareAddress { parts.append(clientHardwareAddress) }
        parts.append(transactionID)
        return parts.joined(separator: " · ")
    }

    /// Written for this app's stated audience — a network engineer, not a
    /// software developer — so it skips what that reader already knows
    /// (broadcast, gateway, DNS, search domain all read themselves) and
    /// covers only what `secondaryDetail` doesn't explain on its own:
    /// which of T1/T2 is which, and what the trailing hex value even is.
    static let transactionHelpText = """
        T1 is the renewal timer (half the lease by default), T2 the \
        rebinding timer (87.5%). The trailing hex value is the DHCP \
        transaction ID — a new one means a genuinely new lease, renewal \
        or rebind, which is what this history keys on.
        """

    var info: DHCPLeaseInfo {
        DHCPLeaseInfo(
            interfaceName: interfaceName,
            serverIdentifier: serverIdentifier,
            assignedAddress: assignedAddress,
            subnetMask: subnetMask,
            broadcastAddress: broadcastAddress,
            router: router,
            dnsServers: dnsServers,
            domainName: domainName,
            leaseSeconds: leaseSeconds,
            t1Seconds: t1Seconds,
            t2Seconds: t2Seconds,
            transactionID: transactionID,
            clientHardwareAddress: clientHardwareAddress,
            checkedAt: observedAt
        )
    }
}
