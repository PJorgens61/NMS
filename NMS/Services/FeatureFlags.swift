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
///
/// **One deliberate exception**: `saasMonitoring` defaults to *on* — see
/// its own doc comment for why and how an explicit prior opt-out is
/// still respected.
enum FeatureFlags {
    private static let defaults = UserDefaults.standard

    /// Key names as named constants, not inline string literals, so
    /// `PreferencesView`'s `@AppStorage` toggles and the plain reads below
    /// share one source of truth rather than two copies of the same
    /// string that could quietly drift apart.
    static let snmpDevicesKey = "FeatureSNMPDevices"
    static let saasMonitoringKey = "FeatureSaaSMonitoring"
    static let saasEnabledServicesKey = "FeatureSaaSEnabledServices"
    static let userAddedSaaSSitesKey = "FeatureUserAddedSaaSSites"
    static let ddnsHostnamesKey = "FeatureDDNSHostnames"
    static let ddnsCheckIntervalKey = "FeatureDDNSCheckInterval"
    static let autoBaselineNetworkQualityKey = "FeatureAutoBaselineNetworkQuality"

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
    /// Live, not restart-required — `SNMPViewModel` observes
    /// `UserDefaults.didChangeNotification` itself and starts/stops its
    /// poll timer accordingly (`SNMPViewModel.activate()`/`deactivate()`).
    /// Was restart-only in an earlier version of this app; fixed directly
    /// once it turned out the "why" that gap's doc comments pointed to
    /// was never actually written down anywhere.
    static var snmpDevices: Bool {
        defaults.bool(forKey: snmpDevicesKey)
    }

    /// Periodic checks against a small, fixed list of business SaaS
    /// status pages — see `SaaSStatusService`/`SaaSMonitoringViewModel`
    /// and DESIGN-NOTES.md's "Business SaaS monitoring".
    ///
    /// **On by default, for now** — the one exception to this file's own
    /// "every flag defaults to off" rule above, requested directly
    /// rather than a silent flip. Originally off for the same reason
    /// `snmpDevices` is (reaches third parties periodically, shouldn't
    /// happen without opt-in) — that reasoning hasn't changed, this is a
    /// deliberate, named exception to it, not a reversal. `defaults.object`
    /// (not `.bool`) is checked first so an explicit prior opt-out
    /// (`-bool false`, from before this default flipped) is still
    /// honored — only a genuinely never-touched key defaults to on.
    /// Live, not restart-required — same
    /// observe-`UserDefaults.didChangeNotification`-and-start/stop-the-timer
    /// shape `snmpDevices` uses, see `SaaSMonitoringViewModel.activate()`/
    /// `deactivate()`.
    static var saasMonitoring: Bool {
        guard defaults.object(forKey: saasMonitoringKey) != nil else { return true }
        return defaults.bool(forKey: saasMonitoringKey)
    }

    /// Which of `SaaSStatusService.monitoredServices` are actually
    /// checked, once `saasMonitoring` itself is on — a second, finer
    /// layer under that one flag, for a real preference (which services
    /// you care about) rather than a feature on/off switch.
    ///
    /// `nil` means "never customized" — every service is monitored, the
    /// same as before this preference existed, so an install that never
    /// opens `PreferencesView`'s SaaS section keeps today's behavior
    /// exactly. Once the user touches any toggle there, this becomes an
    /// explicit array (via `PreferencesView`'s manual `UserDefaults`
    /// read/write — `[String]` isn't one of `@AppStorage`'s supported
    /// types, unlike the plain `Bool` flags above), which can legitimately
    /// be empty if every service gets unchecked. Live, not restart-required
    /// — `SaaSMonitoringViewModel.activeServices` is a computed property
    /// re-read on every `checkAll()` round rather than resolved once, so a
    /// change here reaches the *next* round automatically with no separate
    /// live-update plumbing needed.
    static var saasEnabledServices: Set<String>? {
        guard let stored = defaults.array(forKey: saasEnabledServicesKey) as? [String] else { return nil }
        return Set(stored)
    }

