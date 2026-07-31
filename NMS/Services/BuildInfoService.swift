import Foundation

/// "Which commit is this instance actually running" — for a single-
/// developer, single-machine tool this matters more than it sounds: a
/// build sitting in DerivedData can silently outlive several rounds of
/// source edits if Xcode isn't told to rebuild, and there's no other way
/// to tell from the running app alone.
///
/// Reads a stamp baked into the app bundle's `Info.plist` at build time by
/// the "Stamp build info" run-script phase — **not** git at runtime, which
/// is what this did before.
///
/// **Why that changed.** Reading git at launch answers "what does the
/// checkout say right now," which is a different question from "what was
/// this binary built from," and the two silently diverge the moment a
/// build goes stale — exactly the case this service exists to catch. It
/// failed at that in the worst way: a binary built 2026-07-29 12:26 ran
/// for two days displaying `dead27c+dirty`, a commit made well after it,
/// across several bug reports. That stale binary predated a schema change,
/// so it was also the only reason the store still opened — and the
/// misreported hash is what made the resulting bug (`BUGS.md`, "The
/// persistent store fails to open") look impossible for as long as it did.
/// A build stamp cannot drift this way: it is written by the same build
/// that produced the binary, or it is absent.
///
/// Absent is a real case and stays graceful: `nil` if the keys aren't
/// there (a build made before this phase existed, or one where `git`
/// wasn't available), which the popover already renders as "unknown"
/// rather than as an error. The stamping script is likewise written to
/// never fail a build — a missing build label is a far smaller problem
/// than an unbuildable project.
///
/// One consequence worth knowing: this no longer spawns a process at
/// launch, and no longer depends on the repo living at a hardcoded path,
/// so it now reports correctly on any machine rather than degrading to
/// `nil` off this one checkout.
enum BuildInfoService {
    /// Written by the "Stamp build info" build phase. Kept as constants
    /// rather than inline literals so the Swift side and that script have
    /// one obvious place to be compared against each other.
    private static let hashKey = "NMSGitHash"
    private static let subjectKey = "NMSGitSubject"
    private static let dirtyKey = "NMSGitDirty"

    struct Info {
        let shortHash: String
        let subject: String
        let isDirty: Bool
    }

    /// `nil` when the bundle carries no stamp at all — see the type's doc
    /// comment for when that happens and why it reads as "unknown" rather
    /// than as an error.
    static func current() -> Info? {
        guard let info = Bundle.main.infoDictionary,
              let hash = (info[hashKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hash.isEmpty
        else { return nil }

        let subject = (info[subjectKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Stamped as the strings "YES"/"NO" rather than a plist boolean:
        // `plutil -replace ... -string` is what the script uses for all
        // three keys, so they stay one consistent shape to read and to
        // eyeball in the built plist.
        let isDirty = (info[dirtyKey] as? String) == "YES"

        return Info(shortHash: hash, subject: subject, isDirty: isDirty)
    }
}
