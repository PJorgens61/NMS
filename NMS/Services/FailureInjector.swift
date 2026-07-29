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
/// **Controlled entirely from the command line, with no UI.** Two
/// reasons. The popover has no vertical headroom left (it fits a 13"
/// MacBook Air exactly, after the Events list was trimmed to make it
/// fit), and a UI toggle would mean every test needs someone to click
/// something — where a defaults key can be set by whoever is doing the
/// debugging, including a script or an AI assistant driving the session.
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
/// Read fresh on every check round, so changes take effect within one
/// cadence — though `cfprefsd` may not surface an external edit to an
/// already-running process, so restarting the app is the reliable way to
/// pick one up.
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
