import Testing
import Foundation
import SwiftData
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
        // /22 = 1022 usable, under the 1024 ceiling.
        #expect(SubnetCalculator.hostAddresses(ipAddress: "10.0.0.5", subnetMask: "255.255.252.0") != nil)
        // /21 = 2046 usable, over it.
        #expect(SubnetCalculator.hostAddresses(ipAddress: "10.0.0.5", subnetMask: "255.255.248.0") == nil)
        // /16 = 65,534. The case this guard exists for.
        #expect(SubnetCalculator.hostAddresses(ipAddress: "10.0.0.5", subnetMask: "255.255.0.0") == nil)
    }

    @Test("usableHostCount has no size cap, unlike hostAddresses")
    func usableHostCountUncapped() {
        // /21 = 2046 usable — hostAddresses refuses it, but the count itself
        // is still knowable, e.g. to report why it was refused.
        #expect(SubnetCalculator.usableHostCount(ipAddress: "10.0.0.5", subnetMask: "255.255.248.0") == 2046)
        // /8 = 16,777,214. The real-world case this guard exists for.
        #expect(SubnetCalculator.usableHostCount(ipAddress: "10.0.0.5", subnetMask: "255.0.0.0") == 16_777_214)
        #expect(SubnetCalculator.usableHostCount(ipAddress: "not-an-ip", subnetMask: "255.0.0.0") == nil)
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

// MARK: - UntrustedText

@Suite("UntrustedText")
struct UntrustedTextTests {
    @Test("leaves a short value untouched")
    func shortValueUnchanged() {
        #expect(UntrustedText.capped("Aruba AP-535, ArubaOS 8.10") == "Aruba AP-535, ArubaOS 8.10")
    }

    @Test("truncates a value over the cap")
    func truncatesOverLength() {
        let oversized = String(repeating: "a", count: UntrustedText.maxLength + 500)
        let capped = UntrustedText.capped(oversized)
        #expect(capped.count == UntrustedText.maxLength)
        #expect(capped == String(repeating: "a", count: UntrustedText.maxLength))
    }

    @Test("a value exactly at the cap is untouched")
    func exactLengthUnchanged() {
        let exact = String(repeating: "a", count: UntrustedText.maxLength)
        #expect(UntrustedText.capped(exact) == exact)
    }

    @Test("a custom cap overrides the default")
    func customCap() {
        #expect(UntrustedText.capped("hello world", maxLength: 5) == "hello")
    }
}

// MARK: - EthernetLinkService

@Suite("EthernetLinkService.parse")
struct EthernetLinkServiceTests {
    @Test("Gigabit Ethernet, full duplex — this Mac's own real connection")
    func gigabitFullDuplex() {
        let info = EthernetLinkService.parse("1000baseT <full-duplex flow-control>")
        #expect(info.speedMbps == 1000)
        #expect(info.duplex == "Full Duplex")
    }

    @Test("100baseTX half duplex")
    func fastEthernetHalfDuplex() {
        let info = EthernetLinkService.parse("100baseTX <half-duplex>")
        #expect(info.speedMbps == 100)
        #expect(info.duplex == "Half Duplex")
    }

    @Test("10baseT/UTP parses the slash-qualified base token correctly")
    func tenBaseTSlashVariant() {
        let info = EthernetLinkService.parse("10baseT/UTP <half-duplex>")
        #expect(info.speedMbps == 10)
    }

    @Test("10Gbase-T's G suffix means thousands, not units")
    func tenGigabitEthernet() {
        let info = EthernetLinkService.parse("10Gbase-T <full-duplex>")
        #expect(info.speedMbps == 10000)
    }

    @Test("no link reports nil for both fields")
    func noLink() {
        let info = EthernetLinkService.parse("none")
        #expect(info.speedMbps == nil)
        #expect(info.duplex == nil)
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

    /// CGNAT is *not* RFC 1918 — that's `isCGNAT`'s own, separate range.
    /// `isRFC1918` alone correctly says "not private" for it; it's
    /// `TracerouteHop.isLocal` that combines both checks so a CGNAT hop
    /// still isn't mistaken for "the internet" when picking the
    /// suggested ISP edge hop — see the `TracerouteHop` suite below.
    @Test("CGNAT and other public space are not RFC 1918")
    func publicSpace() {
        #expect(!IPClassifier.isRFC1918("100.64.0.1"))   // CGNAT, RFC 6598
        #expect(!IPClassifier.isRFC1918("8.8.8.8"))
        #expect(!IPClassifier.isRFC1918("1.1.1.1"))
        #expect(!IPClassifier.isRFC1918("192.169.1.1"))  // near-miss on 192.168
    }

    @Test("CGNAT range boundaries are exact")
    func cgnatBoundaries() {
        #expect(!IPClassifier.isCGNAT("100.63.255.255"))  // just below
        #expect(IPClassifier.isCGNAT("100.64.0.0"))        // first
        #expect(IPClassifier.isCGNAT("100.100.1.1"))       // mid-range
        #expect(IPClassifier.isCGNAT("100.127.255.255"))   // last
        #expect(!IPClassifier.isCGNAT("100.128.0.0"))       // just above
        #expect(!IPClassifier.isCGNAT("10.1.10.1"))         // real trace: RFC 1918, not CGNAT-range
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

@Suite("WiFiStressTestAggregator")
struct WiFiStressTestAggregatorTests {
    @Test("all packets answered — zero loss, exact min/avg/max, population stddev")
    func allAnswered() {
        let stats = WiFiStressTestAggregator.aggregate(packetsSent: 3, rttsMs: [1.0, 2.0, 3.0], cpuSamples: [], duration: 1.0)
        #expect(stats.packetLossPercent == 0)
        #expect(stats.minRTTMs == 1.0)
        #expect(stats.maxRTTMs == 3.0)
        #expect(stats.avgRTTMs == 2.0)
        // Population stddev of [1,2,3]: variance = ((1-2)^2 + (2-2)^2 + (3-2)^2) / 3 = 2/3
        #expect(abs(stats.stddevRTTMs! - (2.0 / 3.0).squareRoot()) < 0.0001)
    }

    @Test("partial loss — packetsSent exceeds rtts.count")
    func partialLoss() {
        let stats = WiFiStressTestAggregator.aggregate(packetsSent: 10, rttsMs: Array(repeating: 5.0, count: 7), cpuSamples: [], duration: 1.0)
        #expect(stats.packetLossPercent == 30)
        #expect(stats.packetsReceived == 7)
    }

    @Test("total loss — empty rtts, every RTT field nil")
    func totalLoss() {
        let stats = WiFiStressTestAggregator.aggregate(packetsSent: 5, rttsMs: [], cpuSamples: [], duration: 1.0)
        #expect(stats.packetLossPercent == 100)
        #expect(stats.minRTTMs == nil)
        #expect(stats.avgRTTMs == nil)
        #expect(stats.maxRTTMs == nil)
        #expect(stats.stddevRTTMs == nil)
    }

    @Test("zero packets sent doesn't divide by zero")
    func zeroSent() {
        let stats = WiFiStressTestAggregator.aggregate(packetsSent: 0, rttsMs: [], cpuSamples: [], duration: 1.0)
        #expect(stats.packetLossPercent == 0)
    }

    @Test("single sample has zero stddev")
    func singleSample() {
        let stats = WiFiStressTestAggregator.aggregate(packetsSent: 1, rttsMs: [4.2], cpuSamples: [], duration: 1.0)
        #expect(stats.stddevRTTMs == 0)
    }

    /// Pins the deliberate choice of population stddev (÷N), matching BSD
    /// `ping`'s own "round-trip min/avg/max/stddev" summary line, not
    /// sample stddev (÷N-1) — the two clearly differ for this input.
    @Test("stddev is population, not sample")
    func populationNotSample() {
        let stats = WiFiStressTestAggregator.aggregate(packetsSent: 4, rttsMs: [1.0, 2.0, 3.0, 4.0], cpuSamples: [], duration: 1.0)
        #expect(abs(stats.stddevRTTMs! - 1.1180) < 0.001)   // population ≈ 1.118
        #expect(abs(stats.stddevRTTMs! - 1.2910) > 0.001)   // sample ≈ 1.291 — must not match
    }

    @Test("empty CPU samples yield nil, not zero")
    func emptyCPUSamples() {
        let stats = WiFiStressTestAggregator.aggregate(packetsSent: 1, rttsMs: [1.0], cpuSamples: [], duration: 1.0)
        #expect(stats.peakCPUPercent == nil)
        #expect(stats.avgCPUPercent == nil)
    }

    @Test("CPU peak and average are computed correctly")
    func cpuPeakAndAverage() {
        let stats = WiFiStressTestAggregator.aggregate(packetsSent: 1, rttsMs: [1.0], cpuSamples: [10, 50, 30], duration: 1.0)
        #expect(stats.peakCPUPercent == 50)
        #expect(stats.avgCPUPercent == 30)
    }

    @Test("packet rate and bandwidth are derived from packetsSent and duration, not received count")
    func rateAndBandwidth() {
        // 1000 attempted over 2s = 500 pkt/s; at 1500 on-wire bytes/packet
        // that's 500 * 1500 * 8 / 1_000_000 = 6 Mbps -- using packetsSent
        // (2 lost) rather than packetsReceived, since this figure answers
        // "how hard did we drive the link," not "how much arrived."
        let stats = WiFiStressTestAggregator.aggregate(packetsSent: 1000, rttsMs: Array(repeating: 2.0, count: 998), cpuSamples: [], duration: 2.0)
        #expect(stats.packetsPerSecond == 500)
        #expect(abs(stats.megabitsPerSecond - 6.0) < 0.0001)
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

@Suite("ConnectivityViewModel.hasUnhealthyCriticalCheck")
struct CadenceHealthTests {
    private func check(_ label: String, success: Bool) -> ConnectivityCheck {
        ConnectivityCheck(label: label, target: "t", success: success, latencyMs: nil, checkedAt: Date())
    }

    /// The exact regression this exists for. A real switch reboot: at
    /// 18:24:11, DNS and HTTP had genuinely recovered while
    /// Router/Internet/ISP Edge/Public IP were still genuinely down —
    /// this is the identical check pattern `LocalInterferenceTests
    /// .suppressesWhenDNSSurvives` pins as triggering
    /// `isLikelyLocalPingFailure`. The bug: `anyUnhealthy` used to be
    /// gated by that same heuristic (`!localInterference && ...`), so
    /// this exact round forced cadence back to 30s despite four checks
    /// still being genuinely broken — delaying their real recovery
    /// detection by up to 30s instead of the 5s the fast cadence should
    /// have allowed. Pinned here as its own function, independent of
    /// `isLikelyLocalPingFailure`, specifically so the two can never be
    /// silently re-coupled again.
    @Test("still unhealthy even when isLikelyLocalPingFailure would suppress the same round's events")
    func cadenceStaysHonestDuringGenuineOutageWithAsymmetricRecovery() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.publicIPLabel, success: false),
            check(OverallStatus.peRouterLabel, success: false),
            check(OverallStatus.internetLabel, success: false),
            check(OverallStatus.dnsLabel, success: true),
            check(OverallStatus.httpLabel, success: true)
        ]
        // Same input the local-interference heuristic reads as
        // "suppress" — the whole point is that this function doesn't
        // ask that question at all.
        #expect(ConnectivityViewModel.isLikelyLocalPingFailure(checks))
        #expect(ConnectivityViewModel.hasUnhealthyCriticalCheck(checks, infrastructureLabels: []))
    }

    @Test("a fully healthy round is not unhealthy")
    func healthyRoundIsHealthy() {
        let checks = [
            check(OverallStatus.routerLabel, success: true),
            check(OverallStatus.internetLabel, success: true),
            check(OverallStatus.dnsLabel, success: true),
            check(OverallStatus.httpLabel, success: true)
        ]
        #expect(!ConnectivityViewModel.hasUnhealthyCriticalCheck(checks, infrastructureLabels: []))
    }

    @Test("a failing SNMP infrastructure device counts as unhealthy")
    func infrastructureFailureCounts() {
        let checks = [
            check(OverallStatus.routerLabel, success: true),
            check("Switch", success: false)
        ]
        #expect(!ConnectivityViewModel.hasUnhealthyCriticalCheck(checks, infrastructureLabels: []))
        #expect(ConnectivityViewModel.hasUnhealthyCriticalCheck(checks, infrastructureLabels: ["Switch"]))
    }

    @Test("a failing target not in either set doesn't count")
    func unrelatedTargetDoesNotCount() {
        let checks = [check("SomeRandomLANHost", success: false)]
        #expect(!ConnectivityViewModel.hasUnhealthyCriticalCheck(checks, infrastructureLabels: []))
    }

    @Test("no checks at all is not unhealthy")
    func emptyIsHealthy() {
        #expect(!ConnectivityViewModel.hasUnhealthyCriticalCheck([], infrastructureLabels: []))
    }
}

@Suite("ConnectivityViewModel.isWithinTopologyChangeWindow")
struct TopologyChangeWindowTests {
    private let now = Date()

    @Test("just inside the window counts")
    func justInside() {
        #expect(ConnectivityViewModel.isWithinTopologyChangeWindow(
            now: now, lastChangeAt: now.addingTimeInterval(-29), window: 30
        ))
    }

    /// The boundary itself is exclusive — pinned so the `<` in the
    /// implementation isn't quietly flipped to `<=` later.
    @Test("exactly the window is NOT inside")
    func exactlyOutside() {
        #expect(!ConnectivityViewModel.isWithinTopologyChangeWindow(
            now: now, lastChangeAt: now.addingTimeInterval(-30), window: 30
        ))
    }

    @Test("no lastChangeAt at all is never within the window")
    func neverChanged() {
        #expect(!ConnectivityViewModel.isWithinTopologyChangeWindow(now: now, lastChangeAt: nil, window: 30))
    }
}

