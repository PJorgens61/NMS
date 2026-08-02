import Foundation

/// A hard ceiling on any single string value parsed from untrusted,
/// network-supplied data — SNMP `sysDescr`/`sysName` (`SNMPService.probe`)
/// and DHCP option values (`DHCPLeaseService.parse`) — before it's
/// persisted. Found in a security review requested ahead of letting
/// friends try the app: neither parser had a length limit on
/// device-controlled strings. Not exploitable (everything renders through
/// plain `Text(String)`, never `Text(markdown:)`/`AttributedString
/// (markdown:)`, so there's no rendering-injection path regardless of
/// size), but a misbehaving or malicious LAN device could still bloat the
/// SwiftData store or slow a render with an oversized response.
enum UntrustedText {
    /// A few KB is generous for any legitimate sysDescr, sysName, or DHCP
    /// option value ever seen in practice, while still ruling out a
    /// deliberately oversized one.
    static let maxLength = 4096

    /// Truncates `value` to `maxLength` characters, unchanged if already
    /// within bounds. Applied at the parsing boundary — right where the
    /// raw value first enters the app — rather than at each downstream
    /// use, so nothing consuming it later needs to know this cap exists.
    static func capped(_ value: String, maxLength: Int = Self.maxLength) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength))
    }
}
