import Testing
import Foundation
@testable import NMS

// Scoped deliberately to logic that is *pure* — no network, no SwiftData
// container, no `@MainActor` view model construction. Everything here
// runs from inputs alone, which is what makes these worth having: they
// re-run in a second, in CI, on someone else's machine, without a real
// network or a real store. The parts of this app that genuinely need a
// live network are covered by `script/scenarios.sh` instead.

// MARK: - SubnetCalculator

@Suite("SubnetCalculator")
struct SubnetCalculatorTests {
    @Test("parses and round-trips dotted quads")
    func packAndUnpack() {
        #expect(SubnetCalculator.packedIPv4("10.0.0.1") == 0x0A000001)
        #expect(SubnetCalculator.packedIPv4("255.255.255.255") == 0xFFFFFFFF)
        #expect(SubnetCalculator.packedIPv4("0.0.0.0") == 0)
        #expect(SubnetCalculator.dottedQuad(0x0A000001) == "10.0.0.1")
        #expect(SubnetCalculator.dottedQuad(0xFFFFFFFF) == "255.255.255.255")
    }

    @Test("rejects malformed addresses rather than guessing")
    func rejectsMalformed() {
        #expect(SubnetCalculator.packedIPv4("10.0.0") == nil)          // too few octets
        #expect(SubnetCalculator.packedIPv4("10.0.0.1.5") == nil)      // too many
        #expect(SubnetCalculator.packedIPv4("10.0.0.256") == nil)      // octet out of range
        #expect(SubnetCalculator.packedIPv4("10.0.0.x") == nil)        // non-numeric
        #expect(SubnetCalculator.packedIPv4("") == nil)
    }

    @Test("prefix length counts mask bits")
    func prefixLength() {
        #expect(SubnetCalculator.prefixLength(subnetMask: "255.255.255.0") == 24)
        #expect(SubnetCalculator.prefixLength(subnetMask: "255.255.254.0") == 23)
        #expect(SubnetCalculator.prefixLength(subnetMask: "255.255.0.0") == 16)
        #expect(SubnetCalculator.prefixLength(subnetMask: "255.255.255.255") == 32)
        #expect(SubnetCalculator.prefixLength(subnetMask: "nonsense") == nil)
    }

    @Test("/24 enumerates 254 hosts minus ourselves, excluding network and broadcast")
    func slash24() throws {
        let hosts = try #require(
            SubnetCalculator.hostAddresses(ipAddress: "10.0.0.5", subnetMask: "255.255.255.0")
        )
        // 254 usable, minus our own address.
        #expect(hosts.count == 253)
        #expect(!hosts.contains("10.0.0.0"))    // network
        #expect(!hosts.contains("10.0.0.255"))  // broadcast
        #expect(!hosts.contains("10.0.0.5"))    // ourselves
        #expect(hosts.contains("10.0.0.1"))
        #expect(hosts.contains("10.0.0.254"))
    }

    /// The guard that stops someone accidentally starting a 65,534-host
    /// sweep at ~2s per silent host.
    @Test("refuses subnets larger than maxSweepHosts")
    func refusesLargeSubnets() {
        // /23 = 510 usable, under the 512 ceiling.
        #expect(SubnetCalculator.hostAddresses(ipAddress: "10.0.0.5", subnetMask: "255.255.254.0") != nil)
        // /22 = 1022 usable, over it.
        #expect(SubnetCalculator.hostAddresses(ipAddress: "10.0.0.5", subnetMask: "255.255.252.0") == nil)
        // /16 = 65,534. The case this guard exists for.
        #expect(SubnetCalculator.hostAddresses(ipAddress: "10.0.0.5", subnetMask: "255.255.0.0") == nil)
    }

    @Test("/30, /31 and /32 edges yield no sweepable hosts beyond ourselves")
    func narrowEdges() throws {
        // /30: 2 usable (.1 and .2), minus ourselves.
        let slash30 = try #require(
            SubnetCalculator.hostAddresses(ipAddress: "10.0.0.1", subnetMask: "255.255.255.252")
        )
        #expect(slash30 == ["10.0.0.2"])

        // /31 and /32 have no usable host range at all — empty, not nil,
        // since that's a definite answer rather than "can't tell".
        #expect(SubnetCalculator.hostAddresses(ipAddress: "10.0.0.1", subnetMask: "255.255.255.254") == [])
        #expect(SubnetCalculator.hostAddresses(ipAddress: "10.0.0.1", subnetMask: "255.255.255.255") == [])
    }

    @Test("top-of-range subnet doesn't overflow")
    func topOfRange() throws {
        let hosts = try #require(
            SubnetCalculator.hostAddresses(ipAddress: "255.255.255.253", subnetMask: "255.255.255.252")
        )
        #expect(hosts == ["255.255.255.254"])
    }

    /// `nil` means "can't tell" and must never be collapsed into `false`
    /// — a caller deciding whether to *hide* a device relies on that
    /// distinction (see `SNMPViewModel.rebuildDeviceList`).
    @Test("same-subnet returns nil, not false, when input can't be parsed")
    func sameSubnetUnknownIsNil() {
        #expect(SubnetCalculator.isOnSameSubnet("10.0.0.9", as: "10.0.0.5", subnetMask: "255.255.255.0") == true)
        #expect(SubnetCalculator.isOnSameSubnet("10.0.1.9", as: "10.0.0.5", subnetMask: "255.255.255.0") == false)
        #expect(SubnetCalculator.isOnSameSubnet("garbage", as: "10.0.0.5", subnetMask: "255.255.255.0") == nil)
        #expect(SubnetCalculator.isOnSameSubnet("10.0.0.9", as: "garbage", subnetMask: "255.255.255.0") == nil)
        #expect(SubnetCalculator.isOnSameSubnet("10.0.0.9", as: "10.0.0.5", subnetMask: "garbage") == nil)
    }
}

