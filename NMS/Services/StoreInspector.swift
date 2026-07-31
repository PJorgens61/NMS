import Foundation
import SwiftData

/// Debug-only dump of everything in the SwiftData store, as plain text.
///
/// Exists because inspecting this app's persisted state otherwise means
/// running `sqlite3` against the store by hand, and Core Data's on-disk
/// schema is actively hostile to that: every table is `Z`-prefixed
/// (`ZAPPEVENTRECORD`), every column too (`ZOCCURREDAT`), and every date
/// is stored in Apple's 2001 epoch, so even "show me recent events"
/// needs `datetime(ZOCCURREDAT + 978307200, 'unixepoch', 'localtime')`.
/// That query got hand-written more than a dozen times in a single
/// debugging session before this existed.
///
/// `#if DEBUG` throughout, for the same reason `UIStateLogger` is: this
/// writes SSIDs, MAC addresses, the public IP, SNMP descriptors and the
/// full event history into `~/Library/Logs/`, which `sysdiagnose`
/// collects. A release build must not be able to produce this file at
/// all.
enum StoreInspector {
    #if DEBUG
    private static let directory = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NMS/state-dumps", isDirectory: true)

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let rowFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
    #endif

    /// Writes a dump and returns its filename, or `nil` in release
    /// builds and on failure. Rows per table are capped — this is meant
    /// to be read, and `ConnectivityCheckRecord` alone can hold six
    /// figures of rows (see `SnapshotStore.pruneIfNeeded`).
    ///
    /// `header`, when given, is written verbatim right after the
    /// timestamp line — the bug-report path (`ScreenshotViewModel
    /// .captureBugReport`) uses this for the user's comment, build hash,
    /// and current severity, so the dump is self-contained (matches what
    /// it was captured *for*) without this type needing to know anything
    /// about builds or severity itself.
    @MainActor
    static func dump(context: ModelContext, rowsPerTable: Int = 8, header: String? = nil) -> String? {
        #if DEBUG
        var text = "NMS store dump — \(Date())\n"
        if let header, !header.isEmpty {
            text += header
            if !header.hasSuffix("\n") { text += "\n" }
        }
        text += String(repeating: "=", count: 60) + "\n"

        // Ordered roughly by how often each gets asked about while
        // debugging, not alphabetically or by size.
        text += section(context, "AppEventRecord", \AppEventRecord.occurredAt, rowsPerTable) {
            "\($0.kind): \($0.message)"
        }
        text += section(context, "DHCPLeaseRecord", \DHCPLeaseRecord.observedAt, rowsPerTable) {
            "\($0.serverIdentifier) → \($0.assignedAddress) · lease \($0.leaseSeconds)s · T1 \($0.t1Seconds)s · T2 \($0.t2Seconds)s · \($0.transactionID)"
        }
        text += section(context, "NetworkQualityRecord", \NetworkQualityRecord.testedAt, rowsPerTable) {
            String(format: "↓ %.0f Mbps  ↑ %.0f Mbps", $0.downloadMbps, $0.uploadMbps)
        }
        text += section(context, "SNMPDeviceRecord", \SNMPDeviceRecord.lastSeenAt, rowsPerTable) {
            "\($0.ipAddress) \($0.sysName ?? "—") · uptime \($0.uptimeTicks) · community \($0.community)"
        }
        text += section(context, "NetworkSnapshot", \NetworkSnapshot.capturedAt, rowsPerTable) {
            "\($0.interfaceName) \($0.ipAddress ?? "—")/\($0.subnetMask ?? "—") gw \($0.routerAddress ?? "—") dns \($0.dnsServer ?? "—")\($0.isWiFi ? " (Wi-Fi)" : "")"
        }
        text += section(context, "PublicIPRecord", \PublicIPRecord.observedAt, rowsPerTable) {
            $0.ipAddress
        }
        text += section(context, "KnownNetwork", \KnownNetwork.lastSeenAt, rowsPerTable) {
            "\($0.fingerprint) \($0.label ?? "—") · seen \($0.timesSeen)×"
        }
        text += section(context, "ProviderEdgeRecord", \ProviderEdgeRecord.observedAt, rowsPerTable) {
            "\($0.address) \($0.hostname ?? "—")"
        }
        text += section(context, "ConnectivityCheckRecord", \ConnectivityCheckRecord.checkedAt, rowsPerTable) {
            let latency = $0.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—"
            // Load included because it's the field that answers "was the
            // Mac pinned when this failed?" — the whole reason it's
            // persisted.
            let load = $0.systemLoad.map { String(format: " load %.2f", $0) } ?? ""
            return "\($0.label) \($0.success ? "ok" : "FAIL") \(latency)\($0.correlatedWithChange ? " *" : "")\(load)"
        }
        text += section(context, "DiscoveredDeviceRecord", \DiscoveredDeviceRecord.discoveredAt, rowsPerTable) {
            "\($0.ipAddress) \($0.macAddress ?? "—") \($0.hostname ?? "—")"
        }
        text += section(context, "WiFiSampleRecord", \WiFiSampleRecord.sampledAt, rowsPerTable) {
            let rssi = $0.rssi.map { "\($0) dBm" } ?? "—"
            let phy = $0.phyRateMbps.map { "\(Int($0)) Mbps" } ?? "—"
            return "\($0.ssid ?? "—") \(rssi) ch \($0.channelNumber.map(String.init) ?? "—") \(phy)"
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "NMS-state-\(fileFormatter.string(from: Date())).txt"
        guard (try? text.write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return filename
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// One table's summary: total count, the span it covers, and the
    /// newest few rows. The count and span matter as much as the rows —
    /// "4280 rows spanning 4h29m" is what made the growth rate
    /// measurable in the first place, and a count that doesn't move
    /// after a prune is how a silently-failing delete gets noticed.
    private static func section<T: PersistentModel>(
        _ context: ModelContext,
        _ name: String,
        _ dateKey: KeyPath<T, Date> & Sendable,
        _ limit: Int,
        describe: (T) -> String
    ) -> String {
        var descriptor = FetchDescriptor<T>(sortBy: [SortDescriptor(dateKey, order: .reverse)])
        guard let total = try? context.fetchCount(descriptor) else {
            return "\n\(name): <fetch failed>\n"
        }
        guard total > 0 else {
            return "\n\(name): 0 rows\n"
        }

        descriptor.fetchLimit = limit
        guard let rows = try? context.fetch(descriptor), let newest = rows.first else {
            return "\n\(name): \(total) rows, <fetch failed>\n"
        }

        var oldestDescriptor = FetchDescriptor<T>(sortBy: [SortDescriptor(dateKey, order: .forward)])
        oldestDescriptor.fetchLimit = 1
        let oldest = (try? context.fetch(oldestDescriptor))?.first

        var text = "\n\(name): \(total) rows"
        if let oldest {
            let span = newest[keyPath: dateKey].timeIntervalSince(oldest[keyPath: dateKey])
            text += "  (\(rowFormatter.string(from: oldest[keyPath: dateKey])) → "
            text += "\(rowFormatter.string(from: newest[keyPath: dateKey])), spanning \(durationText(span)))"
        }
        text += "\n"
        if total > limit {
            text += "  showing newest \(limit):\n"
        }
        for row in rows {
            text += "  \(rowFormatter.string(from: row[keyPath: dateKey]))  \(describe(row))\n"
        }
        return text
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3600 { return String(format: "%.0fm", seconds / 60) }
        if seconds < 86400 { return String(format: "%.1fh", seconds / 3600) }
        return String(format: "%.1fd", seconds / 86400)
    }
    #endif
}
