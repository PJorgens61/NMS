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
}