// MARK: - IPClassifier

@Suite("IPClassifier")
struct IPClassifierTests {
    @Test("recognizes the three RFC 1918 ranges")
    func privateRanges() {
        #expect(IPClassifier.isRFC1918("10.0.0.1"))
        #expect(IPClassifier.isRFC1918("10.255.255.255"))
        #expect(IPClassifier.isRFC1918("192.168.1.1"))
        #expect(IPClassifier.isRFC1918("172.16.0.1"))
        #expect(IPClassifier.isRFC1918("172.31.255.255"))
    }

    /// The 172.16/12 boundaries are the ones worth pinning — it's the
    /// only RFC 1918 range that isn't a whole leading octet.
    @Test("172.x boundaries are exact")
    func oneSeventyTwoBoundaries() {
        #expect(!IPClassifier.isRFC1918("172.15.255.255"))  // just below
        #expect(IPClassifier.isRFC1918("172.16.0.0"))       // first
        #expect(IPClassifier.isRFC1918("172.31.255.255"))   // last
        #expect(!IPClassifier.isRFC1918("172.32.0.0"))      // just above
    }

    /// CGNAT is *not* RFC 1918. This app treats it as "internet", which
    /// matters for picking the suggested ISP edge hop.
    @Test("CGNAT and other public space are not private")
    func publicSpace() {
        #expect(!IPClassifier.isRFC1918("100.64.0.1"))   // CGNAT, RFC 6598
        #expect(!IPClassifier.isRFC1918("8.8.8.8"))
        #expect(!IPClassifier.isRFC1918("1.1.1.1"))
        #expect(!IPClassifier.isRFC1918("192.169.1.1"))  // near-miss on 192.168
    }

    @Test("link-local (APIPA) detection is exact")
    func linkLocal() {
        #expect(IPClassifier.isLinkLocal("169.254.0.1"))
        #expect(IPClassifier.isLinkLocal("169.254.255.255"))
        #expect(!IPClassifier.isLinkLocal("169.253.0.1"))
        #expect(!IPClassifier.isLinkLocal("169.255.0.1"))
        #expect(!IPClassifier.isLinkLocal("10.0.0.1"))
    }

    @Test("malformed input is not classified as private")
    func malformed() {
        #expect(!IPClassifier.isRFC1918("10.0.0"))
        #expect(!IPClassifier.isRFC1918(""))
        #expect(!IPClassifier.isLinkLocal("169.254"))
    }
}

// MARK: - OverallStatus

@Suite("OverallStatus")
struct OverallStatusTests {
    private func check(_ label: String, success: Bool) -> ConnectivityCheck {
        ConnectivityCheck(label: label, target: "t", success: success, latencyMs: nil, checkedAt: Date())
    }

    @Test("all healthy is normal")
    func normal() {
        let checks = [
            check(OverallStatus.routerLabel, success: true),
            check(OverallStatus.dnsLabel, success: true),
            check("Switch", success: true)
        ]
        #expect(OverallStatus.compute(interfaceIsDown: false, checks: checks) == .normal)
    }

    /// The interface being down outranks everything — nothing past it can
    /// be meaningfully evaluated anyway.
    @Test("interface down overrides everything, even with all checks passing")
    func interfaceDownWins() {
        let checks = [check(OverallStatus.routerLabel, success: true)]
        #expect(OverallStatus.compute(interfaceIsDown: true, checks: checks) == .critical)
    }