    /// A user's own site, checked for plain reachability rather than a
    /// real vendor status page — see `SaaSMonitoringViewModel
    /// .checkUserAddedSites`'s doc comment for why this is deliberately a
    /// separate, simpler check than the curated list above. `Identifiable`
    /// by `url` since that's the one field a user can't leave blank or
    /// duplicate meaningfully; `nickname` is just a display label.
    struct UserAddedSaaSSite: Codable, Identifiable, Equatable {
        var id: String { url }
        let url: String
        let nickname: String
    }

    /// `[Codable]` isn't one of `@AppStorage`'s supported types (same
    /// reason `saasEnabledServices` above is a plain array, not `[String]`
    /// either) — stored as JSON `Data` instead, empty array on any
    /// decode failure (a corrupted or pre-migration value) rather than
    /// crashing or surfacing an error nobody would see.
    static var userAddedSaaSSites: [UserAddedSaaSSite] {
        guard
            let data = defaults.data(forKey: userAddedSaaSSitesKey),
            let sites = try? JSONDecoder().decode([UserAddedSaaSSite].self, from: data)
        else {
            return []
        }
        return sites
    }

    static func setUserAddedSaaSSites(_ sites: [UserAddedSaaSSite]) {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        defaults.set(data, forKey: userAddedSaaSSitesKey)
    }

    /// A user-configured DDNS hostname to watch for staleness against
    /// this Mac's own public IP — see `DDNSViewModel`. `Identifiable` by
    /// `hostname` since that's the one field that can't be blank or
    /// duplicated meaningfully, same reasoning `UserAddedSaaSSite` gives
    /// for keying on `url`.
    struct DDNSHostname: Codable, Identifiable, Equatable {
        var id: String { hostname }
        let hostname: String
    }

    /// Same JSON-in-`Data` shape as `userAddedSaaSSites`, for the same
    /// reason: `[Codable]` isn't an `@AppStorage`-supported type.
    /// **Deliberately no separate on/off feature flag for this one** —
    /// an empty list is already fully inert (no timer, no checks), so
    /// there's no passive third-party reach to gate before the user has
    /// typed in a hostname, unlike `snmpDevices`/`saasMonitoring`.
    static var ddnsHostnames: [DDNSHostname] {
        guard
            let data = defaults.data(forKey: ddnsHostnamesKey),
            let hostnames = try? JSONDecoder().decode([DDNSHostname].self, from: data)
        else {
            return []
        }
        return hostnames
    }

    static func setDDNSHostnames(_ hostnames: [DDNSHostname]) {
        guard let data = try? JSONEncoder().encode(hostnames) else { return }
        defaults.set(data, forKey: ddnsHostnamesKey)
    }

    /// How often `DDNSViewModel` re-checks every configured hostname.
    /// Two choices only (see `PreferencesView`'s picker) — raised
    /// directly: someone depending on an inbound service (a self-hosted
    /// VPN endpoint, say) may want the aggressive 1-minute option, but a
    /// single `dig` call per hostname is cheap enough that even that
    /// isn't a real cost concern, so this doesn't need a wider range.
    /// `0` (an untouched key) means "never customized," same convention
    /// `saasEnabledServices`'s `nil` uses — defaults to 5 minutes.
    static var ddnsCheckInterval: TimeInterval {
        let stored = defaults.double(forKey: ddnsCheckIntervalKey)
        return stored > 0 ? stored : 300
    }

    /// Auto-runs Network Health's ~5s "networkQuality" quick check once,
    /// the moment a network you've already seen before is recognized
    /// again — so the dot has a real color instead of sitting gray until
    /// someone presses the button. Off by default, deliberately, same
    /// reasoning as `snmpDevices`: the check is a genuine, real
    /// `networkQuality` run (~5s, parallel-mode load, the same "Uses your
    /// data plan" cost the button's own tooltip already warns about), not
    /// a cheap ping — auto-firing it on every network a Mac joins,
    /// including someone else's guest Wi-Fi or a metered hotspot, would
    /// be real bandwidth use without explicit consent. Gated further, in
    /// `NMSApp`'s wiring, to only a network that's already `KnownNetwork`
    /// (`!isNewNetwork`) — never the very first time this Mac has ever
    /// seen a given network.
    static var autoBaselineNetworkQuality: Bool {
        defaults.bool(forKey: autoBaselineNetworkQualityKey)
    }
}
