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
}