    @Test("each critical label failing alone is critical")
    func criticalLabels() {
        for label in OverallStatus.criticalLabels {
            let checks = [
                check(label, success: false),
                check("Switch", success: true)
            ]
            #expect(
                OverallStatus.compute(interfaceIsDown: false, checks: checks) == .critical,
                "\(label) failing should be critical"
            )
        }
    }

    /// A monitored switch/AP going quiet is worth noticing but isn't the
    /// network being broken — that distinction is the whole point of
    /// having a middle tier.
    @Test("a non-critical device failing alone is only marginal")
    func marginal() {
        let checks = [
            check(OverallStatus.routerLabel, success: true),
            check("BrotherLaserPrinter", success: false)
        ]
        #expect(OverallStatus.compute(interfaceIsDown: false, checks: checks) == .marginal)
    }

    @Test("critical outranks marginal when both are failing")
    func criticalOutranksMarginal() {
        let checks = [
            check(OverallStatus.dnsLabel, success: false),
            check("BrotherLaserPrinter", success: false)
        ]
        #expect(OverallStatus.compute(interfaceIsDown: false, checks: checks) == .critical)
    }

    @Test("no checks yet is normal, not a failure")
    func emptyIsNormal() {
        #expect(OverallStatus.compute(interfaceIsDown: false, checks: []) == .normal)
    }
}

// MARK: - Local-interference suppression

/// The riskiest logic in the app to get wrong in the *permissive*
/// direction: a false positive here means a genuine outage is silently
/// never logged. These pin both directions.
@Suite("ConnectivityViewModel.isLikelyLocalPingFailure")
struct LocalInterferenceTests {
    private func check(_ label: String, success: Bool) -> ConnectivityCheck {
        ConnectivityCheck(label: label, target: "t", success: success, latencyMs: nil, checkedAt: Date())
    }

    /// The signature this exists for: every ICMP probe times out while
    /// DNS/HTTP still work, which is a contradiction — traffic reaching a
    /// remote host proves it traversed the very hops reporting
    /// unreachable.
    @Test("all path-critical pings failing while DNS succeeds is local interference")
    func suppressesWhenDNSSurvives() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.publicIPLabel, success: false),
            check(OverallStatus.peRouterLabel, success: false),
            check(OverallStatus.internetLabel, success: false),
            check(OverallStatus.dnsLabel, success: true),
            check(OverallStatus.httpLabel, success: false)
        ]
        #expect(ConnectivityViewModel.isLikelyLocalPingFailure(checks))
    }

    @Test("HTTP surviving is equally sufficient")
    func suppressesWhenHTTPSurvives() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.internetLabel, success: false),
            check(OverallStatus.dnsLabel, success: false),
            check(OverallStatus.httpLabel, success: true)
        ]
        #expect(ConnectivityViewModel.isLikelyLocalPingFailure(checks))
    }

    /// The most important negative case. If DNS and HTTP are *also* down,
    /// this is a real outage and must be reported.
    @Test("a genuine total outage is NOT suppressed")
    func doesNotSuppressRealOutage() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.publicIPLabel, success: false),
            check(OverallStatus.peRouterLabel, success: false),
            check(OverallStatus.internetLabel, success: false),
            check(OverallStatus.dnsLabel, success: false),
            check(OverallStatus.httpLabel, success: false)
        ]
        #expect(!ConnectivityViewModel.isLikelyLocalPingFailure(checks))
    }

    @Test("a single failing ping is not suppressed")
    func doesNotSuppressSingleFailure() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.publicIPLabel, success: true),
            check(OverallStatus.internetLabel, success: true),
            check(OverallStatus.dnsLabel, success: true)
        ]
        #expect(!ConnectivityViewModel.isLikelyLocalPingFailure(checks))
    }

    /// Requires at least two path-critical targets, so a minimal
    /// configuration can't trip suppression on one unlucky timeout.
    @Test("one path-critical target alone is never enough to suppress")
    func requiresTwoPingTargets() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.dnsLabel, success: true)
        ]
        #expect(!ConnectivityViewModel.isLikelyLocalPingFailure(checks))
    }

    /// Infrastructure devices are excluded in both directions — a working
    /// network says nothing about whether a printer is powered on, and a
    /// genuinely-off printer must not block detection.
    @Test("a powered-off infrastructure device neither causes nor blocks suppression")
    func infrastructureIsIgnored() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.publicIPLabel, success: false),
            check(OverallStatus.peRouterLabel, success: false),
            check(OverallStatus.internetLabel, success: false),
            check(OverallStatus.dnsLabel, success: true),
            check("BrotherLaserPrinter", success: false)   // genuinely off
        ]
        #expect(ConnectivityViewModel.isLikelyLocalPingFailure(checks))
    }

    @Test("no checks at all is not suppression")
    func emptyIsNotSuppression() {
        #expect(!ConnectivityViewModel.isLikelyLocalPingFailure([]))
    }
}

