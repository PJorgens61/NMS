import Foundation
import SwiftData

/// Thin wrapper around a `ModelContext` for writing and reading
/// `NetworkSnapshot` history.
@MainActor
final class SnapshotStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    func save(_ info: NetworkInterfaceInfo) -> NetworkSnapshot {
        let snapshot = NetworkSnapshot(from: info)
        context.insert(snapshot)
        try? context.save()
        return snapshot
    }

    func fetchHistory(limit: Int = 100) -> [NetworkSnapshot] {
        var descriptor = FetchDescriptor<NetworkSnapshot>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func latestSnapshot() -> NetworkSnapshot? {
        var descriptor = FetchDescriptor<NetworkSnapshot>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func saveDiscoveredDevices(_ devices: [DiscoveredDevice], for snapshot: NetworkSnapshot?) {
        for device in devices {
            context.insert(DiscoveredDeviceRecord(from: device, snapshot: snapshot))
        }
        try? context.save()
    }

    func saveBonjourDevices(_ devices: [BonjourDevice], for snapshot: NetworkSnapshot?) {
        for device in devices {
            context.insert(BonjourDeviceRecord(from: device, snapshot: snapshot))
        }
        try? context.save()
    }

    /// Persists `checks`, first stamping each failure with whether it landed
    /// near a topology change (see `CorrelationService`), and returns the
    /// enriched values so callers can reflect the flag in the UI too.
    @discardableResult
    func saveConnectivityChecks(_ checks: [ConnectivityCheck]) -> [ConnectivityCheck] {
        let recentSnapshots = fetchHistory(limit: 50)
        let correlation = CorrelationService()

        let enriched = checks.map { check -> ConnectivityCheck in
            var check = check
            if !check.success {
                check.correlatedWithChange = correlation.isCorrelated(checkedAt: check.checkedAt, nearAny: recentSnapshots)
            }
            return check
        }

        for check in enriched {
            context.insert(ConnectivityCheckRecord(from: check))
        }
        try? context.save()

        return enriched
    }

    /// Looks up the `KnownNetwork` for `fingerprint`, bumping its last-seen
    /// timestamp and visit count, or creates it if this is the first time
    /// it's been seen.
    @discardableResult
    func recordNetworkSeen(fingerprint: String, at date: Date = Date()) -> (network: KnownNetwork, isNew: Bool) {
        var descriptor = FetchDescriptor<KnownNetwork>(
            predicate: #Predicate { $0.fingerprint == fingerprint }
        )
        descriptor.fetchLimit = 1

        if let existing = (try? context.fetch(descriptor))?.first {
            existing.lastSeenAt = date
            existing.timesSeen += 1
            try? context.save()
            return (existing, false)
        }

        let network = KnownNetwork(fingerprint: fingerprint, firstSeenAt: date)
        context.insert(network)
        try? context.save()
        return (network, true)
    }

    func setLabel(_ label: String, for network: KnownNetwork) {
        network.label = label.isEmpty ? nil : label
        try? context.save()
    }

    func fetchKnownNetworks(limit: Int = 100) -> [KnownNetwork] {
        var descriptor = FetchDescriptor<KnownNetwork>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func latestPublicIP() -> PublicIPRecord? {
        var descriptor = FetchDescriptor<PublicIPRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func fetchPublicIPHistory(limit: Int = 100) -> [PublicIPRecord] {
        var descriptor = FetchDescriptor<PublicIPRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Persists a new row only if the IP actually changed from the last
    /// recorded value — mirrors `save(_:)` for `NetworkSnapshot`: a timeline
    /// of real changes, not a per-check log. Returns whether it changed.
    @discardableResult
    func recordPublicIPIfChanged(_ info: PublicIPInfo) -> Bool {
        guard latestPublicIP()?.ipAddress != info.ipAddress else { return false }
        context.insert(PublicIPRecord(from: info))
        try? context.save()
        return true
    }

    func latestDHCPLease() -> DHCPLeaseRecord? {
        var descriptor = FetchDescriptor<DHCPLeaseRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The full history of DHCP lease changes — every real renewal/rebind,
    /// not a per-poll log — so a stalled or flapping DHCP server is visible
    /// as a pattern over time, not just today's current lease.
    func fetchDHCPLeaseHistory(limit: Int = 100) -> [DHCPLeaseRecord] {
        var descriptor = FetchDescriptor<DHCPLeaseRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Persists a new row only if the transaction ID actually changed —
    /// same transaction always means the same lease content by protocol
    /// definition, so this alone is a sufficient (and cheaper) change
    /// check than comparing every field. `firstObservedAt` is stamped only
    /// on a genuinely new row, which is what lets a poll that finds the
    /// same lease unchanged (the overwhelmingly common case) leave the
    /// renewal-overdue anchor untouched. Returns whether a new row was
    /// inserted, and whether this is the very first lease ever observed
    /// (so callers can skip logging a "changed" event when there's nothing
    /// to compare against yet).
    @discardableResult
    func recordDHCPLeaseIfChanged(_ info: DHCPLeaseInfo) -> (changed: Bool, isFirstEver: Bool) {
        let previous = latestDHCPLease()
        guard previous?.transactionID != info.transactionID else { return (false, false) }
        context.insert(DHCPLeaseRecord(from: info, firstObservedAt: info.checkedAt))
        try? context.save()
        return (true, previous == nil)
    }

    /// Unconditional insert, unlike every other "record" method here —
    /// every speed-test run is an intentional, standalone data point the
    /// user wants to compare against past ones, not a change to dedupe
    /// against. See `NetworkQualityResult`.
    func recordNetworkQualityResult(_ result: NetworkQualityResult) {
        context.insert(NetworkQualityRecord(from: result))
        try? context.save()
    }

    func fetchNetworkQualityHistory(limit: Int = 10) -> [NetworkQualityRecord] {
        var descriptor = FetchDescriptor<NetworkQualityRecord>(
            sortBy: [SortDescriptor(\.testedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// What changed about an SNMP device since the last time it was polled.
    /// `uptimeTicks` is a 32-bit hundredths-of-a-second counter, so it wraps
    /// roughly every 497 days — a wrap looks exactly like a restart here and
    /// will be reported as one. Rare enough (and a 497-day-uptime device
    /// wrapping is arguably worth surfacing anyway) that it isn't worth
    /// special-casing.
    enum SNMPDeviceChange {
        case firstSeen
        case unchanged
        case restarted
        /// Carries the previous descriptor so the event message can show
        /// what it changed *from*. `restarted` is whether the uptime also
        /// reset — a reboot accompanying an upgrade, rather than a
        /// software change with no restart.
        case softwareChanged(previousDescr: String, restarted: Bool)
    }

    /// Upserts the device's current state (one row per device, keyed by IP —
    /// mirrors `recordNetworkSeen`, not an observation log) and reports what
    /// changed relative to the previously stored state.
    @discardableResult
    func recordSNMPDevice(_ device: SNMPDevice) -> SNMPDeviceChange {
        let ipAddress = device.ipAddress
        var descriptor = FetchDescriptor<SNMPDeviceRecord>(
            predicate: #Predicate { $0.ipAddress == ipAddress }
        )
        descriptor.fetchLimit = 1

        guard let existing = (try? context.fetch(descriptor))?.first else {
            context.insert(SNMPDeviceRecord(from: device))
            try? context.save()
            return .firstSeen
        }

        let previousDescr = existing.sysDescr
        let previousTicks = existing.uptimeTicks
        let restarted = device.uptimeTicks < previousTicks
        let softwareChanged = device.sysDescr != previousDescr

        existing.sysDescr = device.sysDescr
        existing.sysName = device.sysName
        existing.uptimeTicks = device.uptimeTicks
        // Kept in sync too — a device re-polled under a different
        // community string (see `SNMPViewModel.setCommunities`) previously
        // wouldn't update this field on an existing record.
        existing.community = device.community
        existing.lastSeenAt = device.polledAt
        try? context.save()

        if softwareChanged {
            return .softwareChanged(previousDescr: previousDescr, restarted: restarted)
        }
        return restarted ? .restarted : .unchanged
    }

    func fetchSNMPDevices(limit: Int = 100) -> [SNMPDeviceRecord] {
        var descriptor = FetchDescriptor<SNMPDeviceRecord>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Wipes all persisted SNMP device state. Used by `SNMPViewModel.scan()`
    /// so a manual sweep is a genuine clear-and-rediscover, not just a
    /// fresh in-memory list layered on top of old rows — without this, a
    /// device no longer present (e.g. a topology change, like switching
    /// which address represents a VRRP pair) would still reappear on next
    /// launch, since `SNMPViewModel` rehydrates from everything ever
    /// persisted here. Real cost: any device that *is* still around gets a
    /// fresh `firstSeenAt` on rediscovery instead of keeping its real
    /// history — acceptable since this only runs on an explicit, manual
    /// "Scan" click, not automatically.
    func deleteAllSNMPDevices() {
        guard let all = try? context.fetch(FetchDescriptor<SNMPDeviceRecord>()) else { return }
        for record in all {
            context.delete(record)
        }
        try? context.save()
    }

    @discardableResult
    func logEvent(_ kind: AppEventKind, message: String, at date: Date = Date()) -> AppEventRecord {
        let event = AppEventRecord(kind: kind, message: message, occurredAt: date)
        context.insert(event)
        try? context.save()
        return event
    }

    func fetchRecentEvents(limit: Int = 50) -> [AppEventRecord] {
        var descriptor = FetchDescriptor<AppEventRecord>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func latestProviderEdge() -> ProviderEdgeRecord? {
        var descriptor = FetchDescriptor<ProviderEdgeRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func fetchProviderEdgeHistory(limit: Int = 100) -> [ProviderEdgeRecord] {
        var descriptor = FetchDescriptor<ProviderEdgeRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Persists a new row only if the ISP edge router's address actually
    /// changed since the last recorded value — mirrors
    /// `recordPublicIPIfChanged`: a timeline of real changes, not a
    /// per-traceroute-run log. Returns whether it changed.
    @discardableResult
    func recordProviderEdgeIfChanged(address: String, hostname: String?, at date: Date = Date()) -> Bool {
        guard latestProviderEdge()?.address != address else { return false }
        context.insert(ProviderEdgeRecord(address: address, hostname: hostname, observedAt: date))
        try? context.save()
        return true
    }

    /// Patches the hostname onto the most recent `ProviderEdgeRecord` row,
    /// if its address still matches. Needed because `TracerouteService`
    /// now always runs with `-n`, so `recordProviderEdgeIfChanged` gets
    /// called with `hostname: nil` at the moment a row is written — this
    /// fills it in afterward once `TracerouteViewModel`'s reverse-DNS
    /// enrichment (see `ReverseDNSService`) actually resolves one. A no-op
    /// if the address has since moved on (the row this would apply to no
    /// longer exists) or already has a hostname.
    func updateLatestProviderEdgeHostname(_ hostname: String, forAddress address: String) {
        guard let latest = latestProviderEdge(), latest.address == address, latest.hostname == nil else { return }
        latest.hostname = hostname
        try? context.save()
    }
}
