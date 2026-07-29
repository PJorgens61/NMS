import Foundation

/// Enumerates the usable host addresses of an IPv4 subnet, for the SNMP
/// sweep (see `SNMPService`). Deliberately refuses to enumerate anything
/// large: a /24 is 254 hosts, which is a reasonable sweep, but the same
/// code pointed at a /16 would try to produce 65,534 — and at ~2s per
/// unresponsive host that's not a sweep anyone wants to start by accident.
nonisolated struct SubnetCalculator {
    /// Above this, `hostAddresses` returns `nil` rather than a huge array.
    /// 512 comfortably covers /24 (254) and /23 (510) — the sizes where a
    /// sweep is still sane — while ruling out /22 and larger.
    static let maxSweepHosts = 512

    /// All usable host addresses in the subnet containing `ipAddress`,
    /// excluding the network and broadcast addresses (and `ipAddress`
    /// itself — no point probing ourselves). Returns `nil` if the subnet
    /// is larger than `maxSweepHosts`, or if either argument doesn't parse
    /// as IPv4.
    static func hostAddresses(ipAddress: String, subnetMask: String) -> [String]? {
        guard
            let ip = packedIPv4(ipAddress),
            let mask = packedIPv4(subnetMask)
        else { return nil }

        let network = ip & mask
        let broadcast = network | ~mask

        // `&+ 1` / `&- 1` can't overflow here: a /31 or /32 yields an empty
        // or single-address range, caught by the `>=` guard below.
        guard broadcast > network else { return [] }
        let first = network &+ 1
        let last = broadcast &- 1
        guard last >= first else { return [] }

        let count = Int(last - first) + 1
        guard count <= maxSweepHosts else { return nil }

        return (first...last).compactMap { address in
            address == ip ? nil : dottedQuad(address)
        }
    }

    static func packedIPv4(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(octet)
        }
        return result
    }

    /// Whether `address` sits on the same subnet as `ipAddress` under
    /// `subnetMask`. Returns `nil` — deliberately, rather than `false` —
    /// when any input can't be parsed, so a caller deciding whether to
    /// *discard* something can distinguish "definitely elsewhere" from
    /// "can't tell" and refuse to act on the latter.
    static func isOnSameSubnet(_ address: String, as ipAddress: String, subnetMask: String) -> Bool? {
        guard
            let candidate = packedIPv4(address),
            let local = packedIPv4(ipAddress),
            let mask = packedIPv4(subnetMask)
        else { return nil }
        return (candidate & mask) == (local & mask)
    }

    static func dottedQuad(_ address: UInt32) -> String {
        "\((address >> 24) & 0xFF).\((address >> 16) & 0xFF).\((address >> 8) & 0xFF).\(address & 0xFF)"
    }

    /// The CIDR prefix length (e.g. `24` for `255.255.255.0`) — a popcount
    /// of the mask's set bits. Doesn't validate that the mask is a
    /// well-formed contiguous run of 1s followed by 0s (a real subnet mask
    /// always is; a malformed one would just yield a meaningless number,
    /// not a crash).
    static func prefixLength(subnetMask: String) -> Int? {
        packedIPv4(subnetMask)?.nonzeroBitCount
    }
}