@Suite("ConnectivityViewModel.shouldSuppressAsLocalInterference")
struct SuppressionGraceperiodTests {
    private func check(_ label: String, success: Bool) -> ConnectivityCheck {
        ConnectivityCheck(label: label, target: "t", success: success, latencyMs: nil, checkedAt: Date())
    }
    private let now = Date()

    /// The exact regression this exists for. A real Wi-Fi network switch
    /// (Thistle → ThistleGuest): one round showed DNS still resolving
    /// (a leftover/faster lookup) while Router/Internet/ISP Edge/Public
    /// IP — pinging the *old* network's addresses — genuinely failed.
    /// That's the identical pattern `isLikelyLocalPingFailure` reads as
    /// CPU-starved fake pings, and it suppressed six real
    /// "became unreachable" events. `lastChangeAt` a moment ago is the
    /// evidence that tells the two apart.
    @Test("a real topology change moments ago overrides the interference heuristic")
    func recentChangeOverridesSuppression() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.internetLabel, success: false),
            check(OverallStatus.peRouterLabel, success: false),
            check(OverallStatus.publicIPLabel, success: false),
            check(OverallStatus.dnsLabel, success: true)
        ]
        // Confirms the setup actually matches the heuristic's trigger —
        // otherwise this test would pass for the wrong reason.
        #expect(ConnectivityViewModel.isLikelyLocalPingFailure(checks))
        #expect(!ConnectivityViewModel.shouldSuppressAsLocalInterference(
            checks, now: now, lastChangeAt: now.addingTimeInterval(-1), gracePeriod: 30
        ))
    }

    @Test("the same pattern with no recent change still suppresses, unchanged from before")
    func noRecentChangeStillSuppresses() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.internetLabel, success: false),
            check(OverallStatus.peRouterLabel, success: false),
            check(OverallStatus.publicIPLabel, success: false),
            check(OverallStatus.dnsLabel, success: true)
        ]
        #expect(ConnectivityViewModel.shouldSuppressAsLocalInterference(
            checks, now: now, lastChangeAt: nil, gracePeriod: 30
        ))
        #expect(ConnectivityViewModel.shouldSuppressAsLocalInterference(
            checks, now: now, lastChangeAt: now.addingTimeInterval(-45), gracePeriod: 30
        ))
    }

    @Test("a real total outage is never suppressed, recent change or not")
    func realOutageNeverSuppressed() {
        let checks = [
            check(OverallStatus.routerLabel, success: false),
            check(OverallStatus.internetLabel, success: false),
            check(OverallStatus.dnsLabel, success: false),
            check(OverallStatus.httpLabel, success: false)
        ]
        #expect(!ConnectivityViewModel.shouldSuppressAsLocalInterference(
            checks, now: now, lastChangeAt: now.addingTimeInterval(-1), gracePeriod: 30
        ))
    }
}

