import Foundation

/// Debug-only forcing of connectivity check failures, so the app's
/// reaction to an outage can be exercised without unplugging anything.
///
/// Everything interesting about an outage in this app is *downstream* of
/// the checks themselves: the down/up event pair, the drop from the 30s
/// cadence to the 5s one, the menu bar going red vs. yellow
/// (`OverallStatus`), the root-cause dimming that decides which failing
/// layer is the cause and which are consequences, and the
/// `correlatedWithChange` asterisk. None of that had any way to be
/// triggered on demand — every outage path in this app was previously
/// tested by physically pulling a cable, and the DHCP change-event work
/// resorted to editing a value directly in the SQLite store.
///
/// Injecting *results* rather than faking services is deliberate. The
/// services are thin shell-outs to `ping`/`snmpget`/`getaddrinfo` that
/// real use exercises constantly; protocolizing eight of them purely for
/// test seams would be a large change to production code to reach logic
/// that sits after them anyway.
///
/// **Controlled entirely from the command line, with no UI.** A UI
/// toggle would mean every test needs someone to click something, where
/// a defaults key can be set by whoever is doing the debugging,
/// including a script or an AI assistant driving the session — that
/// scriptability is the whole point, not a workaround for popover space
/// that happened to be scarce (that specific constraint is resolved now
/// that every scrollable/full-width section moved window-only; see
/// `SectionLayout`'s "audience split").
///
/// **Use the full plist path, not the bare domain name.** This matters
/// and cost real time to work out:
///
/// ```
/// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectFailures -array Router DNS
/// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectFailures -array "ISP Edge Router"
/// defaults delete ~/Library/Preferences/Thistle.NMS.plist NMSInjectFailures   # back to reality
/// ```
///
/// `defaults write Thistle.NMS …` — the obvious form — silently writes
/// somewhere the app never reads. A stale sandbox container exists at
/// `~/Library/Containers/Thistle.NMS/` from an earlier sandboxed build,
/// and the `defaults` CLI resolves the bare domain to the container's
/// `Thistle.nms.plist`, while the app (now unsandboxed) reads
/// `~/Library/Preferences/Thistle.NMS.plist`. Both `defaults read`
/// spellings then *confirm the key is set*, which makes the failure
/// especially confusing — the key really is written, just not where it
/// gets read. Diagnosed by noticing that a key the app definitely
/// persists (`NMS.snmpCommunities`) was absent from the file the CLI had
/// been writing to.
///
/// Read fresh on every check round, and a running app **does** pick up
/// an external `defaults` edit within one cadence — no relaunch needed.
/// (An earlier note here claimed otherwise; that was an artifact of
/// writing to the wrong plist, not `cfprefsd` caching. Verified by
/// clearing the key against a live app and watching the next round come
/// back healthy.)
///
/// Live toggling matters more than it sounds, because *recovery* events
/// are only observable that way. `ConnectivityViewModel.logTransitions`
/// compares against the previous round's in-memory results, which start
/// empty at launch — so relaunching with the key cleared logs nothing at
/// all, while clearing it in place produces the real down/up pair.
///
/// **What this cannot do**, and it matters: it tests the app's *reaction*
/// to a failure, not its *detection* of one. A `ping` that hangs instead
/// of failing, or a resolver that returns a bogus success, still needs
/// real conditions — and that class has genuinely bitten this app before
/// (`getaddrinfo` returning success in ~1ms with no interface up, which
/// is why `runChecks` short-circuits that case explicitly).
enum FailureInjector {
    /// Matched exactly against `ConnectivityCheck.label` — so "Router",
    /// "Internet", "DNS", "HTTP", "Public IP", "ISP Edge Router", or any
    /// SNMP device's display name.
    static let defaultsKey = "NMSInjectFailures"

