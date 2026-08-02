import Foundation
import Combine

/// Identifies the ISP behind the current public IP and, when known, its
/// status-page link — see `ISPIdentityService`. No timer of its own: a
/// registrant identity only changes when the public IP's owning
/// allocation changes, which `PublicIPViewModel` already detects, so
/// `identify(ip:)` is called from there rather than on its own cadence.
/// No `AppEventKind`, no SwiftData table — this is identification for
/// display, not a health check with up/down transitions to log.
@MainActor
final class ISPIdentityViewModel: ObservableObject {
    @Published private(set) var organizationName: String? {
        didSet { UIStateLogger.log("ISPIdentityViewModel.organizationName", organizationName as Any) }
    }
    @Published private(set) var statusPageURL: String?

    private let service = ISPIdentityService()

    /// `nil` `ip` (no public IP known yet) is a silent no-op — there's
    /// nothing to look up, and this gets called again once
    /// `PublicIPViewModel` actually resolves one.
    func identify(ip: String?) {
        guard let ip else { return }
        Task {
            guard let name = try? await service.identify(ip: ip) else { return }
            organizationName = name
            statusPageURL = service.statusPageURL(forOrganization: name)
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
