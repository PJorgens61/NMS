import Foundation

/// Shared pruning for the debug-artifact directories that write one
/// timestamped file per user action — `ScreenshotService`'s screenshots
/// and `StoreInspector`'s state dumps. Neither had any retention at all
/// until now: `SnapshotStore.pruneIfNeeded` exists precisely because
/// unbounded growth was a real, measured pain point for the SQLite
/// tables, and these two directories carry the identical risk on disk
/// instead — just slower to notice, since a PNG or text file sitting in
/// `~/Library/Logs/NMS/` doesn't show up in any store-size reading.
enum DebugArtifactRetention {
    /// How long a screenshot or state dump is kept before being pruned on
    /// the next write to its directory. Longer than
    /// `SnapshotStore.telemetryRetention` (7 days) deliberately: each file
    /// here is the result of a deliberate button click, not automatic
    /// per-round telemetry, so it's already curated rather than
    /// bulk-generated. 30 days covers "what did this look like last
    /// month" without growing unbounded across a menu bar app that's
    /// designed to stay running for weeks.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Deletes every file in `directory` whose modification date is older
    /// than `retention`. Called on every new write rather than from a
    /// timer, same reasoning `SnapshotStore.pruneIfNeeded`'s doc comment
    /// gives: tying cleanup to the action that causes growth makes it
    /// self-limiting, and there's no separate scheduling mechanism to own.
    /// No throttle, unlike that method's hourly one — that one exists
    /// because its trigger is a check round every 5-30s; a screenshot or
    /// bug report is a deliberate, infrequent click, so pruning on every
    /// one of them costs nothing worth guarding against.
    static func pruneFiles(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-retention)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for file in files {
            guard
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
