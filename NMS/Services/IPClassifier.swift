import Foundation

/// Classifies IPv4 addresses as private (RFC 1918) or not. Used to tell
/// "still on my own LAN" apart from "actually out on the internet" when
/// walking a traceroute path.
struct IPClassifier {
    /// RFC 1918 private ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
    static func isRFC1918(_ ipAddress: String) -> Bool {
        let octets = ipAddress.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }

        switch octets[0] {
        case 10:
            return true
        case 172:
            return (16...31).contains(octets[1])
        case 192:
            return octets[1] == 168
        default:
            return false
        }
    }
}