    /// Matched against `SaaSStatusService.MonitoredService.name` — see
    /// `applySaaSChanges`. A named constant since it's read from three
    /// places in this file (`applySaaSChanges`, `isSaaSForced`,
    /// `activeOverridesSummary`), same reasoning most of `FeatureFlags`'
    /// own keys are named constants. Still command-line-only, no UI —
    /// see this type's own "why no UI" reasoning above. (Not to be
    /// confused with `FeatureFlags.saasEnabledServicesKey`, a real
    /// user-facing preference for which services to monitor at all,
    /// unrelated to this debug-only failure injection.)
    static let saasOutageDefaultsKey = "NMSInjectSaaSOutage"

    /// `#if DEBUG` throughout, without exception. Injected failures write
    /// genuine `AppEventRecord` and `ConnectivityCheckRecord` rows — a
    /// release build that could be made to fabricate outages would
    /// corrupt a real incident history, which is a worse outcome than not
    /// having the tool at all.
    static var forcedLabels: Set<String> {
        #if DEBUG
        return Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        #else
        return []
        #endif
    }

    static func isForced(_ label: String) -> Bool {
        #if DEBUG
        return forcedLabels.contains(label)
        #else
        return false
        #endif
    }

    /// Forces `NetworkMonitorViewModel` to report no active interface —
    /// the "cable unplugged, Wi-Fi off" case.
    ///
    /// ```
    /// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectInterfaceDown -bool YES
    /// ```
    ///
    /// Worth having even though real unplugging can produce it, because
    /// this path has a branch nothing else reaches: `runChecks` detects
    /// the nil interface and short-circuits Internet/DNS/HTTP rather than
    /// attempting them, specifically because `getaddrinfo` was measured
    /// returning a bogus ~1ms success with no interface up.
    ///
    /// **One limit remains, one was closed.** It still only bites when
    /// something calls `NetworkMonitorViewModel.refresh()` — the popover's
    /// Refresh button, or a real topology change — since nothing polls it
    /// on a timer.
    ///
    /// It previously could *not* produce `interfaceDown`/`interfaceUp`
    /// events at all, since those were logged only from a path reachable
    /// exclusively via the real `SCDynamicStore` callback, which this
    /// doesn't fake. That's fixed now, without faking the callback:
    /// `refresh()` and the real observer path were merged into one
    /// `updateInterface()` that both call, so a Refresh press reacts
    /// exactly as a real topology change would — set this key, press
    /// Refresh, and the real `interfaceDown` event logs; clear it, press
    /// Refresh again, and `interfaceUp` logs. What this exercises is
    /// everything downstream of a nil interface, genuine events included.
    static var isInterfaceDownForced: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "NMSInjectInterfaceDown")
        #else
        return false
        #endif
    }

    /// Forces the DHCP link-local (APIPA) fallback signal — "DHCP failed
    /// and the OS self-assigned a 169.254.x.x address."
    ///
    /// ```
    /// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectDHCPLinkLocal -bool YES
    /// ```
    ///
    /// This is one of two DHCP failure signals that had **never been
    /// exercised at all** before injection existed — producing a genuine
    /// APIPA fallback means breaking DHCP on the real network, and the
    /// `dhcpFellBackToLinkLocal`/`dhcpAddressRestored` pair had therefore
    /// only ever been reasoned about, never observed.
    static var isDHCPLinkLocalForced: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "NMSInjectDHCPLinkLocal")
        #else
        return false
        #endif
    }

    /// Forces the DHCP renewal-overdue signal — the lease's transaction
    /// ID hasn't changed past its own T2 (rebinding) deadline.
    ///
    /// ```
    /// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectDHCPRenewalOverdue -bool YES
    /// ```
    ///
    /// The other never-exercised DHCP signal, and the harder of the two
    /// to reach honestly: with a 24h lease and a T2 at 87.5%, waiting for
    /// a real overdue renewal takes 21 hours and requires the DHCP server
    /// to actually misbehave.
    static var isDHCPRenewalOverdueForced: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "NMSInjectDHCPRenewalOverdue")
        #else
        return false
        #endif
    }

    /// Applied where the interface is read, so both `refresh()` and the
    /// change-observer path get it from one place.
    static func applyInterfaceDown(to info: NetworkInterfaceInfo?) -> NetworkInterfaceInfo? {
        #if DEBUG
        return isInterfaceDownForced ? nil : info
        #else
        return info
        #endif
    }

    /// Rewrites polled SNMP results so the app's own change detection
    /// concludes a device restarted, or that its software changed.
    ///
    /// ```
    /// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectSNMPRestart -array Switch
    /// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectSNMPSoftwareChange -array AP1
    /// ```
    ///
    /// Names match `SNMPDevice.displayName` — the `sysName` a device
    /// reports, or its IP if it reports none.
    ///
    /// Deliberately rewrites the *inputs* rather than forcing the
    /// outcome. `SnapshotStore.recordSNMPDevice` decides a restart from
    /// `uptimeTicks < previousTicks` and a software change from a
    /// differing `sysDescr`, so faking the comparison's result would test
    /// nothing — feeding it a low uptime makes the real comparison run,
    /// including the case the two signals share: an uptime reset *with* a
    /// descriptor change is reported as `snmpDeviceSoftwareChanged`
    /// ("restarted after software change"), not the alarming
    /// `snmpDeviceRestarted`, because a reboot following an upgrade is
    /// explained rather than mysterious. Setting both keys for one device
    /// exercises exactly that branch.
    ///
    /// Fires once per injection rather than repeatedly, and does so
    /// without needing the key cleared: the forced uptime is persisted as
    /// the new baseline, so the next poll compares 1 against 1 and finds
    /// nothing changed.
    static func applySNMPChanges(to devices: [SNMPDevice]) -> [SNMPDevice] {
        #if DEBUG
        let restarts = Set(UserDefaults.standard.stringArray(forKey: "NMSInjectSNMPRestart") ?? [])
        let softwareChanges = Set(UserDefaults.standard.stringArray(forKey: "NMSInjectSNMPSoftwareChange") ?? [])
        guard !restarts.isEmpty || !softwareChanges.isEmpty else { return devices }
        return devices.map { device in
            let forceRestart = restarts.contains(device.displayName)
            let forceSoftwareChange = softwareChanges.contains(device.displayName)
            guard forceRestart || forceSoftwareChange else { return device }
            var forced = SNMPDevice(
                ipAddress: device.ipAddress,
                sysDescr: forceSoftwareChange ? "\(device.sysDescr) [injected]" : device.sysDescr,
                sysName: device.sysName,
                // 1 tick = one hundredth of a second of uptime, i.e. "just
                // came back", which is what a real restart looks like to
                // the very next poll.
                uptimeTicks: forceRestart ? 1 : device.uptimeTicks,
                community: device.community,
                polledAt: device.polledAt
            )
            // Preserved explicitly — these come from the ARP-based MAC
            // merge, not from SNMP, and dropping them would silently
            // un-merge a VRRP pair as a side effect of injection.
            forced.aliasAddresses = device.aliasAddresses
            return forced
        }
        #else
        return devices
        #endif
    }

    /// Forces one or more monitored SaaS services (by
    /// `SaaSStatusService.MonitoredService.name` — "Slack", "Claude",
    /// etc.) to report as down, so `SaaSMonitoringViewModel`'s real
    /// down/recovery transition logic and event logging can be exercised
    /// without waiting for or faking an actual third-party outage.
    ///
    /// ```
    /// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSInjectSaaSOutage -array Slack
    /// defaults delete ~/Library/Preferences/Thistle.NMS.plist NMSInjectSaaSOutage
    /// ```
    ///
    /// Rewrites the *result*, not an input one level removed — unlike
    /// `applySNMPChanges`, there's no deeper comparison this needs to
    /// preserve (a SaaS check's whole "outcome" is its indicator, the
    /// same reason `apply(to: [ConnectivityCheck])` above rewrites
    /// `success` directly rather than faking a ping's raw output). The
    /// real fetch still runs underneath — only the parsed result is
    /// overridden afterward, so this never masks a genuine problem
    /// reaching the endpoint.
    static func applySaaSChanges(to statuses: [SaaSMonitoringViewModel.ServiceStatus]) -> [SaaSMonitoringViewModel.ServiceStatus] {
        #if DEBUG
        let forced = Set(UserDefaults.standard.stringArray(forKey: saasOutageDefaultsKey) ?? [])
        guard !forced.isEmpty else { return statuses }
        return statuses.map { status in
            guard forced.contains(status.name) else { return status }
            return SaaSMonitoringViewModel.ServiceStatus(
                name: status.name,
                indicator: .major,
                description: "[injected] Simulated outage"
            )
        }
        #else
        return statuses
        #endif
    }

    /// True if `name` is currently forced down via `applySaaSChanges`, for
    /// prefixing its event-log message the same way connectivity/SNMP
    /// failures are prefixed — the description baked into the rewritten
    /// `ServiceStatus` already says "[injected]", but the durable event
    /// record needs its own marker too, same belt-and-suspenders
    /// reasoning `SNMPViewModel.apply`'s use of `isSNMPForced` follows.
    static func isSaaSForced(_ name: String) -> Bool {
        #if DEBUG
        let forced = UserDefaults.standard.stringArray(forKey: saasOutageDefaultsKey) ?? []
        return forced.contains(name)
        #else
        return false
        #endif
    }

    /// Divides a poll interval, so a scripted scenario doesn't spend
    /// most of its runtime asleep.
    ///
    /// ```
    /// defaults write ~/Library/Preferences/Thistle.NMS.plist NMSPollSpeedup -int 10
    /// defaults delete ~/Library/Preferences/Thistle.NMS.plist NMSPollSpeedup
    /// ```
    ///
    /// A **divisor rather than an absolute interval**, deliberately.
    /// Flattening everything to one value would destroy the relationships
    /// between intervals, and at least one of those is itself under test:
    /// `ConnectivityViewModel` drops from its 30s cadence to a 5s one
    /// while anything is unhealthy, which can't be observed if both
    /// become the same number. Scaling keeps 6:1 at any speed.
    ///
    /// Floored at one second. Without it, a large divisor would turn real
    /// `ping`/`snmpget` subprocess fan-out into a tight loop — the
    /// connectivity round alone shells out to roughly ten targets, so
    /// sub-second scheduling would be self-inflicted load rather than a
    /// faster test.
    ///
    /// Applied to the connectivity, SNMP, DHCP, traceroute, and SaaS
    /// monitoring timers, but deliberately **not** to `PublicIPViewModel`:
    /// that one calls a third-party service (`api.ipify.org`), and its
    /// 300s cadence is partly politeness rather than a tuning decision.
    /// Nothing testable depends on its frequency anyway — a
    /// `publicIPChanged` event needs the address to actually change,
    /// which no injection here does. SaaS monitoring is the opposite:
    /// `applySaaSChanges` *can* force a change, so speeding up its timer
    /// is what makes that injection's down/recovery transition actually
    /// observable without waiting up to 300s.
    static func acceleratedInterval(_ interval: TimeInterval) -> TimeInterval {
        #if DEBUG
        let divisor = UserDefaults.standard.double(forKey: "NMSPollSpeedup")
        guard divisor > 1 else { return interval }
        return max(1, interval / divisor)
        #else
        return interval
        #endif
    }

    /// True if either SNMP key names this device, for prefixing its event
    /// message the same way connectivity failures are prefixed.
    static func isSNMPForced(_ displayName: String) -> Bool {
        #if DEBUG
        let restarts = UserDefaults.standard.stringArray(forKey: "NMSInjectSNMPRestart") ?? []
        let softwareChanges = UserDefaults.standard.stringArray(forKey: "NMSInjectSNMPSoftwareChange") ?? []
        return restarts.contains(displayName) || softwareChanges.contains(displayName)
        #else
        return false
        #endif
    }

    /// Rewrites matching checks as failures, leaving everything else
    /// untouched. Builds a replacement rather than mutating, since
    /// `success` and `latencyMs` are deliberately `let` on
    /// `ConnectivityCheck` — injection shouldn't force production types
    /// to loosen for its benefit.
    static func apply(to checks: [ConnectivityCheck]) -> [ConnectivityCheck] {
        #if DEBUG
        let labels = forcedLabels
        guard !labels.isEmpty else { return checks }
        return checks.map { check in
            guard labels.contains(check.label) else { return check }
            return ConnectivityCheck(
                label: check.label,
                target: check.target,
                success: false,
                latencyMs: nil,
                checkedAt: check.checkedAt,
                correlatedWithChange: check.correlatedWithChange
            )
        }
        #else
        return checks
        #endif
    }

    /// A single, always-checkable answer to "is anything debug-injected
    /// right now" — every accessor above stays active silently once set
    /// (a failure, a poll speedup) with nothing forcing whoever set it to
    /// remember it's on. This is exactly the class of mistake that has
    /// happened for real in this project: a test's `defaults` key left
    /// set after the test ended, found later only by grepping the plist
    /// by hand. `nil` when nothing is active — checked fresh on every
    /// call, the same "read live, never cached" contract every key above
    /// already has, so this summary can't itself go stale.
    ///
    /// **Deliberately excludes `NMSStorePath`.** Unlike every key above,
    /// which is re-read every check round, the store path is read exactly
    /// once, in `NMSApp.init()`, to construct the `ModelContainer` — a
    /// `defaults write` after launch changes what this method would
    /// report without changing what the app is actually doing, which
    /// would make this summary actively misleading rather than merely
    /// incomplete. `NMSApp` already logs the real, resolved path via
    /// `App.store` at launch, which is the trustworthy source for that
    /// one setting.
    static func activeOverridesSummary() -> String? {
        #if DEBUG
        var parts: [String] = []
        let labels = forcedLabels
        if !labels.isEmpty {
            parts.append("failures forced: \(labels.sorted().joined(separator: ", "))")
        }
        if isInterfaceDownForced {
            parts.append("interface down")
        }
        if isDHCPLinkLocalForced {
            parts.append("DHCP link-local")
        }
        if isDHCPRenewalOverdueForced {
            parts.append("DHCP renewal overdue")
        }
        let restarts = Set(UserDefaults.standard.stringArray(forKey: "NMSInjectSNMPRestart") ?? [])
        if !restarts.isEmpty {
            parts.append("SNMP restart forced: \(restarts.sorted().joined(separator: ", "))")
        }
        let softwareChanges = Set(UserDefaults.standard.stringArray(forKey: "NMSInjectSNMPSoftwareChange") ?? [])
        if !softwareChanges.isEmpty {
            parts.append("SNMP software-change forced: \(softwareChanges.sorted().joined(separator: ", "))")
        }
        let saasOutages = Set(UserDefaults.standard.stringArray(forKey: saasOutageDefaultsKey) ?? [])
        if !saasOutages.isEmpty {
            parts.append("SaaS outage forced: \(saasOutages.sorted().joined(separator: ", "))")
        }
        let speedup = UserDefaults.standard.double(forKey: "NMSPollSpeedup")
        if speedup > 1 {
            parts.append("poll speed ×\(Int(speedup))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
        #else
        return nil
        #endif
    }

    /// Prefix for event messages about an injected failure, so the event
    /// log and store dumps stay honest — nobody reading history weeks
    /// later (or an AI assistant reading a store dump) should have to
    /// guess whether an outage was real. Empty for genuine failures.
    ///
    /// Deliberately asymmetric: the *recovery* event carries no prefix,
    /// because by the time it fires the injection has been cleared and
    /// the check really did succeed. That reads correctly rather than
    /// pedantically — "[injected] Router became unreachable" followed by
    /// "Router reachable again" is exactly what happened.
    static func messagePrefix(for label: String) -> String {
        #if DEBUG
        return isForced(label) ? "[injected] " : ""
        #else
        return ""
        #endif
    }
}
