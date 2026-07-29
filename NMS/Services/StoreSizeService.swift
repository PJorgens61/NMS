import Foundation

/// Reports how much disk space the SwiftData store actually occupies.
///
/// **Must sum three files, not one.** SwiftData's SQLite backend runs in
/// WAL mode, which keeps recent writes in a separate `-wal` file (flushed
/// into the main store only on a checkpoint) plus a small `-shm` shared-
/// memory index. Checked directly against the real store rather than
/// assumed: at one point the `-wal` file (4.2 MB) was larger than the
/// main `.store` file itself (2.0 MB) — reporting only the base file
/// would have understated real usage by more than half.
enum StoreSizeService {
    /// `nil` if the base file doesn't exist yet (e.g. the very first
    /// launch, before anything has been written) — reported as absent
    /// rather than as a misleading "0 bytes".
    static func totalBytes(at storeURL: URL) -> Int64? {
        let sidecarSuffixes = ["-wal", "-shm"]
        let basePath = storeURL.path
        guard FileManager.default.fileExists(atPath: basePath) else { return nil }

        var total: Int64 = fileSize(atPath: basePath) ?? 0
        for suffix in sidecarSuffixes {
            if let size = fileSize(atPath: basePath + suffix) {
                total += size
            }
        }
        return total
    }

    /// Formatted for the popover footer — short enough to sit on one
    /// line next to the build hash. `ByteCountFormatter` over a
    /// hand-rolled KB/MB table: it already handles the GB case this app
    /// hasn't needed yet but eventually will as retention-bounded tables
    /// keep accumulating.
    static func formattedSize(at storeURL: URL) -> String? {
        guard let bytes = totalBytes(at: storeURL) else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    private static func fileSize(atPath path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.size] as? Int64
    }
}
