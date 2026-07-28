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
    var observedAt: Date
    var firstObservedAt: Date

    init(from info: DHCPLeaseInfo, firstObservedAt: Date) {
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
        observedAt = info.checkedAt
        self.firstObservedAt = firstObservedAt
    }

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
            checkedAt: observedAt
        )
    }
}
