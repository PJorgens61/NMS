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

    /// Carrier-grade NAT range (RFC 6598), 100.64.0.0/10 — reserved
    /// specifically for an ISP's own internal NAT infrastructure, so it
    /// can't collide with a customer's RFC 1918 LAN the way reusing
    /// 10.0.0.0/8 for the same purpose would. An address in this range
    /// appearing as an actual routed traceroute hop is unambiguous
    /// evidence of CGNAT: nothing legitimately routes this block on the
    /// public internet. See `TracerouteViewModel.leadingNonInternetHopCount`.
    ///
    /// Not the only way an ISP does this in practice, though — confirmed
    /// against a real trace (Comcast) using plain 10.0.0.0/8 for the same
    /// purpose instead, which `isRFC1918` alone already classifies
    /// correctly as non-internet. This method exists for the *specific,
    /// confident* claim ("this is CGNAT") that only the reserved range
    /// can support; the general "extra NAT layer" detection doesn't
    /// depend on it.
    static func isCGNAT(_ ipAddress: String) -> Bool {
        let octets = ipAddress.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// Self-assigned/link-local range (RFC 3927 APIPA), 169.254.0.0/16.
    /// macOS falls back to an address in this range when DHCP genuinely
    /// fails — checkable with zero network calls, just the IP already on
    /// hand.
    static func isLinkLocal(_ ipAddress: String) -> Bool {
        let octets = ipAddress.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 169 && octets[1] == 254
    }
}