@Suite("ConnectivityViewModel.wasFailingPreviously")
struct WasFailingPreviouslyTests {
    private func check(_ label: String, success: Bool) -> ConnectivityCheck {
        ConnectivityCheck(label: label, target: "t", success: success, latencyMs: nil, checkedAt: Date())
    }

    @Test("a matching prior success means it wasn't failing")
    func priorSuccess() {
        let previous = [check("Router", success: true)]
        #expect(ConnectivityViewModel.wasFailingPreviously("Router", previous: previous) == false)
    }

    @Test("a matching prior failure means it was failing")
    func priorFailure() {
        let previous = [check("Router", success: false)]
        #expect(ConnectivityViewModel.wasFailingPreviously("Router", previous: previous) == true)
    }

    /// The exact regression this exists for. A printer unreachable on a
    /// guest network the entire time — but absent from one round's target
    /// list (the `runChecks()` "no interface" fallback omits
    /// infrastructure entirely) reappeared afterward and, under the old
    /// `?? false` default, read as *freshly* broken. `nil` here is what
    /// lets `logTransitions` skip a label with no real prior verdict
    /// instead of assuming it had been fine.
    @Test("a label absent from a non-empty previous round is unknown, not assumed healthy")
    func absentFromNonEmptyPreviousIsUnknown() {
        let previous = [check("DNS", success: false), check("Internet", success: false)]
        #expect(ConnectivityViewModel.wasFailingPreviously("brotherlaserprinter", previous: previous) == nil)
    }