// MARK: - SNMP shared-MAC merging

@Suite("SNMPViewModel.mergingSharedMACs")
struct SharedMACMergeTests {
    private func device(_ ip: String, name: String) -> SNMPDevice {
        SNMPDevice(
            ipAddress: ip,
            sysDescr: "descr",
            sysName: name,
            uptimeTicks: 1000,
            community: "public",
            polledAt: Date()
        )
    }

    /// The real case: AP1 answers both its own address and the VRRP
    /// virtual one, and ARP proves they're one interface.
    @Test("two addresses sharing a MAC collapse into one entry")
    func mergesSharedMAC() throws {
        let devices = [device("10.0.0.16", name: "AP1"), device("10.0.0.17", name: "AP1")]
        let macs = [
            "10.0.0.16": "e8:10:98:ca:a9:22",
            "10.0.0.17": "e8:10:98:ca:a9:22"
        ]
        let merged = SNMPViewModel.mergingSharedMACs(devices, macByAddress: macs)
        #expect(merged.count == 1)
        let primary = try #require(merged.first)
        // Lowest address becomes primary — a deterministic tie-break, not
        // a claim about which is "real".
        #expect(primary.ipAddress == "10.0.0.16")
        #expect(primary.aliasAddresses == ["10.0.0.17"])
        // Neither address is discarded.
        #expect(primary.allAddresses.sorted() == ["10.0.0.16", "10.0.0.17"])
    }

    @Test("merge result is independent of input order")
    func orderIndependent() throws {
        let macs = [
            "10.0.0.16": "e8:10:98:ca:a9:22",
            "10.0.0.17": "e8:10:98:ca:a9:22"
        ]
        let forward = SNMPViewModel.mergingSharedMACs(
            [device("10.0.0.16", name: "AP1"), device("10.0.0.17", name: "AP1")],
            macByAddress: macs
        )
        let reversed = SNMPViewModel.mergingSharedMACs(
            [device("10.0.0.17", name: "AP1"), device("10.0.0.16", name: "AP1")],
            macByAddress: macs
        )
        #expect(forward.first?.ipAddress == reversed.first?.ipAddress)
        #expect(forward.first?.aliasAddresses == reversed.first?.aliasAddresses)
    }

    @Test("three addresses on one MAC collapse to one primary plus two aliases")
    func threeOnOneMAC() throws {
        let devices = [
            device("10.0.0.16", name: "AP1"),
            device("10.0.0.17", name: "AP1"),
            device("10.0.0.19", name: "AP1")
        ]
        let mac = "e8:10:98:ca:a9:22"
        let merged = SNMPViewModel.mergingSharedMACs(
            devices,
            macByAddress: ["10.0.0.16": mac, "10.0.0.17": mac, "10.0.0.19": mac]
        )
        #expect(merged.count == 1)
        #expect(merged.first?.ipAddress == "10.0.0.16")
        #expect(merged.first?.aliasAddresses == ["10.0.0.17", "10.0.0.19"])
    }

    /// A MAC *match* proves one device; a MAC *mismatch* proves nothing —
    /// but distinct MACs must still never be merged.
    @Test("distinct MACs are never merged")
    func distinctMACsStaySeparate() {
        let devices = [device("10.0.0.16", name: "AP1"), device("10.0.0.18", name: "AP2")]
        let merged = SNMPViewModel.mergingSharedMACs(
            devices,
            macByAddress: [
                "10.0.0.16": "e8:10:98:ca:a9:22",
                "10.0.0.18": "e8:10:98:ca:9f:66"
            ]
        )
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.aliasAddresses.isEmpty })
    }

    /// The launch-time case: ARP hasn't populated yet. Devices must pass
    /// through untouched rather than being guessed at or dropped.
    @Test("with no ARP data at all, every device passes through unmerged")
    func noARPDataIsPassthrough() {
        let devices = [device("10.0.0.16", name: "AP1"), device("10.0.0.17", name: "AP1")]
        let merged = SNMPViewModel.mergingSharedMACs(devices, macByAddress: [:])
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.aliasAddresses.isEmpty })
    }

    @Test("a device missing from ARP is kept alongside merged ones")
    func partialARPData() {
        let devices = [
            device("10.0.0.16", name: "AP1"),
            device("10.0.0.17", name: "AP1"),
            device("10.0.0.99", name: "Unknown")   // no ARP entry
        ]
        let mac = "e8:10:98:ca:a9:22"
        let merged = SNMPViewModel.mergingSharedMACs(
            devices,
            macByAddress: ["10.0.0.16": mac, "10.0.0.17": mac]
        )
        #expect(merged.count == 2)
        #expect(merged.contains { $0.ipAddress == "10.0.0.99" })
    }
}

