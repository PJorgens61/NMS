import Foundation
import SwiftData

/// Thin wrapper around a `ModelContext` for writing and reading
/// `NetworkSnapshot` history.
@MainActor
final class SnapshotStore {
    private let context: ModelContext

    /// The current network's identity, per `KnownNetwork.fingerprint` —
    /// set by `NetworkIdentityViewModel` once it's resolved (or cleared to
    /// `nil` on a topology change, until the new network is recognized).
    /// Every per-network write (`logEvent`, `recordDHCPLeaseIfChanged`,
    /// `recordSNMPDevice`) stamps new rows with this, and every per-network
    /// read filters by it, so data recorded on one network never shows
    /// while on another. See DESIGN-NOTES.md's "Per-network device
    /// scoping."
    private(set) var currentNetworkFingerprint: String?

    init(context: ModelContext) {
        self.context = context
    }

    func setCurrentNetworkFingerprint(_ fingerprint: String?) {
        currentNetworkFingerprint = fingerprint
    }

    /// Retroactively tags every currently-`nil`-fingerprinted
    /// `AppEventRecord`/`DHCPLeaseRecord`/`SNMPDeviceRecord` row with
    /// `fingerprint`. Called from `NetworkIdentityViewModel.recognize`
    /// right as a network is identified.
    ///
    /// Needed because of a real, confirmed launch-time race: SNMP
    /// discovery and DHCP checks both run before the first LAN scan can
    /// resolve which network this is, so their writes land with `nil`
    /// while recognition is still pending. Without this, the *next*
    /// rebuild reads those rows back scoped to the now-known fingerprint,
    /// finds nothing (the persisted rows are still `nil`), and the
    /// in-memory list silently goes empty — observed directly:
    /// `SNMPViewModel.devices` dropped from 5 entries to `[]` within
    /// 300ms of the first real recognition on a fresh store, and stayed
    /// empty (`poll()` refuses to run once `devices.isEmpty`), a full
    /// outage for the rest of the session. This is not the "legacy data"
    /// the discard-on-conversion decision was about — it's data genuinely
    /// learned on *this* network moments before its name was known, so
    /// adopting it here isn't cross-network leakage, it's finishing an
    /// attribution that was only ever delayed, not wrong.
    func adoptUntaggedRecords(into fingerprint: String) {
        if let events = try? context.fetch(FetchDescriptor<AppEventRecord>(
            predicate: #Predicate { $0.networkFingerprint == nil }
        )) {
            for event in events { event.networkFingerprint = fingerprint }
        }
        if let leases = try? context.fetch(FetchDescriptor<DHCPLeaseRecord>(
            predicate: #Predicate { $0.networkFingerprint == nil }
        )) {
            for lease in leases { lease.networkFingerprint = fingerprint }
        }
        // Unlike events and leases above — append-only logs where a
        // retagged row is just another entry — `SNMPDeviceRecord` holds
        // **one row per (ipAddress, network)**, an invariant enforced only
        // in code (see `recordSNMPDevice`; it can't be a SwiftData
        // constraint, which has no composite form). Blindly retagging here
        // broke it: an SNMP poll that lands before the LAN scan resolves
        // the router MAC writes a `nil`-tagged row for a device that
        // already has a tagged one, and adopting it produced a duplicate
        // pair.
        //
        // That was a real crash, not a theoretical one. `recordSNMPDevice`
        // fetches with `fetchLimit = 1`, so it updates one twin and leaves
        // the other frozen; `mergingSharedMACs` then puts both copies in
        // its `unknownMAC` bucket whenever ARP hasn't resolved that address
        // yet, and the duplicate reaches `SNMPViewModel.apply`'s
        // `Dictionary(uniqueKeysWithValues:)`, which traps on duplicate
        // keys. Confirmed in the store: every device had exactly two rows.
        if let devices = try? context.fetch(FetchDescriptor<SNMPDeviceRecord>(
            predicate: #Predicate { $0.networkFingerprint == nil }
        )) {
            for device in devices {
                let ipAddress = device.ipAddress
                var descriptor = FetchDescriptor<SNMPDeviceRecord>(
                    predicate: #Predicate { $0.ipAddress == ipAddress && $0.networkFingerprint == fingerprint }
                )
                descriptor.fetchLimit = 1
                guard let existing = (try? context.fetch(descriptor))?.first else {
                    device.networkFingerprint = fingerprint
                    continue
                }
                // A tagged row already owns this address. The untagged row
                // carries the *newer* poll (it was just written), so its
                // state is folded into the survivor rather than dropped —
                // then the duplicate goes, keeping the invariant intact.
                if device.lastSeenAt > existing.lastSeenAt {
                    existing.sysDescr = device.sysDescr
                    existing.sysName = device.sysName
                    existing.uptimeTicks = device.uptimeTicks
                    existing.community = device.community
                    existing.lastSeenAt = device.lastSeenAt
                }
                existing.firstSeenAt = min(existing.firstSeenAt, device.firstSeenAt)
                context.delete(device)
            }
        }
        try? context.save()
    }