    /// The one case that still defaults to `false` rather than `nil` —
    /// nothing has ever been checked yet (app launch), and a bad first
    /// observation should still be reported, not silently absorbed as
    /// the baseline.
    @Test("an empty previous round (nothing checked yet) defaults to not-failing")
    func emptyPreviousDefaultsToNotFailing() {
        #expect(ConnectivityViewModel.wasFailingPreviously("Router", previous: []) == false)
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

    /// Pins the behaviour behind a real crash. Duplicate
    /// `SNMPDeviceRecord` rows for one address (see
    /// `SnapshotStore.adoptUntaggedRecords`, where they came from) arrive
    /// here as two devices with the *same* `ipAddress`. When ARP knows the
    /// address they collapse by MAC — but when it doesn't, both fall into
    /// the `unknownMAC` bucket and **pass straight through as duplicates**.
    /// That output then reached `SNMPViewModel.apply`'s dictionary build,
    /// which used `Dictionary(uniqueKeysWithValues:)` and trapped, killing
    /// the app with a SIGILL.
    ///
    /// The assertion is deliberately that duplicates *survive* rather than
    /// that this function dedupes them: this layer merges by MAC, and
    /// inventing an address-based dedupe here would paper over a corrupt
    /// store instead of fixing it. The invariant belongs upstream (the
    /// store must not hold duplicate rows) and the tolerance downstream
    /// (`apply` now uses `uniquingKeysWith:`). This test exists so that
    /// contract stays explicit — if someone later makes this dedupe, the
    /// downstream tolerance stops being load-bearing and this should be
    /// reconsidered rather than silently passing.
    @Test("duplicate addresses with no ARP entry pass through, and must not trap downstream")
    func duplicateAddressesWithoutMACPassThrough() {
        let duplicated = [device("10.0.0.16", name: "AP1"), device("10.0.0.16", name: "AP1")]
        let merged = SNMPViewModel.mergingSharedMACs(duplicated, macByAddress: [:])
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.ipAddress == "10.0.0.16" })

