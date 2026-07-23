import Foundation

/// A single public-IP lookup result.
struct PublicIPInfo: Equatable, Codable {
    let ipAddress: String
    let checkedAt: Date
}
