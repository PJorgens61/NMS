import Foundation

/// Identifies the ISP behind the current public IP and, when known, its
/// status-page link — see `ISPIdentityService`. No timer of its own: a
/// registrant identity only changes when the public IP's owning
/// allocation changes, which `PublicIPViewModel` already detects, so
/// `identify(ip:)` is called from there rather than on its own cadence.
/// No SwiftData table — this is identification for display, not a
/// health check with up/down transitions to persist history for. It
/// does log one `AppEventKind`, `.ispOrganizationChanged` — see
/// `identify(ip:)` — the one edge case from a punchlist review of this
/// feature that turned out to be genuinely observable, unlike the
/// others (a blocked RDAP lookup, a status-page link failing to load)
/// which stay silent for the same reasons `SaaSStatusService`'s own
/// `.unknown` catch branch does.
@MainActor
@Observable
final class ISPIdentityViewModel {
    private(set) var organizationName: String? {
        didSet { UIStateLogger.log("ISPIdentityViewModel.organizationName", organizationName as Any) }
    }
    private(set) var statusPageURL: String?

    private let service = ISPIdentityService()
    private let snapshotStore: SnapshotStore

    /// Fired when an `AppEventRecord` gets logged (organization changed),
    /// so the event log view can refresh — same shape as every other
    /// producer `NMSApp.wireHistoryRefresh` wires up.
    var onEventLogged: (() -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    /// `nil` `ip` (no public IP known yet) is a silent no-op — there's
    /// nothing to look up, and this gets called again once
    /// `PublicIPViewModel` actually resolves one.
    func identify(ip: String?) {
        guard let ip else { return }
        Task {
            guard let name = try? await service.identify(ip: ip) else { return }
            // Captured before `organizationName` is overwritten below —
            // `nil` means either the very first identification this
            // session or a network just changed (`reset()` clears it),
            // neither of which is a real "change" worth logging. Mirrors
            // `PublicIPViewModel.apply`'s identical `previousIP` guard.
            let previousName = organizationName
            organizationName = name
            statusPageURL = service.statusPageURL(forOrganization: name)

            if let previousName, previousName != name {
                snapshotStore.logEvent(
                    .ispOrganizationChanged,
                    message: "ISP identified as \(name) (was \(previousName))"
                )
                onEventLogged?()
            }
        }
    }

    /// Called from `NMSApp`'s topology-change handling, right alongside
    /// `NetworkIdentityViewModel.reset()` — without this, switching
    /// networks left the *previous* network's ISP name and status-page
    /// link on screen until `identify(ip:)` happened to be called again,
    /// which only fires from `PublicIPViewModel.onCurrentIPChanged`
    /// (i.e. only once the new network's public IP is both checked and
    /// found to differ). Reported directly from offsite testing as old
    /// ISP info showing up on a new network — the same
    /// clear-before-recognizing shape every other per-network section
    /// already uses, just for state that lives here instead of
    /// `SnapshotStore`.
    func reset() {
        organizationName = nil
        statusPageURL = nil
    }
}