        // The downstream shape that used to crash: same keying `apply`
        // does. `uniqueKeysWithValues:` traps here; this must not.
        let byAddress = Dictionary(merged.map { ($0.ipAddress, $0) }) { older, newer in
            older.polledAt >= newer.polledAt ? older : newer
        }
        #expect(byAddress.count == 1)
    }

    /// The same duplicate rows, but with ARP data present — they collapse
    /// by MAC, which is why this crash was intermittent rather than
    /// constant. Also pins the self-alias artifact the corrupt store
    /// produced: `.16` listing its own address as an alias.
    @Test("duplicate addresses sharing a MAC collapse, aliasing the address to itself")
    func duplicateAddressesWithMACCollapse() throws {
        let duplicated = [device("10.0.0.16", name: "AP1"), device("10.0.0.16", name: "AP1")]
        let merged = SNMPViewModel.mergingSharedMACs(
            duplicated,
            macByAddress: ["10.0.0.16": "e8:10:98:ca:a9:22"]
        )
        #expect(merged.count == 1)
        let primary = try #require(merged.first)
        #expect(primary.ipAddress == "10.0.0.16")
        // Exactly the tell seen in the real log before the fix:
        // aliasAddresses containing the primary's own address.
        #expect(primary.aliasAddresses == ["10.0.0.16"])
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

// MARK: - TracerouteHop / TracerouteViewModel

@Suite("TracerouteHop.isLocal")
struct TracerouteHopTests {
    private func hop(_ n: Int, _ address: String?) -> TracerouteHop {
        TracerouteHop(hopNumber: n, address: address, hostname: nil, roundTripMs: address == nil ? nil : 10)
    }

    @Test("a non-responding hop classifies as nil, not local or internet")
    func nonResponding() {
        #expect(hop(1, nil).isLocal == nil)
    }

    @Test("RFC 1918 and CGNAT both count as local; a real address doesn't")
    func classification() {
        #expect(hop(1, "192.168.1.1").isLocal == true)
        #expect(hop(1, "10.1.10.1").isLocal == true)
        #expect(hop(1, "100.64.0.1").isLocal == true)      // the fix: was wrongly `false` before
        #expect(hop(1, "96.120.90.213").isLocal == false)
    }
}

@Suite("TracerouteViewModel.leadingNonInternetHopCount")
struct NATLayerDetectionTests {
    private func hop(_ n: Int, _ address: String?) -> TracerouteHop {
        TracerouteHop(hopNumber: n, address: address, hostname: nil, roundTripMs: address == nil ? nil : 10)
    }

    /// The real trace this feature was built from — a Comcast connection
    /// at a friend's house. Two non-internet hops (the customer's own
    /// router, then an unresolvable 10.x address) before the first real
    /// public one, using plain RFC 1918 space rather than the compliant
    /// CGNAT range — which is exactly why the detection counts *any*
    /// leading non-internet hop rather than only checking `isCGNAT`.
    @Test("Martha's real Comcast trace: double-NAT, not compliant CGNAT")
    func realTraceFromMarthas() {
        let hops = [
            hop(1, "192.168.1.1"),
            hop(2, "10.1.10.1"),
            hop(3, "96.120.90.213"),
            hop(4, "96.216.8.109")
        ]
        #expect(TracerouteViewModel.leadingNonInternetHopCount(hops) == 2)
        #expect(!TracerouteViewModel.includesConfirmedCGNAT(hops))
    }

    @Test("a normal single-NAT home network counts exactly one")
    func normalHomeNetwork() {
        let hops = [
            hop(1, "192.168.1.1"),
            hop(2, "75.101.33.52"),
            hop(3, "157.131.209.34")
        ]
        #expect(TracerouteViewModel.leadingNonInternetHopCount(hops) == 1)
    }

    @Test("a compliant CGNAT hop is both counted and confidently identified")
    func compliantCGNAT() {
        let hops = [
            hop(1, "192.168.1.1"),
            hop(2, "100.64.5.1"),
            hop(3, "8.8.8.8")
        ]
        #expect(TracerouteViewModel.leadingNonInternetHopCount(hops) == 2)
        #expect(TracerouteViewModel.includesConfirmedCGNAT(hops))
    }

    /// The accepted limitation, pinned: a non-responding hop stops the
    /// count rather than being skipped over, so a real double-NAT path
    /// can undercount if the *first* hop happens to time out. Documented
    /// in `leadingNonInternetHopCount`'s own comment as the deliberate
    /// "can't tell, don't act" tradeoff — this test exists so a future
    /// change to "skip nils instead" is a conscious choice, not an
    /// accident.
    @Test("a non-responding leading hop stops the count rather than being skipped")
    func nonRespondingHopStopsCounting() {
        let hops = [
            hop(1, nil),
            hop(2, "10.1.10.1"),
            hop(3, "96.120.90.213")
        ]
        #expect(TracerouteViewModel.leadingNonInternetHopCount(hops) == 0)
    }

    @Test("an empty or fully-unresponsive trace counts zero, not a crash")
    func emptyTrace() {
        #expect(TracerouteViewModel.leadingNonInternetHopCount([]) == 0)
        #expect(TracerouteViewModel.leadingNonInternetHopCount([hop(1, nil), hop(2, nil)]) == 0)
    }

    @Test("hop order in the array doesn't matter, only hopNumber order")
    func outOfOrderInput() {
        let hops = [
            hop(3, "96.120.90.213"),
            hop(1, "192.168.1.1"),
            hop(2, "10.1.10.1")
        ]
        #expect(TracerouteViewModel.leadingNonInternetHopCount(hops) == 2)
    }
}

// MARK: - SectionLayout

/// Pins "declared, present, and not accidentally reverted to zero" for
/// every fixed-height scroll box — a plainer check than this suite used
/// to run back when there were two surfaces (a popover and a window)
/// competing for a tight height budget. NMS is a single-window app now
/// (see `NMSApp`), so there's no budget to guard, just a sanity check
/// that every declared box still has a real, positive height.
@Suite("SectionLayout")
struct SectionLayoutTests {
    @Test("every declared section has a positive box height")
    func everySectionHasAPositiveHeight() {
        for section in SectionLayout.allCases {
            #expect(section.boxHeight > 0, "\(section.rawValue) should declare a positive box height")
        }
    }
}

// MARK: - SNMP Devices sysDescr splitting

/// See `BUGS.md`'s "SNMP device sysDescr truncated to one line live"
/// entry for why this exists instead of a single wrapping `Text`: every
/// attempt to make `sysDescr` auto-wrap inside `NoBounceScrollView`
/// reliably clipped this list's first row instead. Splitting into up to
/// two fixed, single-line `Text`s sidesteps that entirely — these tests
/// pin the splitting logic itself, independent of the AppKit rendering
/// issue that motivated it.
@Suite("ContentView.sysDescrLines")
struct SysDescrLinesTests {
    @Test("short strings come back unsplit")
    func shortStringUnsplit() {
        #expect(ContentView.sysDescrLines("Alta Route10 1.5b") == ["Alta Route10 1.5b"])
    }

    @Test("a real long sysDescr splits near its midpoint, at a space")
    func longStringSplitsAtNearestSpace() {
        let sysDescr = "GC108P 8-Port Gigabit Ethernet PoE+ Insight Managed Smart Cloud Switch with 8 PoE+ Ports (64W), Software Version 1.0.8.9, Boot Version 1.0.0.3"
        let lines = ContentView.sysDescrLines(sysDescr)
        #expect(lines.count == 2)
        // Neither half starts or ends with whitespace, and rejoining
        // with a single space reconstructs the original — the split
        // point itself is a space that got consumed, not text that was
        // dropped.
        for line in lines {
            #expect(line == line.trimmingCharacters(in: .whitespaces))
        }
        #expect(lines.joined(separator: " ") == sysDescr)
    }

    @Test("a string with no space near the midpoint comes back unsplit rather than mis-splitting")
    func noNearbySpaceStaysUnsplit() {
        let noSpaces = String(repeating: "x", count: 100)
        #expect(ContentView.sysDescrLines(noSpaces) == [noSpaces])
    }
}

// MARK: - KnownNetwork fingerprint derivation

/// `routerMAC` and `subnet` are derived from `fingerprint` rather than
/// stored beside it — the change that let the store open again after two
/// days of the app silently falling back to an in-memory container (see
/// `BUGS.md`). These pin the round-trip and, more importantly, the
/// real legacy row that doesn't round-trip.
@Suite("KnownNetwork.fingerprint")
struct KnownNetworkFingerprintTests {
    @Test("a fingerprint round-trips back to the values it was built from")
    func roundTrip() {
        let fingerprint = KnownNetwork.makeFingerprint(
            routerMAC: "bc:b9:23:81:a6:d4",
            subnet: "10.0.0.0/24"
        )
        #expect(KnownNetwork.routerMAC(fromFingerprint: fingerprint) == "bc:b9:23:81:a6:d4")
        #expect(KnownNetwork.subnet(fromFingerprint: fingerprint) == "10.0.0.0/24")
    }

    @Test("a legacy MAC-only fingerprint yields an empty subnet, not a crash")
    func legacyMACOnlyRow() {
        // Not hypothetical: this exact row is in the real store, written
        // before the subnet joined the key (back when router MAC alone
        // was the whole fingerprint). Reported as unknown rather than
        // guessed at.
        #expect(KnownNetwork.routerMAC(fromFingerprint: "bc:b9:23:81:a6:d4") == "bc:b9:23:81:a6:d4")
        #expect(KnownNetwork.subnet(fromFingerprint: "bc:b9:23:81:a6:d4") == "")
    }

    @Test("a MAC's colons don't get mistaken for the separator")
    func colonsAreNotSeparators() {
        // The separator is deliberately `|`, which appears in neither a
        // MAC (colons) nor a CIDR subnet (dots and a slash) — so a single
        // split at the first occurrence is unambiguous.
        let fingerprint = KnownNetwork.makeFingerprint(
            routerMAC: "fc:34:97:38:c6:b0",
            subnet: "192.168.50.0/24"
        )
        #expect(KnownNetwork.routerMAC(fromFingerprint: fingerprint) == "fc:34:97:38:c6:b0")
        #expect(KnownNetwork.subnet(fromFingerprint: fingerprint) == "192.168.50.0/24")
    }

    @Test("an empty subnet still produces a separator, so it stays distinguishable")
    func emptySubnetKeepsSeparator() {
        // A same-MAC network with an unknown subnet must not collide with
        // the legacy MAC-only row above — one has a trailing separator,
        // the other has none, so their fingerprints differ and SwiftData's
        // uniqueness constraint keeps them apart.
        let withEmpty = KnownNetwork.makeFingerprint(routerMAC: "aa:bb:cc:dd:ee:ff", subnet: "")
        #expect(withEmpty != "aa:bb:cc:dd:ee:ff")
        #expect(KnownNetwork.subnet(fromFingerprint: withEmpty) == "")
        #expect(KnownNetwork.routerMAC(fromFingerprint: withEmpty) == "aa:bb:cc:dd:ee:ff")
    }
}

// MARK: - SaaSStatusService parsers

/// Fixture-based, no network — real JSON shapes, matched to what each
/// vendor's endpoint was confirmed (via live `curl`) to actually send,
/// documented in each `parseXXX` function's own doc comment. Exists
/// because these parsers already caused a real shipped bug once:
/// `77912bf` fixed OpenAI/Notion sending no `incidents` key at all
/// (rather than `"incidents": []`) throwing `keyNotFound` and sticking
/// both services at "Could not check status" forever despite a healthy
/// 200. That fixture is `notionMissingIncidentsKey` below — this suite
/// exists so the next vendor that does the same thing is caught here,
/// not after shipping.
@Suite("SaaSStatusService parsers")
struct SaaSStatusParserTests {
    @Test("Statuspage: healthy with an explicit empty incidents array (Claude's shape)")
    func statuspageHealthyExplicitEmpty() throws {
        let json = Data(#"{"status":{"indicator":"none","description":"All Systems Operational"},"incidents":[]}"#.utf8)
        let result = try SaaSStatusService.parseStatuspage(json)
        #expect(result.indicator == .none)
        #expect(result.description == "All Systems Operational")
        #expect(result.specificURL == nil)
    }

    @Test("Statuspage: healthy with the incidents key omitted entirely — the real 77912bf regression case")
    func statuspageHealthyMissingKey() throws {
        let json = Data(#"{"status":{"indicator":"none","description":"All Systems Operational"}}"#.utf8)
        let result = try SaaSStatusService.parseStatuspage(json)
        #expect(result.indicator == .none)
        #expect(result.description == "All Systems Operational")
    }

    @Test("Statuspage: a real incident's name/shortlink win over the generic status description")
    func statuspageWithIncident() throws {
        let json = Data(#"""
        {"status":{"indicator":"major","description":"Partial System Outage"},
         "incidents":[{"name":"Degraded performance on Claude Sonnet 5","shortlink":"https://status.claude.com/incidents/abc123"}]}
        """#.utf8)
        let result = try SaaSStatusService.parseStatuspage(json)
        #expect(result.indicator == .major)
        #expect(result.description == "Degraded performance on Claude Sonnet 5")
        #expect(result.specificURL == "https://status.claude.com/incidents/abc123")
    }

    @Test("Statuspage: an unrecognized indicator string reports unknown, not a crash or a silent healthy")
    func statuspageUnrecognizedIndicator() throws {
        let json = Data(#"{"status":{"indicator":"catastrophic","description":"???"},"incidents":[]}"#.utf8)
        let result = try SaaSStatusService.parseStatuspage(json)
        #expect(result.indicator == .unknown)
    }

    @Test("Statuspage: a scheduled maintenance window reports .maintenance, not .unknown — the real Asana shape")
    func statuspageMaintenance() throws {
        // Confirmed live via `curl` against Asana's real `summary.json`
        // during an actual in-progress scheduled maintenance window
        // (`scheduled_maintenances[0].status == "in_progress"`) — this is
        // the exact `status` object it returned. `incidents` stayed
        // empty; maintenance is a separate top-level array this parser
        // doesn't read, so `status.indicator`/`.description` are the only
        // signal available for it, same as every other case here.
        let json = Data(#"{"status":{"indicator":"maintenance","description":"Service Under Maintenance"},"incidents":[]}"#.utf8)
        let result = try SaaSStatusService.parseStatuspage(json)
        #expect(result.indicator == .maintenance)
        #expect(result.description == "Service Under Maintenance")
    }

    @Test("Slack: healthy (empty active_incidents)")
    func slackHealthy() throws {
        let json = Data(#"{"status":"ok","active_incidents":[]}"#.utf8)
        let result = try SaaSStatusService.parseSlack(json)
        #expect(result.indicator == .none)
        #expect(result.description == "All Systems Operational")
    }

    @Test("Slack: an active incident always reports major, and carries its own title/url")
    func slackActiveIncident() throws {
        let json = Data(#"""
        {"status":"critical","active_incidents":[{"title":"Messages delayed","url":"https://slack-status.com/incidents/xyz"}]}
        """#.utf8)
        let result = try SaaSStatusService.parseSlack(json)
        #expect(result.indicator == .major)
        #expect(result.description == "Messages delayed")
        #expect(result.specificURL == "https://slack-status.com/incidents/xyz")
    }

    @Test("Slack: a title-less incident falls back to a generic description rather than failing")
    func slackIncidentMissingTitle() throws {
        let json = Data(#"{"status":"critical","active_incidents":[{"title":null,"url":null}]}"#.utf8)
        let result = try SaaSStatusService.parseSlack(json)
        #expect(result.indicator == .major)
        #expect(result.description == "Active incident reported")
        #expect(result.specificURL == nil)
    }

    @Test("Zendesk: healthy (empty data array)")
    func zendeskHealthy() throws {
        let json = Data(#"{"data":[],"included":[]}"#.utf8)
        let result = try SaaSStatusService.parseZendesk(json)
        #expect(result.indicator == .none)
    }

    @Test("Zendesk: multiple active incidents join their titles into one description")
    func zendeskMultipleIncidents() throws {
        let json = Data(#"""
        {"data":[{"attributes":{"title":"API degraded"}},{"attributes":{"title":"Dashboard slow"}}]}
        """#.utf8)
        let result = try SaaSStatusService.parseZendesk(json)
        #expect(result.indicator == .major)
        #expect(result.description == "API degraded, Dashboard slow")
        #expect(result.specificURL == nil, "Zendesk's shape has no per-incident URL — every row falls back to the general status page")
    }

    @Test("Google incidents: healthy when every incident in the history has already ended")
    func googleIncidentsHealthy() throws {
        let json = Data(#"""
        [{"modified":"2026-07-25T13:16:55+00:00","end":"2026-07-16T12:25:00+00:00","external_desc":"resolved","severity":"high"}]
        """#.utf8)
        let service = SaaSStatusService.MonitoredService(name: "Google Cloud", endpoint: URL(string: "https://status.cloud.google.com/incidents.json")!, shape: .googleIncidents)
        let result = try SaaSStatusService.parseGoogleIncidents(json, service: service)
        #expect(result.indicator == .none)
        #expect(result.description == "All Systems Operational")
    }

    @Test("Google incidents: an ongoing (no end) incident maps high severity to major")
    func googleIncidentsOngoingHighSeverity() throws {
        let json = Data(#"""
        [{"modified":"2026-07-25T13:16:55+00:00","end":null,"external_desc":"Cooling failure in europe-west4-a","severity":"high","uri":"incidents/abc"}]
        """#.utf8)
        let service = SaaSStatusService.MonitoredService(name: "Google Cloud", endpoint: URL(string: "https://status.cloud.google.com/incidents.json")!, shape: .googleIncidents)
        let result = try SaaSStatusService.parseGoogleIncidents(json, service: service)
        #expect(result.indicator == .major)
        #expect(result.description == "Cooling failure in europe-west4-a")
        #expect(result.specificURL == "https://status.cloud.google.com/incidents/abc")
    }

    @Test("Google incidents: medium severity maps to minor, and an unrecognized/missing severity maps to unknown rather than a guess")
    func googleIncidentsSeverityMapping() throws {
        let mediumJSON = Data(#"[{"modified":"2026-07-25T13:16:55+00:00","end":null,"severity":"medium"}]"#.utf8)
        let unknownJSON = Data(#"[{"modified":"2026-07-25T13:16:55+00:00","end":null,"severity":"low"}]"#.utf8)
        let missingJSON = Data(#"[{"modified":"2026-07-25T13:16:55+00:00","end":null}]"#.utf8)
        let service = SaaSStatusService.MonitoredService(name: "Google Cloud", endpoint: URL(string: "https://status.cloud.google.com/incidents.json")!, shape: .googleIncidents)
        #expect(try SaaSStatusService.parseGoogleIncidents(mediumJSON, service: service).indicator == .minor)
        #expect(try SaaSStatusService.parseGoogleIncidents(unknownJSON, service: service).indicator == .unknown)
        #expect(try SaaSStatusService.parseGoogleIncidents(missingJSON, service: service).indicator == .unknown)
    }

    @Test("Google incidents: with two incidents ongoing at once, the most recently modified one wins")
    func googleIncidentsMostRecentlyModifiedWins() throws {
        let json = Data(#"""
        [{"modified":"2026-07-20T00:00:00+00:00","end":null,"external_desc":"older, stays hidden","severity":"medium"},
         {"modified":"2026-07-25T13:16:55+00:00","end":null,"external_desc":"newer, should win","severity":"high"}]
        """#.utf8)
        let service = SaaSStatusService.MonitoredService(name: "Google Cloud", endpoint: URL(string: "https://status.cloud.google.com/incidents.json")!, shape: .googleIncidents)
        let result = try SaaSStatusService.parseGoogleIncidents(json, service: service)
        #expect(result.description == "newer, should win")
        #expect(result.indicator == .major)
    }

    @Test("Google incidents: the specific-incident URL is built against dashboardPath when the endpoint host isn't itself a status page (Google Workspace)")
    func googleIncidentsURLUsesDashboardPath() throws {
        let json = Data(#"[{"modified":"2026-07-25T13:16:55+00:00","end":null,"severity":"high","uri":"incidents/xyz"}]"#.utf8)
        let service = SaaSStatusService.MonitoredService(
            name: "Google Workspace",
            endpoint: URL(string: "https://www.google.com/appsstatus/dashboard/incidents.json")!,
            shape: .googleIncidents,
            dashboardPath: "/appsstatus/dashboard/"
        )
        let result = try SaaSStatusService.parseGoogleIncidents(json, service: service)
        #expect(result.specificURL == "https://www.google.com/appsstatus/dashboard/incidents/xyz")
    }
}

// MARK: - ISPIdentityService

/// Fixture-based, no network. `sonicRegistrantEntity` is a trimmed real
/// shape — captured live against this app's own actual public IP — of
/// the field path `ISPIdentityService.parseRegistrantName` depends on:
/// the entity tagged `"registrant"`, its `vcardArray`'s `"fn"` property.
@Suite("ISPIdentityService")
struct ISPIdentityServiceTests {
    @Test("The real Sonic.net shape: a registrant entity's fn wins")
    func realRegistrantShape() throws {
        let json = Data(#"""
        {"entities":[
            {"handle":"SNIC","roles":["registrant"],"vcardArray":["vcard",[
                ["version",{},"text","4.0"],
                ["fn",{},"text","Sonic.net, LLC"],
                ["kind",{},"text","org"]
            ]]},
            {"handle":"ABUSE546-ARIN","roles":["abuse"],"vcardArray":["vcard",[
                ["fn",{},"text","Abuse Department"],
                ["org",{},"text","Sonic.net, LLC"]
            ]]}
        ]}
        """#.utf8)
        #expect(try ISPIdentityService.parseRegistrantName(json) == "Sonic.net, LLC")
    }

    @Test("No entity tagged registrant falls back to the first entity")
    func noRegistrantRoleFallsBackToFirst() throws {
        let json = Data(#"""
        {"entities":[
            {"handle":"X","roles":["technical"],"vcardArray":["vcard",[["fn",{},"text","Some ISP LLC"]]]}
        ]}
        """#.utf8)
        #expect(try ISPIdentityService.parseRegistrantName(json) == "Some ISP LLC")
    }

    @Test("No entities array at all throws rather than crashing")
    func noEntitiesThrows() {
        let json = Data(#"{"name":"SOME-BLK"}"#.utf8)
        #expect(throws: ISPIdentityService.ISPIdentityError.self) {
            try ISPIdentityService.parseRegistrantName(json)
        }
    }

    @Test("An entity with no fn property throws rather than guessing")
    func noFnPropertyThrows() {
        let json = Data(#"""
        {"entities":[{"roles":["registrant"],"vcardArray":["vcard",[["version",{},"text","4.0"]]]}]}
        """#.utf8)
        #expect(throws: ISPIdentityService.ISPIdentityError.self) {
            try ISPIdentityService.parseRegistrantName(json)
        }
    }

    @Test("Malformed JSON throws rather than crashing")
    func malformedJSONThrows() {
        let json = Data("not json".utf8)
        #expect(throws: ISPIdentityService.ISPIdentityError.self) {
            try ISPIdentityService.parseRegistrantName(json)
        }
    }

    @Test("statusPageURL: a known organization hits, an unknown one (Astound -- checked live, no public status page found) returns nil")
    func statusPageURLLookup() {
        let service = ISPIdentityService()
        #expect(service.statusPageURL(forOrganization: "Sonic.net, LLC") == "https://sonicstatus.com/")
        #expect(service.statusPageURL(forOrganization: "Astound Broadband LLC") == nil)
    }
}

// MARK: - Persistent-store fallback detection

/// A tiny, throwaway model — deliberately not any of the app's 11 real
/// SwiftData models. Reproducing the *literal* historical bug (a schema
/// gaining a new non-optional stored property on top of existing rows —
/// see `BUGS.md`'s "The persistent store fails to open") needs two
/// different compiled versions of the same class, which one test run
/// can't construct. What's tested instead is the actual guarantee that
/// matters: `NMSApp.openStoreWithFallback` must detect *any* store-open
/// failure and report it, never silently swallow one the way the
/// two-day bug's single `print()` did.
@Model
private final class FallbackTestModel {
    var id: String
    init(id: String) { self.id = id }
}

@Suite("NMSApp.openStoreWithFallback")
struct StoreFallbackTests {
    private static func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NMSTests-\(UUID().uuidString)")
            .appendingPathComponent("scratch.store")
    }

    @Test("a valid, openable path reports no fallback reason")
    func validStoreOpensCleanly() throws {
        let url = Self.scratchURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let schema = Schema([FallbackTestModel.self])
        let result = NMSApp.openStoreWithFallback(schema: schema, url: url)
        #expect(result.fallbackReason == nil)

        // Not just "didn't report a reason" — confirm the container is
        // actually the real, persistent one, not silently in-memory
        // despite a nil reason (the exact failure mode this whole path
        // exists to prevent).
        let context = ModelContext(result.container)
        context.insert(FallbackTestModel(id: "test"))
        try context.save()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a store that fails to open is detected and reported, not silently swallowed")
    func corruptStoreFallsBackAndReports() throws {
        let url = Self.scratchURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Garbage bytes, not a real SwiftData/SQLite store — guaranteed
        // to fail to open, the same category of failure (store exists
        // on disk but can't be opened as-is) as a genuine migration
        // mismatch, without needing to construct one.
        try Data("not a real store".utf8).write(to: url)

        let schema = Schema([FallbackTestModel.self])
        let result = NMSApp.openStoreWithFallback(schema: schema, url: url)

        #expect(result.fallbackReason != nil, "a corrupt store must be reported, not silently accepted")
        #expect(result.fallbackReason?.isEmpty == false)

        // The fallback container must still be genuinely usable — the
        // whole point of falling back at all — even though nothing
        // written to it will persist.
        let context = ModelContext(result.container)
        context.insert(FallbackTestModel(id: "test"))
        #expect(throws: Never.self) { try context.save() }
    }
}

@Suite("DDNSViewModel.syncState")
struct DDNSSyncStateTests {
    @Test("matching resolved and public IPs, no CGNAT: current")
    func matchingIsCurrent() {
        let state = DDNSViewModel.syncState(resolvedIP: "203.0.113.4", publicIP: "203.0.113.4", isCGNAT: false)
        #expect(state == .current)
    }

    @Test("mismatched IPs, no CGNAT: stale")
    func mismatchIsStale() {
        let state = DDNSViewModel.syncState(resolvedIP: "203.0.113.4", publicIP: "203.0.113.9", isCGNAT: false)
        #expect(state == .stale)
    }

    /// CGNAT preempts the plain comparison rather than supplementing it —
    /// even a "matching" pair is still reported as blocked, since
    /// `publicIP` here would only ever be this Mac's own CGNAT-internal
    /// address, never the real address a DDNS record would need to point
    /// at. See `DDNSViewModel.syncState`'s own doc comment.
    @Test("CGNAT confirmed, IPs match: blockedByCGNAT, not current")
    func cgnatOverridesMatch() {
        let state = DDNSViewModel.syncState(resolvedIP: "100.64.1.2", publicIP: "100.64.1.2", isCGNAT: true)
        #expect(state == .blockedByCGNAT)
    }

    @Test("CGNAT confirmed, IPs mismatch: still blockedByCGNAT, not stale")
    func cgnatOverridesMismatch() {
        let state = DDNSViewModel.syncState(resolvedIP: "203.0.113.4", publicIP: "203.0.113.9", isCGNAT: true)
        #expect(state == .blockedByCGNAT)
    }
}
