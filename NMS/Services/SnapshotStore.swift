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
        // Append-only timeline, same as events/leases above — no
        // uniqueness constraint to protect the way SNMPDeviceRecord's
        // block below does, so a plain retag is correct here.
        if let edges = try? context.fetch(FetchDescriptor<ProviderEdgeRecord>(
            predicate: #Predicate { $0.networkFingerprint == nil }
        )) {
            for edge in edges { edge.networkFingerprint = fingerprint }
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
    /// **Update: two of the three are read now.** This originally said
    /// nothing here was fetched at all, retained only because a *planned*
    /// sparklines feature would eventually read the first table — that
    /// feature has since shipped. `fetchLatencyHistory` reads
    /// `ConnectivityCheckRecord` for Network Health's per-layer
    /// sparklines, and `fetchWiFiSampleHistory` reads `WiFiSampleRecord`
    /// for the Wi-Fi RSSI sparkline and Network Review's Wi-Fi tab.
    /// `DiscoveredDeviceRecord` alone still fits the original claim —
    /// written (here and by LAN scans) and never fetched anywhere else
    /// (verified across the whole source). The retention math doesn't
    /// change either way: seven days is still ~700x what either
    /// sparkline's ~20-30-point window actually needs, so being read now
    /// rather than "eventually" doesn't argue for keeping more of it.
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

    /// Scoped to `currentNetworkFingerprint` — same reasoning as
    /// `latestProviderEdge`: a hop confirmed as the ISP edge router on one
    /// network shouldn't read back as confirmed on a different one just
    /// because it happens to share the same hop number. `nil` while the
    /// current network isn't recognized yet, same as every other
    /// per-network read in this file.
    func confirmedEdgeHopNumber() -> Int? {
        guard let fingerprint = currentNetworkFingerprint else { return nil }
        var descriptor = FetchDescriptor<KnownNetwork>(
            predicate: #Predicate { $0.fingerprint == fingerprint }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.confirmedEdgeHopNumber
    }

    /// A no-op if the current network isn't recognized yet (no
    /// `KnownNetwork` row to attach the confirmation to) — matches
    /// `updateLatestProviderEdgeHostname`'s same tolerance elsewhere in
    /// this file. In practice this doesn't lose the confirmation: the
    /// user can only confirm a hop from a completed trace's popover,
    /// which is well after recognition normally completes.
    ///
    /// Always marks `hasDecidedEdgeHop`, regardless of whether
    /// `hopNumber` is a real value or `nil` — confirming a hop and
    /// explicitly clearing one ("Stop monitoring") are both a decision,
    /// and `TracerouteViewModel`'s auto-confirm must never act again on a
    /// network either one has touched. See that field's own doc comment.
    func setConfirmedEdgeHopNumber(_ hopNumber: Int?) {
        guard let fingerprint = currentNetworkFingerprint else { return }
        var descriptor = FetchDescriptor<KnownNetwork>(
            predicate: #Predicate { $0.fingerprint == fingerprint }
        )
        descriptor.fetchLimit = 1
        guard let network = (try? context.fetch(descriptor))?.first else { return }
        network.confirmedEdgeHopNumber = hopNumber
        network.hasDecidedEdgeHop = true
        try? context.save()
    }

    /// Whether *any* decision (confirm or explicit clear) has ever been
    /// made about the current network's ISP edge hop — see
    /// `KnownNetwork.hasDecidedEdgeHop`'s own doc comment. `false` while
    /// the current network isn't recognized yet, same as every other
    /// per-network read in this file — nothing to have decided on
    /// without a `KnownNetwork` row yet, so auto-confirm simply waits
    /// for recognition like everything else per-network does.
    func hasDecidedEdgeHop() -> Bool {
        guard let fingerprint = currentNetworkFingerprint else { return false }
        var descriptor = FetchDescriptor<KnownNetwork>(
            predicate: #Predicate { $0.fingerprint == fingerprint }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.hasDecidedEdgeHop ?? false
    }

    /// Whether the current network is the one marked home — `false` while
    /// unrecognized, same as every other per-network read in this file.
    /// `DDNSViewModel.checkAll()` gates on this directly: confirmed live
    /// (2026-08-04, off-site) that without a gate, DDNS hostname checking
    /// keeps comparing a home hostname against whatever network's public
    /// IP happens to be current, displaying the home network's own setup
    /// while connected somewhere else entirely.
    func isCurrentNetworkHome() -> Bool {
        guard let fingerprint = currentNetworkFingerprint else { return false }
        var descriptor = FetchDescriptor<KnownNetwork>(
            predicate: #Predicate { $0.fingerprint == fingerprint }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.isHome ?? false
    }

    /// Marks `network` as home, or clears it. A singleton designation —
    /// setting `true` clears every other network's flag first, so at most
    /// one is ever marked, matching `isCurrentNetworkHome()`'s assumption
    /// of a single unambiguous "home."
    func setHome(_ isHome: Bool, for network: KnownNetwork) {
        if isHome {
            let othersDescriptor = FetchDescriptor<KnownNetwork>(
                predicate: #Predicate { $0.isHome == true }
            )
            for other in (try? context.fetch(othersDescriptor)) ?? [] where other.fingerprint != network.fingerprint {
                other.isHome = false
            }
        }
        network.isHome = isHome
        try? context.save()
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
        // Added late, and that's the point worth recording: this method
        // was written when there were three per-network tables, and
        // `WiFiSampleRecord` shipped afterwards without anything
        // connecting the two. Found by deleting a real network and
        // noticing 90 samples survive it — with SSID and BSSID attached,
        // which is precisely what "forget this network" should remove.
        //
        // Worse than orphaned rows: `KnownNetwork.fingerprint` is derived
        // (`routerMAC|subnet`), so rejoining the same network mints the
        // identical fingerprint and the "forgotten" samples silently
        // reattach to it.
        //
        // **Anything added to this file with a `networkFingerprint` must
        // be deleted here too.** There is no compiler check for that — the
        // four tables are related only by convention.
        if let samples = try? context.fetch(FetchDescriptor<WiFiSampleRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint }
        )) {
            for sample in samples { context.delete(sample) }
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

    /// Same as `latestDHCPLease()`, additionally scoped to one specific
    /// interface — the fix for a real bug found live (2026-08-06) on a
    /// Mac that keeps both Ethernet and Wi-Fi active at once: the
    /// unscoped lookup returns whichever interface happened to report
    /// *most recently*, so a routine, unchanged renewal on `en1` compared
    /// itself against `en0`'s last lease instead of `en1`'s own —
    /// producing a bogus "address 10.0.0.158 → 10.0.0.161" Events log
    /// entry, when neither interface's actual lease had changed at all.
    /// `recordDHCPLeaseIfChanged` and `DHCPLeaseViewModel.apply`'s own
    /// `fieldChanges` comparison both need "this interface's previous
    /// lease," never any interface's.
    func latestDHCPLease(forInterface interfaceName: String) -> DHCPLeaseRecord? {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<DHCPLeaseRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint && $0.interfaceName == interfaceName },
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
    ///
    /// Deliberately a no-op while `currentNetworkFingerprint` is still
    /// `nil` (not yet recognized) — see BUGS.md's "DHCP History gets a
    /// duplicate row" entry. `DHCPLeaseViewModel` checks once at launch
    /// and on every topology change, both of which can land before the
    /// first LAN scan recognizes the network. Recording under `nil`
    /// looked harmless (`NetworkIdentityViewModel.recognize`'s
    /// `adoptUntaggedRecords` retroactively re-tags it once recognition
    /// completes), but broke this method's own dedup: the *next* time
    /// this runs under `nil` again (e.g. the following launch), the prior
    /// row already carries the real fingerprint, not `nil` — so the
    /// `nil`-scoped lookup below finds nothing, `previous` comes back
    /// `nil`, and an unchanged lease gets inserted as a "new" one.
    /// Skipping here instead is safe: `check()` retries in 300s
    /// regardless, and `NMSApp.wireDependencies` also fires it directly
    /// from `onNetworkRecognized`, so the real write just happens once
    /// the fingerprint is actually known, correctly scoped the first time.
    @discardableResult
    func recordDHCPLeaseIfChanged(_ info: DHCPLeaseInfo) -> (changed: Bool, isFirstEver: Bool) {
        guard let fingerprint = currentNetworkFingerprint else { return (false, false) }
        // Scoped to this same interface -- see `latestDHCPLease(forInterface:)`'s
        // own doc comment for the real cross-interface bug this fixes on
        // a Mac that keeps Ethernet and Wi-Fi both active.
        let previous = latestDHCPLease(forInterface: info.interfaceName)
        guard previous?.transactionID != info.transactionID else { return (false, false) }
        context.insert(DHCPLeaseRecord(from: info, firstObservedAt: info.checkedAt, networkFingerprint: fingerprint))
        try? context.save()
        return (true, previous == nil)
    }

    /// Unconditional insert, unlike every other "record" method here —
    /// every speed-test run is an intentional, standalone data point the
    /// user wants to compare against past ones, not a change to dedupe
    /// against. See `NetworkQualityResult`.
    func recordNetworkQualityResult(_ result: NetworkQualityResult) {
        context.insert(NetworkQualityRecord(from: result, networkFingerprint: currentNetworkFingerprint))
        try? context.save()
    }

    /// Unconditional insert, same reasoning as `recordNetworkQualityResult`
    /// — every stress-test run is a deliberate data point, not a change
    /// to dedupe against. See `WiFiStressTestResult`.
    func recordWiFiStressTestResult(_ result: WiFiStressTestResult) {
        context.insert(WiFiStressTestRecord(from: result, networkFingerprint: currentNetworkFingerprint))
        try? context.save()
    }

    /// Scoped by `currentNetworkFingerprint`: a different network's stress
    /// test runs never show here. See `WiFiStressTestRecord.networkFingerprint`.
    func fetchWiFiStressTestHistory(limit: Int = 10) -> [WiFiStressTestRecord] {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<WiFiStressTestRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.testedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Unconditional insert, same reasoning as `recordNetworkQualityResult`
    /// — every FW scan is a deliberate data point the user asked for (or
    /// that a scheduled/SNMP-triggered run made on their behalf), not a
    /// change to dedupe against. FW's own server is stateless (see
    /// `FWClient`'s doc comment); this is the one and only place a scan's
    /// result is actually kept.
    @discardableResult
    func recordFirewallScan(_ job: FWClient.ScanJob) -> FirewallScanRecord {
        let record = FirewallScanRecord(
            scannedAt: job.completedAt ?? Date(),
            targetIPv4: job.targetIPv4,
            targetIPv6: job.targetIPv6,
            results: job.results,
            networkFingerprint: currentNetworkFingerprint
        )
        context.insert(record)
        try? context.save()
        return record
    }

    /// The scan immediately before the one just recorded — what
    /// `FirewallVisibilityViewModel.diff(previous:current:)` compares
    /// against to decide whether anything newly opened or closed.
    func previousFirewallScan(before date: Date) -> FirewallScanRecord? {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<FirewallScanRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint && $0.scannedAt < date },
            sortBy: [SortDescriptor(\.scannedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Scoped by `currentNetworkFingerprint`: a different network's scan
    /// history never shows here — same reasoning `fetchWiFiStressTestHistory`
    /// gives, and doubly so here since a coffee shop's firewall isn't
    /// something this Mac's owner controls or cares about tracking.
    func fetchFirewallScanHistory(limit: Int = 10) -> [FirewallScanRecord] {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<FirewallScanRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.scannedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Scoped by `currentNetworkFingerprint`: a different network's speed
    /// tests never show here. See `NetworkQualityRecord.networkFingerprint`.
    func fetchNetworkQualityHistory(limit: Int = 10) -> [NetworkQualityRecord] {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<NetworkQualityRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.testedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// `.quickCheck`-source rows only, filtered at the query level rather
    /// than fetched via `fetchNetworkQualityHistory` and post-filtered in
    /// Swift — the quick check is expected to run far more often than a
    /// full speed test (it's the "before a video call" habit, not the
    /// occasional deliberate one), so post-filtering a shared, small
    /// `limit` could starve this down to just a couple of points whenever
    /// full-test runs happen to be interleaved. Filtering in the
    /// predicate means `limit` always means "this many quick checks,"
    /// not "this many of any kind that happened to include some."
    /// Default of 15, not 10 — matches the dot-history row's own width
    /// budget (see `PUNCHLIST.md`'s "Network Health and Info tiles" item).
    func fetchQuickCheckHistory(limit: Int = 15) -> [NetworkQualityRecord] {
        let fingerprint = currentNetworkFingerprint
        let sourceValue = NetworkQualityResult.Source.quickCheck.rawValue
        var descriptor = FetchDescriptor<NetworkQualityRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint && $0.source == sourceValue },
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

    /// Separate from `recordSNMPDevice` because web detection resolves
    /// asynchronously, well after the SNMP poll that discovered or
    /// re-confirmed the device already upserted its own row — folding
    /// this into that method would mean persisting `nil` every round
    /// (the freshly-polled `SNMPDevice` never carries a `webURL` of its
    /// own; only `SNMPViewModel`'s in-memory patch does). Silent no-op if
    /// the device's row is somehow gone by the time this resolves (e.g. a
    /// network switch mid-probe) — nothing to update.
    func updateSNMPDeviceWebURL(address: String, url: String) {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<SNMPDeviceRecord>(
            predicate: #Predicate { $0.ipAddress == address && $0.networkFingerprint == fingerprint }
        )
        descriptor.fetchLimit = 1
        guard let existing = (try? context.fetch(descriptor))?.first else { return }
        existing.webURL = url
        try? context.save()
    }

    /// Same reasoning as `updateSNMPDeviceWebURL` just above, for the
    /// same reason: `ReverseDNSService`'s lookup resolves asynchronously,
    /// after `recordSNMPDevice` already upserted this round's row.
    func updateSNMPDeviceHostname(address: String, hostname: String) {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<SNMPDeviceRecord>(
            predicate: #Predicate { $0.ipAddress == address && $0.networkFingerprint == fingerprint }
        )
        descriptor.fetchLimit = 1
        guard let existing = (try? context.fetch(descriptor))?.first else { return }
        existing.hostname = hostname
        try? context.save()
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

    /// `networkFingerprint`, when given, overrides `currentNetworkFingerprint`
    /// for this one event — see `WiFiSSIDViewModel.logNetworkChangeIfNeeded`,
    /// the one caller that needs it: a network-transition event describes
    /// something that happened *on the network being left*, but by the time
    /// it's logged (after `NetworkIdentityViewModel.reset()` has already
    /// cleared `currentNetworkFingerprint` for the topology change in
    /// progress) the ambient value no longer reflects that network at all.
    /// `nil` (the default, every other call site) keeps today's behavior —
    /// tag with whatever's currently live.
    @discardableResult
    func logEvent(_ kind: AppEventKind, message: String, at date: Date = Date(), networkFingerprint: String? = nil, url: String? = nil) -> AppEventRecord {
        let event = AppEventRecord(kind: kind, message: message, occurredAt: date, networkFingerprint: networkFingerprint ?? currentNetworkFingerprint, url: url)
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

    /// Scoped to `currentNetworkFingerprint` — same reasoning as
    /// `latestDHCPLease`: an edge address from a different network
    /// shouldn't count as "the previous edge" for change detection, or
    /// show as this network's fallback ping target
    /// (`TracerouteViewModel.monitoredHopAddress`).
    ///
    /// **A real crash was chased here and NOT fixed by rewriting this
    /// query** — see `PathDiscoveryEventLoggingTests`' own doc comment
    /// and the cross-machine sync issue for the live findings. Confirmed
    /// on two machines that calling this from a fresh in-memory
    /// `ModelContainer` traps deep inside `SwiftData.framework` itself —
    /// and confirmed here that removing the `#Predicate`, the
    /// `SortDescriptor`, and the `fetchLimit` in turn (a fully bare
    /// `context.fetch(FetchDescriptor<ProviderEdgeRecord>())`, no
    /// modifiers at all) still crashes identically. So this is back to
    /// its original, simplest form — rewriting the query further didn't
    /// help and only adds risk to code this app has otherwise relied on
    /// correctly for weeks against the real on-disk store. Left as a
    /// real open question whether this is specific to the ephemeral
    /// in-memory test configuration (most likely, given production
    /// hasn't shown this) or something that could affect the real store
    /// too — not yet ruled out either way.
    func latestProviderEdge() -> ProviderEdgeRecord? {
        let fingerprint = currentNetworkFingerprint
        var descriptor = FetchDescriptor<ProviderEdgeRecord>(
            predicate: #Predicate { $0.networkFingerprint == fingerprint },
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Persists a new row only if the ISP edge router's address actually
    /// changed since the last recorded value — mirrors
    /// `recordPublicIPIfChanged`: a timeline of real changes, not a
    /// per-traceroute-run log. Returns whether it changed.
    @discardableResult
    func recordProviderEdgeIfChanged(address: String, hostname: String?, at date: Date = Date()) -> Bool {
        guard latestProviderEdge()?.address != address else { return false }
        context.insert(ProviderEdgeRecord(
            address: address,
            hostname: hostname,
            observedAt: date,
            networkFingerprint: currentNetworkFingerprint
        ))
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

    /// Records the result of a Path Discovery run (`GlobalpingReverseTraceService`)
    /// against the most recent `ProviderEdgeRecord` row — always records
    /// `probeCount`/`corroboratingCount` so the tile can show "ran, but
    /// nothing matched" honestly, distinct from "never run at all" (both
    /// `nil`). `externallyCorroboratedAt` only updates when at least one
    /// probe actually matched — a run that finds zero corroboration
    /// shouldn't refresh a timestamp implying it was just reconfirmed.
    /// Same "no-op if the address has since moved on" tolerance as
    /// `updateLatestProviderEdgeHostname` above. `probeCount`/
    /// `corroboratingCount` are expected to already be gap-filtered — see
    /// `TracerouteViewModel.corroboratingSummary`.
    ///
    /// Also logs `.pathDiscoveryCorroborated`/`.pathDiscoveryNotCorroborated`
    /// on a genuine change from the previous run against this same row
    /// (or on the very first run for it — a deliberate manual click is
    /// always new information, unlike an automatically-repeating check
    /// observing "just where it already is"). Nothing is logged when
    /// `probeCount` is zero (every probe hit a reply gap — no real data
    /// either way), and the negative kind specifically is suppressed
    /// when `isKnownComplexTopology` is true — raised directly ("only in
    /// certain circumstances?"): under confirmed CGNAT, divergence across
    /// external vantage points is expected, not news.
    func recordPathDiscoveryRun(address: String, probeCount: Int, corroboratingCount: Int, isKnownComplexTopology: Bool, at date: Date = Date()) {
        guard let latest = latestProviderEdge(), latest.address == address else { return }
        let previousCorroborated: Bool? = latest.pathDiscoveryProbeCount == nil ? nil : (latest.pathDiscoveryCorroboratingCount ?? 0) > 0
        let newCorroborated = corroboratingCount > 0

        latest.pathDiscoveryProbeCount = probeCount
        latest.pathDiscoveryCorroboratingCount = corroboratingCount
        if corroboratingCount > 0 {
            latest.externallyCorroboratedAt = date
        }
        try? context.save()

        guard probeCount > 0, previousCorroborated != newCorroborated else { return }
        if newCorroborated {
            logEvent(
                .pathDiscoveryCorroborated,
                message: "Path Discovery: \(corroboratingCount) of \(probeCount) external source\(probeCount == 1 ? "" : "s") confirm \(address) as the ISP edge router.",
                at: date
            )
        } else if !isKnownComplexTopology {
            logEvent(
                .pathDiscoveryNotCorroborated,
                message: "Path Discovery: none of \(probeCount) external source\(probeCount == 1 ? "" : "s") reached \(address) as the last hop before this Mac — could be asymmetric routing, or the confirmed hop may be worth rechecking.",
                at: date
            )
        }
    }
}
