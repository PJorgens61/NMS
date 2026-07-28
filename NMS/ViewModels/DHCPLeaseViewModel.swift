import Foundation
import Combine

/// Tracks the current DHCP lease (from `ipconfig getpacket`, a purely
/// local read — see `DHCPLeaseService`) and its history over time, plus two
/// independent failure signals explored in DESIGN-NOTES.md's "DHCP lease
/// tracking" section before this was written: a fallback to a
/// self-assigned (APIPA) address, and a renewal that's run past its
/// expected T2 deadline without the transaction ID changing.
@MainActor
final class DHCPLeaseViewModel: ObservableObject {
    /// Every real lease change, newest first — a genuine `@Model` array
    /// (like `NetworkIdentityViewModel.currentNetwork`) rather than a
    /// value-type projection, since the view just needs to list them.
    /// `history.first` doubles as "the current lease" — there's no
    /// separate "current" property, since the newest history row already
    /// is that.
    @Published private(set) var history: [DHCPLeaseRecord] = [] {
        didSet { UIStateLogger.log("DHCPLeaseViewModel.history", history.map(\.info)) }
    }
    @Published private(set) var isFallenBackToLinkLocal = false

    private let service = DHCPLeaseService()
    private let snapshotStore: SnapshotStore
    private weak var networkMonitor: NetworkMonitorViewModel?
    private var timer: Timer?
    private var isChecking = false

    /// In-memory transition trackers, same shape (and same
    /// relaunch-during-an-ongoing-condition caveat) as
    /// `ConnectivityViewModel.wasUnhealthy` — each logs only on the actual
    /// transition, not every poll while a condition continues.
    private var wasOverdue = false
    private var wasLinkLocal = false

    /// Purely local (no network I/O), so this could poll far more often
    /// than a real network check — 5 minutes is still cheap and frequent
    /// enough that Signal 2 can't lag reality by more than that.
    private static let checkInterval: TimeInterval = 300

    /// Fired when an `AppEventRecord` gets logged, so the event log view
    /// can refresh.
    var onEventLogged: (() -> Void)?

