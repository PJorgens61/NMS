import Foundation

/// Bundles a filed bug report's screenshot and header text (build,
/// severity, comment) into a zip on the Desktop, ready for a tester to
/// attach to whatever email client they actually use — asked directly
/// after confirming macOS has no way to hand a compose window off to a
/// browser-based mail provider (Gmail-in-a-tab included): the native
/// share-sheet API only reaches the system's registered mail app, a dead
/// end for a friend who's never configured one. Saving a plain file
/// works identically regardless of what they use.
///
/// Deliberately release-build-safe, unlike `StoreInspector`'s full state
/// dump: this only ever bundles the screenshot and the tester's own
/// typed comment, never the `#if DEBUG`-only dump's SNMP descriptors,
/// MAC addresses, or SSIDs — that boundary exists specifically so a
/// release build can't produce a file `sysdiagnose` would sweep up, and
/// this feature has no reason to reopen it.
///
/// `nonisolated`, matching `PrinterDiscoveryService`/`DNSResolutionService`:
/// shells out to `/usr/bin/zip` and blocks on `waitUntilExit()`, so it
/// must be callable from a background queue rather than confined to the
/// main actor by this project's default isolation.
nonisolated struct BugReportExportService {
    private static let zipExecutablePath = "/usr/bin/zip"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: zipExecutablePath)
    }

    /// `nil` on any failure (screenshot missing, `zip` unavailable, the
    /// process failing) — a friend testing the app losing this
    /// convenience is far less costly than the app crashing or blocking
    /// on it, same "silently does nothing" posture `ScreenshotService
    /// .capture` already takes for its own failure cases.
    ///
    /// Left on the Desktop with no retention/pruning, deliberately unlike
    /// `DebugArtifactRetention`'s handling of the internal screenshots/
    /// state-dumps directories — silently deleting files from someone's
    /// actual Desktop is a different, much bigger deal than pruning a
    /// `Library/Logs` folder nobody browses by hand.
    static func export(screenshotFilename: String, header: String) -> URL? {
        guard isAvailable else { return nil }
        let screenshotURL = ScreenshotService.directory.appendingPathComponent(screenshotFilename)
        guard FileManager.default.fileExists(atPath: screenshotURL.path) else { return nil }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let reportTextURL = stagingDirectory.appendingPathComponent("report.txt")
        guard (try? header.write(to: reportTextURL, atomically: true, encoding: .utf8)) != nil else { return nil }

        let reportName = (screenshotFilename as NSString).deletingPathExtension
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let zipURL = desktop.appendingPathComponent("\(reportName).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zipExecutablePath)
        // `-j` (junk paths): the zip holds just the two files at its top
        // level, not the staging directory's own folder structure — the
        // simplest possible thing to drag into an email.
        process.arguments = ["-j", zipURL.path, screenshotURL.path, reportTextURL.path]
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: zipURL.path) else { return nil }
        return zipURL
    }
}
