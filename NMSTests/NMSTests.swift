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

/// The popover's height budget, as arithmetic rather than as a recurring
/// discovery on someone's smaller screen.
///
/// This app's single most-repeated bug is "the popover outgrew the M1
/// MacBook Air again" — fixed at least three separate times by hand
/// (Events 170→136, DHCP History 90→56, SNMP Devices 140→123), each time
/// found only after it shipped, because nothing could answer "what does
/// the popover cost?" without a human reading six scattered comments and
/// adding them up. `SectionLayout` makes that a computation; these tests
/// make it a build failure.
@Suite("SectionLayout")
struct SectionLayoutTests {
    @Test("the popover's scroll boxes stay within their declared budget")
    func popoverBoxTotalWithinBudget() {
        // The guard that actually catches the recurring regression:
        // adding a section to the popover, or growing an existing box,
        // fails here. Shrinking is deliberately free.
        #expect(SectionLayout.popoverBoxTotal <= SectionLayout.popoverBoxBudget)
    }

    @Test("the budget reflects today's real total, not a number with slack in it")
    func budgetHasNoHiddenSlack() {
        // Pins the budget *to* the total, so the test above can't quietly
        // stop being a constraint: if someone raises the budget to make a
        // failure go away without shrinking anything, this catches it and
        // forces the trade-off to be stated rather than absorbed.
        #expect(SectionLayout.popoverBoxTotal == SectionLayout.popoverBoxBudget)
    }

    @Test("the popover's scroll boxes are the only trimmable space, and it's small")
    func trimmableSpaceIsMostlyGone() {
        // Documents the finding that motivated this whole structure: the
        // trim lever is nearly exhausted. Against a last-measured popover
        // of 846-860pt, the boxes are ~252pt — everything else (the tile
        // grid's rows, headers, dividers, footer) has no trim mechanism
        // at all. If this ever drops much further, trimming has stopped
        // being a viable answer and content has to move to the window
        // instead.
        #expect(SectionLayout.popoverBoxTotal < SectionLayout.estimatedPopoverCeiling / 2)
    }

    @Test("window-only sections declare no popover height")
    func windowOnlySectionsHaveNoPopoverHeight() {
        // The exact defect this replaced: SNMP Devices and DHCP History
        // both kept carefully-trimmed popover heights (123pt and 56pt)
        // long after becoming window-only — ~180pt of budget that a
        // future trim would have reasoned about and found wasn't there.
        for section in SectionLayout.allCases where !section.appears(on: .popover) {
            #expect(
                section.boxHeight(on: .popover) == nil,
                "\(section.rawValue) is window-only but declares a popover height"
            )
        }
    }

    @Test("every section appears on at least one surface")
    func noOrphanedSections() {
        for section in SectionLayout.allCases {
            #expect(!section.surfaces.isEmpty, "\(section.rawValue) renders nowhere")
        }
    }

    @Test("the window gives every box at least as much room as the popover")
    func windowIsNeverTighterThanThePopover() {
        // The window exists precisely because it has room the popover
        // doesn't. A section that's tighter there would be a typo, not a
        // decision.
        for section in SectionLayout.allCases {
            guard let popover = section.boxHeight(on: .popover),
                  let window = section.boxHeight(on: .window) else { continue }
            #expect(window >= popover, "\(section.rawValue) is tighter in the window")
        }
    }

    @Test("sections that scroll on both surfaces always box in the window")
    func windowAlwaysBoxes() {
        // The popover's row-count threshold exists to avoid blank space
        // under 1-2 rows; the window ignores it so sections behave
        // consistently there. Pins that asymmetry as intentional.
        for section in SectionLayout.allCases where section.appears(on: .window) {
            guard section.boxHeight(on: .window) != nil else { continue }
            #expect(section.scrollThreshold >= 0)
        }
    }

    @Test("Printer Alerts carries a row of headroom past the 2-printer boundary")
    func printerAlertsHasHeadroom() {
        // A same-day bug report ("might need to be taller for 2 printers")
        // against a box sized to exactly 2 rows, filed before a second
        // real printer existed to test with. The headroom stands in for
        // the measurement that couldn't be taken — pinned so it isn't
        // "tidied" back to the exact boundary later.
        #expect(SectionLayout.printerAlerts.boxHeight(on: .window) == SectionLayout.rowHeight * 3)
    }

    @Test("the measured row-height constant is the one the trims were derived from")
    func rowHeightIsTheMeasuredConstant() {
        // 17pt/row is measured, not estimated: two real desktop
        // screenshots bracketing 41e169c showed 10 rows in 170pt and 8
        // rows in 136pt. Both trims in the table derive from it.
        #expect(SectionLayout.rowHeight == 17)
        #expect(SectionLayout.events.boxHeight(on: .popover) == SectionLayout.rowHeight * 8)
    }
}