    init(snapshotStore: SnapshotStore, networkMonitor: NetworkMonitorViewModel) {
        self.snapshotStore = snapshotStore
        self.networkMonitor = networkMonitor
        history = snapshotStore.fetchDHCPLeaseHistory()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.check()
            }
        }
        check()
    }

    deinit {
        timer?.invalidate()
    }

    /// `ipconfig` blocks like the `ping`/`snmpget`/`arp` shell-outs
    /// elsewhere in this app, so it runs off the main thread even though
    /// it's local-only and normally fast.
    func check() {
        guard !isChecking else { return }
        guard let interface = networkMonitor?.currentInterface else { return }
        isChecking = true
        let interfaceName = interface.interfaceName
        let ipAddress = interface.ipAddress
        let service = self.service
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lease = service.currentLease(interface: interfaceName)
            Task { @MainActor in
                self?.apply(lease, currentIPAddress: ipAddress)
            }
        }
    }

    private func apply(_ lease: DHCPLeaseInfo?, currentIPAddress: String?) {
        isChecking = false
        checkLinkLocalFallback(currentIPAddress: currentIPAddress)

        // `nil` covers every "not applicable" case (static config, no
        // lease, interface gone) alike — nothing to persist or compare,
        // and the last known lease is left displayed rather than cleared,
        // matching how `PublicIPViewModel` keeps showing the last known
        // address through a transient interface hiccup.
        guard let lease else { return }

        // Captured before the insert below, so it's the lease this poll is
        // being compared *against* — `recordDHCPLeaseIfChanged` would
        // otherwise already have replaced it.
        let previous = snapshotStore.latestDHCPLease()

        let (changed, isFirstEver) = snapshotStore.recordDHCPLeaseIfChanged(lease)
        if changed {
            // Only re-queried on an actual change, not every poll — mirrors
            // `SNMPViewModel.onDeviceListChanged`'s reasoning: refetching
            // unconditionally would just repeat the same query every 5
            // minutes for a list that usually hasn't moved.
            history = snapshotStore.fetchDHCPLeaseHistory()
            // A fresh transaction ID alone isn't newsworthy — routine
            // renewals get a new one every time even when nothing else
            // moved, and logging one of those as "changed" would be exactly
            // the false-alarm-on-a-healthy-renewal problem Signal 2 already
            // takes care to avoid. Only fields that actually differ from
            // the previous lease make it into the message, and if none do,
            // no event fires at all.
            if let previous, !isFirstEver {
                let changes = Self.fieldChanges(from: previous, to: lease)
                if !changes.isEmpty {
                    snapshotStore.logEvent(.dhcpLeaseChanged, message: "DHCP lease changed: \(changes.joined(separator: ", "))")
                    onEventLogged?()
                }
            }
        }
        checkRenewalOverdue()
    }

    /// Every field that differs between the previous lease and this one,
    /// as "`label` old → new" strings — deliberately every parsed field,
    /// not a curated subset, since the point (per the scenario this was
    /// built for: spotting a change someone *else* made to the network,
    /// like an admin editing the DHCP scope) is knowing exactly what
    /// changed, not just that something did. The transaction ID itself is
    /// excluded — it changes on every renewal by protocol definition, so
    /// listing it would never be informative.
    private static func fieldChanges(from previous: DHCPLeaseRecord, to lease: DHCPLeaseInfo) -> [String] {
        var changes: [String] = []
        if previous.serverIdentifier != lease.serverIdentifier {
            changes.append("server \(previous.serverIdentifier) → \(lease.serverIdentifier)")
        }
        if previous.assignedAddress != lease.assignedAddress {
            changes.append("address \(previous.assignedAddress) → \(lease.assignedAddress)")
        }
        if previous.subnetMask != lease.subnetMask {
            changes.append("subnet mask \(previous.subnetMask ?? "—") → \(lease.subnetMask ?? "—")")
        }
        if previous.broadcastAddress != lease.broadcastAddress {
            changes.append("broadcast \(previous.broadcastAddress ?? "—") → \(lease.broadcastAddress ?? "—")")
        }
        if previous.router != lease.router {
            changes.append("gateway \(previous.router ?? "—") → \(lease.router ?? "—")")
        }
        if previous.dnsServers != lease.dnsServers {
            changes.append("DNS \(previous.dnsServers.joined(separator: ",")) → \(lease.dnsServers.joined(separator: ","))")
        }
        if previous.domainName != lease.domainName {
            changes.append("domain \(previous.domainName ?? "—") → \(lease.domainName ?? "—")")
        }
        if previous.leaseSeconds != lease.leaseSeconds {
            changes.append("lease \(DHCPLeaseInfo.durationText(previous.leaseSeconds)) → \(DHCPLeaseInfo.durationText(lease.leaseSeconds))")
        }
        if previous.t1Seconds != lease.t1Seconds {
            changes.append("T1 \(DHCPLeaseInfo.durationText(previous.t1Seconds)) → \(DHCPLeaseInfo.durationText(lease.t1Seconds))")
        }
        if previous.t2Seconds != lease.t2Seconds {
            changes.append("T2 \(DHCPLeaseInfo.durationText(previous.t2Seconds)) → \(DHCPLeaseInfo.durationText(lease.t2Seconds))")
        }
        return changes
    }

    private func checkLinkLocalFallback(currentIPAddress: String?) {
        let isLinkLocal = currentIPAddress.map(IPClassifier.isLinkLocal) ?? false
        isFallenBackToLinkLocal = isLinkLocal
        defer { wasLinkLocal = isLinkLocal }
        guard isLinkLocal != wasLinkLocal else { return }
        if isLinkLocal {
            snapshotStore.logEvent(.dhcpFellBackToLinkLocal, message: "Interface fell back to a self-assigned address")
        } else {
            snapshotStore.logEvent(.dhcpAddressRestored, message: "DHCP address restored")
        }
        onEventLogged?()
    }

    /// The client should have started rebinding by T2 and hasn't. Reads
    /// straight from the persisted record rather than in-memory state, so
    /// a renewal that succeeds on schedule resets this deadline (via a
    /// fresh `firstObservedAt`) before it's ever reached — no false alarms
    /// for healthy renewals.
    private func checkRenewalOverdue() {
        guard let record = snapshotStore.latestDHCPLease() else { return }
        let expectedT2At = record.firstObservedAt.addingTimeInterval(TimeInterval(record.t2Seconds))
        let isOverdue = Date() > expectedT2At
        defer { wasOverdue = isOverdue }
        guard isOverdue != wasOverdue else { return }
        if isOverdue {
            snapshotStore.logEvent(.dhcpRenewalOverdue, message: "DHCP renewal overdue")
        } else {
            snapshotStore.logEvent(.dhcpRenewalRecovered, message: "DHCP lease renewed")
        }
        onEventLogged?()
    }
}
