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

        // The write path that causes ~90% of this store's growth also
        // drives its own cleanup — see `pruneIfNeeded`.
        pruneIfNeeded()

        return enriched
    }

    /// How long raw, per-check telemetry is kept. Everything pruned by
    /// `pruneIfNeeded` is high-volume machine output whose value decays
    /// almost immediately; nothing that represents a *change* is touched.
    ///
    /// Seven days is deliberately generous relative to the only planned
    /// consumer — the latency sparklines sketched in DESIGN-NOTES.md want
    /// roughly 20–30 points, about 10–15 minutes at the normal cadence,
    /// so this keeps ~700x what that feature would read. It's sized for
    /// human forensics ("what was happening overnight?") rather than for
    /// any code that exists today, and steady state lands around 160k
    /// rows / ~24 MB, which is bounded and small enough not to matter.
    private static let telemetryRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Minimum gap between prune passes. The trigger is a write on a hot
    /// path (a check round every 5–30s), so the throttle is what keeps
    /// this from issuing deletes continuously; the actual work happens at
    /// most hourly.
    private static let pruneInterval: TimeInterval = 60 * 60

    /// `nil` initially, so the first check round after launch prunes
    /// immediately rather than waiting out the interval — a Mac that was
    /// asleep for a week should clean up promptly, not an hour in.
    private var lastPrunedAt: Date?

    /// Deletes telemetry older than `telemetryRetention`, at most once
    /// per `pruneInterval`.
    ///
    /// **Only three tables are pruned, and the asymmetry is the whole
    /// design.** `ConnectivityCheckRecord` alone is ~90% of all rows
    /// (measured: 4280 of 4736 after 4.5 hours, growing ~953 rows/hour,
    /// ~3.5 MB/day) because it's the one table driven by a timer rather
    /// than by events — one row per target per round, forever.
    /// `DiscoveredDeviceRecord` and `BonjourDeviceRecord` grow the same
    /// way per LAN/Bonjour scan. All three are raw observations.
    ///
    /// Everything else is deliberately left alone: `AppEventRecord`,
    /// `PublicIPRecord`, `DHCPLeaseRecord` and `NetworkSnapshot` are
    /// change-logs whose entire value *is* their age (a DHCP server
    /// change six months ago is exactly what someone would go looking
    /// for), `NetworkQualityRecord` rows are each a deliberate user
    /// action, and `SNMPDeviceRecord`/`KnownNetwork` are upserts bounded
    /// by how much hardware exists. Between them they were 456 rows to
    /// the telemetry tables' 4280 — pruning telemetry alone removes
    /// essentially all the growth while touching nothing anyone would
    /// miss.
    ///
    /// Worth stating plainly: **nothing in this app currently reads any
    /// of the three pruned tables.** They're written and never fetched
    /// (verified across the whole source), so this bounds data that is,
    /// as of today, pure write amplification — retained only because the
    /// planned sparklines feature would read the first of them.
    ///
    /// Pruning on write rather than from a timer or at launch is a
    /// deliberate choice for a menu bar app: launch-only never runs on an
    /// instance that stays up for weeks (this app is designed to), and a
    /// dedicated timer would be a second scheduling mechanism to own.
    /// Tying cleanup to the write that causes the growth makes it
    /// self-limiting — an app doing nothing writes nothing and needs no
    /// cleanup.
    func pruneIfNeeded(now: Date = Date()) {
        if let lastPrunedAt, now.timeIntervalSince(lastPrunedAt) < Self.pruneInterval {
            return
        }
        lastPrunedAt = now

        let cutoff = now.addingTimeInterval(-Self.telemetryRetention)

        // Batch delete for the one table with no relationships. This is
        // the table that actually gets large (~160k rows at steady
        // state), so it's worth the efficient path — nothing is loaded
        // into memory.
        do {
            try context.delete(model: ConnectivityCheckRecord.self, where: #Predicate { $0.checkedAt < cutoff })
        } catch {
            UIStateLogger.log("SnapshotStore.prune", "ConnectivityCheckRecord batch delete failed: \(error)")
        }

        // Fetch-then-delete for the two that hold a `snapshot`
        // relationship. `delete(model:where:)` was confirmed to silently
        // do nothing for these — a real test with a 2-hour window pruned
        // 3544 connectivity checks correctly while leaving all 325
        // eligible `DiscoveredDeviceRecord` rows untouched, oldest still
        // five hours old. Deleting fetched objects individually respects
        // the relationship graph and actually works. Affordable because
        // these tables are small (hundreds of rows, written per scan
        // rather than per check round); the same approach on
        // `ConnectivityCheckRecord` would mean loading six figures of
        // rows into memory.
        deleteFetched(FetchDescriptor<DiscoveredDeviceRecord>(predicate: #Predicate { $0.discoveredAt < cutoff }))
        deleteFetched(FetchDescriptor<BonjourDeviceRecord>(predicate: #Predicate { $0.discoveredAt < cutoff }))

        try? context.save()
    }

    /// Deletes every object matching `descriptor`, one at a time.
    ///
    /// Errors are logged rather than swallowed: the original version of
    /// `pruneIfNeeded` used `try?` throughout, which is exactly why the
    /// batch-delete failure above went unnoticed until the counts were
    /// checked by hand. A prune that silently does nothing looks
    /// identical to a prune that had nothing to do.
    private func deleteFetched<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) {
        do {
            for object in try context.fetch(descriptor) {
                context.delete(object)
            }
        } catch {
            UIStateLogger.log("SnapshotStore.prune", "\(T.self) fetch-then-delete failed: \(error)")
        }
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

    /// Debug-only plain-text dump of every table — see `StoreInspector`.
    /// Lives here rather than taking a `ModelContext` at the call site so
    /// `context` can stay private; this type is the only thing that owns
    /// it.
    func dumpState() -> String? {
        StoreInspector.dump(context: context)
    }

    @discardableResult
    func logEvent(_ kind: AppEventKind, message: String, at date: Date = Date()) -> AppEventRecord {
        let event = AppEventRecord(kind: kind, message: message, occurredAt: date)
        context.insert(event)
        try? context.save()
        return event
    }

    /// 200, not the original 50 — an outage is bursty (a single
    /// interface failover here produced 19 events in two seconds, and a
    /// down/up cycle across router + 5 infrastructure devices + 5 network
    /// layers reliably produces 30+), so 50 covers barely more than one
    /// incident. The popover only ever shows ~8 rows at a time regardless;
    /// this is scrollback depth, and a `fetchLimit`-bounded query stays
    /// cheap no matter how large the table itself gets.
    ///
    /// Note this is a *fetch* bound, not retention: nothing in this type
    /// ever deletes an `AppEventRecord`, so the table grows without limit
    /// on disk. That's a real, known gap (see DESIGN-NOTES.md — it
    /// applies to every table here, not just this one), deliberately not
    /// solved by this constant.
    func fetchRecentEvents(limit: Int = 200) -> [AppEventRecord] {
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
