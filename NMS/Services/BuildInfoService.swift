import Foundation

/// "Which commit is this instance actually running" — for a single-
/// developer, single-machine tool this matters more than it sounds: a
/// build sitting in DerivedData can silently outlive several rounds of
/// source edits if Xcode isn't told to rebuild, and there's no other way
/// to tell from the running app alone.
///
/// Reads `git rev-parse --short HEAD` and the commit's subject line
/// directly from the known checkout path at launch — a build-time stamp
/// (an Xcode Run Script phase writing a generated Swift file) would be more
/// correct in general, but this project only ever runs on the machine it
/// was built on moments earlier via Cmd+R, so "current checkout state at
/// launch" and "what got compiled" are the same thing in practice, without
/// adding a build phase to a project that just had its build-file
/// duplication cleaned up.
///
/// The hardcoded path is a real, deliberate limitation: this never runs
/// anywhere but this one checkout. If the repo ever moves, or this ships to
/// another machine, `current()` degrades to `nil` — never a crash, and
/// never stale data mistaken for current.
enum BuildInfoService {
    private static let repoPath = NSString(string: "~/Developer/NMS").expandingTildeInPath

    struct Info {
        let shortHash: String
        let subject: String
        let isDirty: Bool
    }

    /// `nil` if the repo isn't at the expected path, `git` isn't on the
    /// expected path, or the working tree somehow isn't a git repo at all —
    /// any of which should read as "unknown," not as an error worth
    /// surfacing to the user.
    static func current() -> Info? {
        guard let hash = run(["rev-parse", "--short", "HEAD"]) else { return nil }
        let subject = run(["log", "-1", "--format=%s"]) ?? ""
        let dirty = !(run(["status", "--porcelain"]) ?? "").isEmpty
        return Info(shortHash: hash, subject: subject, isDirty: dirty)
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath] + arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty ?? true) ? nil : output
    }
}