    /// Deletes duplicate `SNMPDeviceRecord` rows — more than one for the
    /// same (`ipAddress`, `networkFingerprint`) — keeping whichever was
    /// polled most recently and preserving the earliest `firstSeenAt`
    /// across the set.
    ///
    /// Self-healing rather than a one-shot migration, because stores that
    /// already contain the duplicates exist in the wild: this bug shipped,
    /// and other people are running the app (see the feature-flag notes).
    /// Cheap enough to run at every launch — it's one fetch over a table
    /// holding a handful of rows per network, and it no-ops entirely once
    /// the store is clean.
    ///
    /// Kept separate from `adoptUntaggedRecords`' own guard above: that
    /// stops *new* duplicates being created, this clears ones already on
    /// disk. Both are needed; neither subsumes the other.
    func dedupeSNMPDevices() {
        guard let all = try? context.fetch(FetchDescriptor<SNMPDeviceRecord>()) else { return }
        var survivorByKey: [String: SNMPDeviceRecord] = [:]
        var doomed: [SNMPDeviceRecord] = []

        for record in all {
            let key = "\(record.ipAddress)|\(record.networkFingerprint ?? "")"
            guard let survivor = survivorByKey[key] else {
                survivorByKey[key] = record
                continue
            }
            let (keep, drop) = record.lastSeenAt > survivor.lastSeenAt
                ? (record, survivor)
                : (survivor, record)
            keep.firstSeenAt = min(keep.firstSeenAt, drop.firstSeenAt)
            survivorByKey[key] = keep
            doomed.append(drop)
        }

        guard !doomed.isEmpty else { return }
        for record in doomed { context.delete(record) }
        try? context.save()
        UIStateLogger.log("SnapshotStore.dedupeSNMPDevices", "removed \(doomed.count) duplicate row(s)")
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

    /// Persists `checks`, first stamping each failure with whether it landed
    /// near a topology change (see `CorrelationService`), and returns the
    /// enriched values so callers can reflect the flag in the UI too.
    @discardableResult
    func saveConnectivityChecks(_ checks: [ConnectivityCheck]) -> [ConnectivityCheck] {
        let recentSnapshots = fetchHistory(limit: 50)
        let correlation = CorrelationService()

        // Sampled once for the whole round, not per check: every result
        // here came from the same moment, so per-check sampling would
        // record noise as if it were per-target signal.
        let systemLoad = SystemLoadService.normalizedLoad()

        let enriched = checks.map { check -> ConnectivityCheck in
            var check = check
            check.systemLoad = systemLoad
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
    /// `DiscoveredDeviceRecord` grows the same way per LAN scan, and
    /// `WiFiSampleRecord` per periodic Wi-Fi sample. All three are raw
    /// observations. (`BonjourDeviceRecord` used to be a fourth — removed
    /// along with Bonjour discovery entirely, see DESIGN-NOTES.md's
    /// "mDNS/Bonjour" section.)
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

        // Batch delete for the tables with no relationships. `ConnectivityCheckRecord`
        // is the one that actually gets large (~160k rows at steady state),
        // so it's worth the efficient path — nothing is loaded into memory.
        // `WiFiSampleRecord` joined this group from the day it shipped,
        // rather than as a fast-follow once it grew large enough to
        // notice — same timer-driven, no-relationship shape.
        do {
            try context.delete(model: ConnectivityCheckRecord.self, where: #Predicate { $0.checkedAt < cutoff })
        } catch {
            UIStateLogger.log("SnapshotStore.prune", "ConnectivityCheckRecord batch delete failed: \(error)")
        }
        do {
            try context.delete(model: WiFiSampleRecord.self, where: #Predicate { $0.sampledAt < cutoff })
        } catch {
            UIStateLogger.log("SnapshotStore.prune", "WiFiSampleRecord batch delete failed: \(error)")
        }

        // Fetch-then-delete for the one that holds a `snapshot`
        // relationship. `delete(model:where:)` was confirmed to silently
        // do nothing for these — a real test with a 2-hour window pruned
        // 3544 connectivity checks correctly while leaving all 325
        // eligible `DiscoveredDeviceRecord` rows untouched, oldest still
        // five hours old. Deleting fetched objects individually respects
        // the relationship graph and actually works. Affordable because
        // this table is small (hundreds of rows, written per scan rather
        // than per check round); the same approach on
        // `ConnectivityCheckRecord` would mean loading six figures of
        // rows into memory.
        deleteFetched(FetchDescriptor<DiscoveredDeviceRecord>(predicate: #Predicate { $0.discoveredAt < cutoff }))

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

    /// Looks up the `KnownNetwork` for the router MAC + subnet pair,
    /// bumping its last-seen timestamp and visit count, or creates it if
    /// this is the first time it's been seen. See `KnownNetwork` for why
    /// both are needed, not just the router MAC.
    @discardableResult
    func recordNetworkSeen(routerMAC: String, subnet: String, at date: Date = Date()) -> (network: KnownNetwork, isNew: Bool) {
        let fingerprint = KnownNetwork.makeFingerprint(routerMAC: routerMAC, subnet: subnet)
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

        let network = KnownNetwork(routerMAC: routerMAC, subnet: subnet, firstSeenAt: date)
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

    /// Forgets a network entirely: every `AppEventRecord`, `DHCPLeaseRecord`
    /// and `SNMPDeviceRecord` tagged with its fingerprint, plus the
    /// `KnownNetwork` row itself. A deliberate, real cleanup — not just
    /// removing it from the list while its data lingers behind orphaned to
    /// a fingerprint nothing references anymore.
    func deleteNetwork(_ network: KnownNetwork) {
        let fingerprint = network.fingerprint

        if let events = try? context.fetch(FetchDescriptor<AppEventRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint }
        )) {
            for event in events { context.delete(event) }
        }
        if let leases = try? context.fetch(FetchDescriptor<DHCPLeaseRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint }
        )) {
            for lease in leases { context.delete(lease) }
        }
        if let devices = try? context.fetch(FetchDescriptor<SNMPDeviceRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint }
        )) {
            for device in devices { context.delete(device) }
        }
        context.delete(network)
        try? context.save()

        if currentNetworkFingerprint == fingerprint {
            currentNetworkFingerprint = nil
        }
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

    /// Scoped to `currentNetworkFingerprint` — a lease seen on a different
    /// network shouldn't count as "the previous lease" for change
    /// detection here, any more than it should show in the history list.
    func latestDHCPLease() -> DHCPLeaseRecord? {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<DHCPLeaseRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The full history of DHCP lease changes on the current network —
    /// every real renewal/rebind, not a per-poll log — so a stalled or
    /// flapping DHCP server is visible as a pattern over time, not just
    /// today's current lease. Scoped by `currentNetworkFingerprint`: a
    /// different network's lease history never shows here.
    func fetchDHCPLeaseHistory(limit: Int = 100) -> [DHCPLeaseRecord] {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<DHCPLeaseRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Same as `fetchDHCPLeaseHistory`, but for an explicitly named
    /// network rather than whichever one is current — used by Network
    /// Review to read a *past* network's history. Deliberately does not
    /// read or touch `currentNetworkFingerprint`: reassigning that global
    /// to browse another network would mistag whatever background writes
    /// (SNMP poll, DHCP check, Wi-Fi sample) land while the review window
    /// is open. See DESIGN-NOTES.md's "Network Review" section.
    func fetchDHCPLeaseHistory(for fingerprint: String, limit: Int = 100) -> [DHCPLeaseRecord] {
        var descriptor = FetchDescriptor<DHCPLeaseRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
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
    /// *on this network* (so callers can skip logging a "changed" event
    /// when there's nothing on this network to compare against yet).
    @discardableResult
    func recordDHCPLeaseIfChanged(_ info: DHCPLeaseInfo) -> (changed: Bool, isFirstEver: Bool) {
        let previous = latestDHCPLease()
        guard previous?.transactionID != info.transactionID else { return (false, false) }
        context.insert(DHCPLeaseRecord(from: info, firstObservedAt: info.checkedAt, networkFingerprint: currentNetworkFingerprint))
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

    /// Unconditional insert, same reasoning as `recordNetworkQualityResult`
    /// — a genuine time series, not a change to dedupe against. Unlike that
    /// one, this runs on a timer (`WiFiSSIDViewModel`'s periodic sampling)
    /// rather than a user action, so it's grown into `pruneIfNeeded`'s
    /// retention group from the start rather than as a fast-follow — see
    /// that method.
    func recordWiFiSample(
        ssid: String?,
        bssid: String?,
        rssi: Int?,
        noise: Int?,
        channelNumber: Int?,
        channelBand: String?,
        phyRateMbps: Double?,
        security: String?
    ) {
        context.insert(WiFiSampleRecord(
            ssid: ssid,
            bssid: bssid,
            rssi: rssi,
            noise: noise,
            channelNumber: channelNumber,
            channelBand: channelBand,
            phyRateMbps: phyRateMbps,
            security: security,
            networkFingerprint: currentNetworkFingerprint
        ))
        try? context.save()
    }

    /// Scoped by `currentNetworkFingerprint`: a different network's Wi-Fi
    /// history never shows here.
    func fetchWiFiSampleHistory(limit: Int = 30) -> [WiFiSampleRecord] {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<WiFiSampleRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Explicit-fingerprint sibling of `fetchWiFiSampleHistory`, for
    /// Network Review — see `fetchDHCPLeaseHistory(for:limit:)`'s doc
    /// comment for why this never touches `currentNetworkFingerprint`.
    func fetchWiFiSampleHistory(for fingerprint: String, limit: Int = 30) -> [WiFiSampleRecord] {
        var descriptor = FetchDescriptor<WiFiSampleRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
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

    /// Upserts the device's current state (one row per device, keyed by IP
    /// *within the current network* — mirrors `recordNetworkSeen`, not an
    /// observation log) and reports what changed relative to the
    /// previously stored state. Scoped by `currentNetworkFingerprint`: two
    /// different networks can legitimately each have a device at the same
    /// IP address, and this must not confuse them for one another.
    @discardableResult
    func recordSNMPDevice(_ device: SNMPDevice) -> SNMPDeviceChange {
        let ipAddress = device.ipAddress
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<SNMPDeviceRecord>(
            predicate: #Predicate { $0.ipAddress == ipAddress && $0.networkFingerprint == fingerprint }
        )
        descriptor.fetchLimit = 1

        guard let existing = (try? context.fetch(descriptor))?.first else {
            context.insert(SNMPDeviceRecord(from: device, networkFingerprint: fingerprint))
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

    /// Keeps an alias address's row from looking permanently dead once its
    /// physical device gets folded into a primary elsewhere by
    /// `SNMPViewModel.mergingSharedMACs` — the primary is the only address
    /// actually polled from then on (see `SNMPViewModel.poll`), so without
    /// this the alias's `lastSeenAt` freezes at whatever the last full
    /// Scan recorded. Found this way: `10.0.0.17` (AP1's VRRP address)
    /// sat unrefreshed for ~12 hours while its merged partner `10.0.0.16`
    /// polled successfully every minute — invisible in the popover, since
    /// the merge already hides the duplicate, but a `StoreInspector` dump
    /// or a direct query reads it as a device gone silent when it's the
    /// exact same hardware the primary just proved is alive.
    ///
    /// Deliberately quiet — no restart/software-change detection, no
    /// event logged. `recordSNMPDevice` already reports those for the
    /// merged device under its one display name; running the same
    /// detection again here on the same underlying data would just
    /// double the event.
    func syncAliasFreshness(primary: SNMPDevice) {
        guard !primary.aliasAddresses.isEmpty else { return }
        let fingerprint = currentNetworkFingerprint
        for alias in primary.aliasAddresses {
            var descriptor = FetchDescriptor<SNMPDeviceRecord>(
                predicate: #Predicate { $0.ipAddress == alias && $0.networkFingerprint == fingerprint }
            )
            descriptor.fetchLimit = 1
            guard let record = (try? context.fetch(descriptor))?.first else { continue }
            record.sysDescr = primary.sysDescr
            record.sysName = primary.sysName
            record.uptimeTicks = primary.uptimeTicks
            record.lastSeenAt = primary.polledAt
        }
        try? context.save()
    }

    /// Scoped by `currentNetworkFingerprint`: a different network's SNMP
    /// devices never show here.
    func fetchSNMPDevices(limit: Int = 100) -> [SNMPDeviceRecord] {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<SNMPDeviceRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Explicit-fingerprint sibling of `fetchSNMPDevices`, for Network
    /// Review — see `fetchDHCPLeaseHistory(for:limit:)`'s doc comment for
    /// why this never touches `currentNetworkFingerprint`.
    func fetchSNMPDevices(for fingerprint: String, limit: Int = 100) -> [SNMPDeviceRecord] {
        var descriptor = FetchDescriptor<SNMPDeviceRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Wipes persisted SNMP device state **for the current network only**.
    /// Used by `SNMPViewModel.scan()` so a manual sweep is a genuine
    /// clear-and-rediscover, not just a fresh in-memory list layered on
    /// top of old rows — without this, a device no longer present (e.g. a
    /// topology change, like switching which address represents a VRRP
    /// pair) would still reappear on next launch, since `SNMPViewModel`
    /// rehydrates from everything persisted here. Scoped rather than
    /// global specifically because of the scenario this whole feature
    /// exists for: a manual re-scan while on a *different* network must
    /// never wipe another network's already-recorded devices. Real cost:
    /// any device that *is* still around on this network gets a fresh
    /// `firstSeenAt` on rediscovery instead of keeping its real history —
    /// acceptable since this only runs on an explicit, manual "Scan"
    /// click, not automatically.
    func deleteAllSNMPDevices() {
        let fingerprint = currentNetworkFingerprint
        guard let matching = try? context.fetch(FetchDescriptor<SNMPDeviceRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint }
        )) else { return }
        for record in matching {
            context.delete(record)
        }
        try? context.save()
    }

    /// The most recent `limit` checks for one label, oldest-first for
    /// drawing.
    ///
    /// **Bounded by `fetchLimit`, not by slicing in Swift**, which is the
    /// trap this table specifically invites: it's the largest in the
    /// store by an order of magnitude (~90% of all rows), so fetching a
    /// label's entire history and taking the last 30 would cost more
    /// every day the app runs. With the limit the query cost tracks the
    /// point count instead of the table's lifetime.
    ///
    /// Returns value types, not `@Model` objects — see `LatencySample`.
    func fetchLatencyHistory(label: String, limit: Int = 30) -> [LatencySample] {
        var descriptor = FetchDescriptor<ConnectivityCheckRecord>(
            predicate: #Predicate { $0.label == label },
            sortBy: [SortDescriptor(\.checkedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let records = (try? context.fetch(descriptor)) ?? []
        // Fetched newest-first so the limit keeps the *recent* rows, then
        // reversed for drawing left-to-right in time order.
        return records.reversed().map { LatencySample(latencyMs: $0.latencyMs, checkedAt: $0.checkedAt) }
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
        let event = AppEventRecord(kind: kind, message: message, occurredAt: date, networkFingerprint: currentNetworkFingerprint)
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
    /// Scoped by `currentNetworkFingerprint`: a different network's events
    /// never show here.
    func fetchRecentEvents(limit: Int = 200) -> [AppEventRecord] {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<AppEventRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Explicit-fingerprint sibling of `fetchRecentEvents`, for Network
    /// Review — see `fetchDHCPLeaseHistory(for:limit:)`'s doc comment for
    /// why this never touches `currentNetworkFingerprint`.
    func fetchRecentEvents(for fingerprint: String, limit: Int = 200) -> [AppEventRecord] {
        var descriptor = FetchDescriptor<AppEventRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
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
