import Foundation

/// Lightweight, no-server feature gating — for features not yet ready to
/// be on by default for every install, now that friends are testing NMS
/// on their own Macs rather than just the two this was developed on.
///
/// Backed by `UserDefaults`, the same mechanism `NMSStorePath` and
/// `FailureInjector`'s debug overrides already use — deliberately not
/// `#if DEBUG`: these need to work in whatever build a tester actually
/// runs, not just a debug build. There's no server here to serve flags
/// remotely or do staged rollouts (this is a local-only app, per the
/// README), so this is intentionally just "read a UserDefaults bool,"
/// nothing more.
///
/// `UserDefaults.bool(forKey:)` returns `false` for a key that's never
/// been set, so **every flag here defaults to off for a fresh install**
/// — a tester gets the stable, core experience unless a flag is
/// explicitly turned on. That cuts the other way for machines that were
/// already running NMS before a given flag existed: they won't have the
/// key set either, so review whether your own daily-use Macs need a
/// `defaults write` to keep what they already had. See the README's
/// "Experimental features" section for the exact commands.
enum FeatureFlags {
    private static let defaults = UserDefaults.standard

    /// Key names as named constants, not inline string literals, so
    /// `PreferencesView`'s `@AppStorage` toggles and the plain reads below
    /// share one source of truth rather than two copies of the same
    /// string that could quietly drift apart.
    static let comparisonWindowKey = "FeatureComparisonWindow"
    static let snmpDevicesKey = "FeatureSNMPDevices"
    static let saasMonitoringKey = "FeatureSaaSMonitoring"

    /// The resizable "Open in Window" alternative to the popover — see
    /// `NMSApp`'s "nms-window" scene doc comment. Still explicitly
    /// "not yet a replacement for the popover, just a side-by-side
    /// alternative to evaluate," which is exactly the kind of thing this
    /// type exists to keep off by default for a new install.
    static var comparisonWindow: Bool {
        defaults.bool(forKey: comparisonWindowKey)
    }

    /// SNMP device discovery/monitoring — active network probing (SNMP
    /// GET sweeps) against whatever LAN the Mac is attached to. Off by
    /// default for a fresh install specifically because of that: a
    /// friend testing on their own network hasn't necessarily reviewed
    /// or approved NMS probing their devices, and this feature has also
    /// had several real bugs found and fixed against it recently (see
    /// DESIGN-NOTES.md's "Per-network device scoping"). Gates more than
    /// the UI section — `SNMPViewModel` itself doesn't scan or poll at
    /// all while this is off, not just hides what it finds.
    ///
    /// Read once at `SNMPViewModel.init()`, not observed afterward —
    /// toggling this in `PreferencesView` while NMS is already running
    /// takes effect on the next restart, not immediately. See that view's
    /// doc comment for why that's the deliberate v1 behavior rather than
    /// a gap.
    static var snmpDevices: Bool {
        defaults.bool(forKey: snmpDevicesKey)
    }

    /// Periodic checks against a small, fixed list of business SaaS
    /// status pages (Slack, Claude, ChatGPT) — see
    /// `SaaSStatusService`/`SaaSMonitoringViewModel` and DESIGN-NOTES.md's
    /// "Business SaaS monitoring". Off by default for the same reason
    /// `snmpDevices` is: this reaches out to third-party services
    /// periodically, which a fresh install shouldn't do without explicit
    /// opt-in, even though (unlike SNMP) it's a WAN fetch rather than LAN
    /// probing. Read once at `SaaSMonitoringViewModel.init()`, same
    /// restart-to-apply behavior as `snmpDevices`.
    static var saasMonitoring: Bool {
        defaults.bool(forKey: saasMonitoringKey)
    }
}
