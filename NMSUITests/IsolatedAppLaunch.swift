import XCTest

/// Points a launched app at a throwaway store instead of the real
/// `~/Library/Application Support/NMS/default.store` — see BUGS.md's
/// "NMSUITests launches the real app against the real, on-disk production
/// store." `-NMSStorePath` is `NMSApp.storeURL()`'s own existing
/// `#if DEBUG` override (already used by `script/scenarios.sh`, via
/// `defaults write`); here it's set through `launchArguments` instead,
/// since Foundation registers `-Key value` launch arguments into
/// `UserDefaults.standard`'s argument domain for just that one process —
/// no `defaults write`/`defaults delete` cleanup needed, and no risk of
/// racing a real running instance's own preferences.
///
/// Returns the scratch path so the caller can remove it in `tearDown`
/// (`.store`, `.store-shm`, `.store-wal` — SwiftData's SQLite store
/// leaves all three).
extension XCUIApplication {
    @discardableResult
    func configureIsolatedStore() -> String {
        let path = NSTemporaryDirectory().appending("NMSUITests-\(UUID().uuidString).store")
        launchArguments += ["-NMSStorePath", path]
        return path
    }
}

func removeIsolatedStore(at path: String) {
    for suffix in ["", "-shm", "-wal"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
    }
}
