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
}