// MARK: - StoreSizeService

@Suite("StoreSizeService")
struct StoreSizeServiceTests {
    /// WAL-mode SQLite keeps recent writes in a `-wal` sidecar and an
    /// `-shm` index. Reporting only the base file understated real usage
    /// by more than half on the real store, so the sum is the point.
    @Test("sums the base store plus its WAL and shm sidecars")
    func sumsSidecars() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nms-store-size-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = directory.appendingPathComponent("test.store")
        try Data(count: 1000).write(to: store)
        try Data(count: 2000).write(to: URL(fileURLWithPath: store.path + "-wal"))
        try Data(count: 500).write(to: URL(fileURLWithPath: store.path + "-shm"))

        #expect(StoreSizeService.totalBytes(at: store) == 3500)
    }

    @Test("base file alone is reported when no sidecars exist")
    func baseFileAlone() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nms-store-size-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = directory.appendingPathComponent("test.store")
        try Data(count: 1234).write(to: store)

        #expect(StoreSizeService.totalBytes(at: store) == 1234)
    }

    /// `nil`, not `0` — absence and zero mean different things, and the
    /// footer relies on that to show nothing rather than "0 bytes".
    @Test("a missing store reports nil rather than zero")
    func missingStoreIsNil() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-not-there-\(UUID().uuidString).store")
        #expect(StoreSizeService.totalBytes(at: missing) == nil)
        #expect(StoreSizeService.formattedSize(at: missing) == nil)
    }
}

// MARK: - Small value-type formatting

@Suite("Value-type formatting")
struct FormattingTests {
    @Test("SNMP uptime renders coarsely, largest unit first")
    func uptimeDescription() {
        // uptimeTicks are hundredths of a second.
        let twoDays = SNMPDevice(
            ipAddress: "10.0.0.1", sysDescr: "d", sysName: "n",
            uptimeTicks: 2 * 86_400 * 100, community: "public", polledAt: Date()
        )
        #expect(twoDays.uptimeDescription == "up 2d 0h")

        let threeHours = SNMPDevice(
            ipAddress: "10.0.0.1", sysDescr: "d", sysName: "n",
            uptimeTicks: 3 * 3600 * 100, community: "public", polledAt: Date()
        )
        #expect(threeHours.uptimeDescription == "up 3h 0m")

        let fiveMinutes = SNMPDevice(
            ipAddress: "10.0.0.1", sysDescr: "d", sysName: "n",
            uptimeTicks: 5 * 60 * 100, community: "public", polledAt: Date()
        )
        #expect(fiveMinutes.uptimeDescription == "up 5m")
    }

    /// Falls back to the address when a device reports no `sysName`, so a
    /// row is never blank.
    @Test("display name falls back to the address")
    func displayNameFallback() {
        let named = SNMPDevice(
            ipAddress: "10.0.0.1", sysDescr: "d", sysName: "router",
            uptimeTicks: 0, community: "public", polledAt: Date()
        )
        #expect(named.displayName == "router")

        let unnamed = SNMPDevice(
            ipAddress: "10.0.0.1", sysDescr: "d", sysName: nil,
            uptimeTicks: 0, community: "public", polledAt: Date()
        )
        #expect(unnamed.displayName == "10.0.0.1")

        let blank = SNMPDevice(
            ipAddress: "10.0.0.1", sysDescr: "d", sysName: "",
            uptimeTicks: 0, community: "public", polledAt: Date()
        )
        #expect(blank.displayName == "10.0.0.1")
    }

    @Test("DHCP durations render in hours or minutes")
    func dhcpDurationText() {
        #expect(DHCPLeaseInfo.durationText(86_400) == "24h")
        #expect(DHCPLeaseInfo.durationText(43_200) == "12h")
        #expect(DHCPLeaseInfo.durationText(3600) == "1h")
        #expect(DHCPLeaseInfo.durationText(1800) == "30m")
        #expect(DHCPLeaseInfo.durationText(60) == "1m")
    }
}
