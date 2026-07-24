import Foundation
import SwiftData

/// The kinds of events worth logging to the app's event timeline. Deliberately
/// narrow — this is for "something worth noticing happened," not a catch-all
/// debug log. Each bad-state kind has a matching recovery kind, so an outage
/// is bracketed by two events (start and end) rather than only ever showing
/// when things broke.
enum AppEventKind: String, Codable {
    case interfaceDown
    case interfaceUp
    case interfaceChanged
    case routerUnreachable
    case routerReachable
    case internetUnreachable
    case internetReachable
    case dnsUnreachable
    case dnsReachable
    case httpUnreachable
    case httpReachable
    case publicIPChanged

    enum Polarity {
        case positive, negative, neutral
    }

    /// Recoveries render as positive (green), bad states as negative (red);
    /// a public IP change or an interface failover is neither — it's just
    /// information, not a problem or a fix — so both render neutral. See
    /// `ContentView.eventColor`.
    var polarity: Polarity {
        switch self {
        case .interfaceUp, .routerReachable, .internetReachable, .dnsReachable, .httpReachable:
            return .positive
        case .interfaceDown, .routerUnreachable, .internetUnreachable, .dnsUnreachable, .httpUnreachable:
            return .negative
        case .publicIPChanged, .interfaceChanged:
            return .neutral
        }
    }
}

/// A single entry in the app's event log. Logged only on state transitions
/// (see `NetworkMonitorViewModel` and `ConnectivityViewModel`), not
/// repeatedly while a condition persists — otherwise a router that's down
/// for an hour would produce one row per connectivity-check cycle.
@Model
final class AppEventRecord {
    var kind: String
    var message: String
    var occurredAt: Date

    init(kind: AppEventKind, message: String, occurredAt: Date = Date()) {
        self.kind = kind.rawValue
        self.message = message
        self.occurredAt = occurredAt
    }
}
