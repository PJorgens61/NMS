import Foundation

/// Tracks the current DHCP lease (from `ipconfig getpacket`, a purely
/// local read — see `DHCPLeaseService`) and its history over time, plus two
/// independent failure signals explored in DESIGN-NOTES.md's "DHCP lease
/// tracking" section before this was written: a fallback to a
/// self-assigned (APIPA) address, and a renewal that's run past its
/// expected T2 deadline without the transaction ID changing.
@MainActor
@Observable
final class DHCPLeaseViewModel {
    /// Every real lease change, newest first — a genuine `@Model` array
    /// (like `NetworkIdentityViewModel.currentNetwork`) rather than a
    /// value-type projection, since the view just needs to list them.
    /// `history.first` doubles as "the current lease" — there's no
    /// separate "current" property, since the newest history row already
    /// is that.
    private(set) var history: [DHCPLeaseRecord] = [] {
        didSet { UIStateLogger.log("DHCPLeaseViewModel.history", history.map(\.info)) }
    }
    private(set) var isFallenBackToLinkLocal = false
    /// Same shape as `isFallenBackToLinkLocal` above — kept unconditionally
    /// current in `checkRenewalOverdue()`, `wasOverdue` below stays the
    /// separate, private edge-detector for the actual transition logging.
    /// Added for the merged Network tile's DHCP status dot (see
    /// `PUNCHLIST.md`'s "Network Health and Info tiles" item) — this
    /// state already existed for `.dhcpRenewalOverdue`/`.dhcpRenewalRecovered`
    /// event logging, it just wasn't readable by the UI before now.
    private(set) var isRenewalOverdue = false
    /// When `fieldChanges` last found a real, substantive difference from
    /// the previous lease on the same interface — `nil` until the first
    /// one this session. Distinct from any record's own `firstObservedAt`
    /// on purpose: a fresh `DHCPLeaseRecord` row gets inserted on *every*
    /// renewal (a new transaction ID, by protocol definition — see that
    /// type's own doc comment), including routine ones where nothing
    /// else moved, so `DHCPStatusRow`'s "recently changed" yellow needs
    /// this narrower signal, not just "a row exists that's new." Real gap
    /// found live (2026-08-06): a dual-homed Mac (Ethernet + Wi-Fi both
    /// active) waking from sleep re-renews both interfaces within
    /// seconds, and the status dot read that as "changed" even though
    /// neither interface's actual lease was any different than before.
    private(set) var lastGenuineChangeAt: Date?
    /// True while a user-triggered `renew()` is in flight — separate from
    /// `isChecking`, which fires on every routine poll and would otherwise
    /// make the Renew button flicker disabled during ordinary background
    /// activity that has nothing to do with the button being pressed.
    private(set) var isRenewing = false

    /// One-time "this briefly disrupts the connection and may prompt for
    /// an administrator password" acknowledgment — same shape as
    /// `WiFiStressTestViewModel.hasConfirmedBefore`: a plain
    /// view-model-owned `UserDefaults` key, confirmed once, ever, not a
    /// `FeatureFlags` entry (this isn't an on/off feature to gate).
    private static let hasConfirmedRenewKey = "DHCPRenewHasConfirmed"
    var hasConfirmedRenewBefore: Bool { UserDefaults.standard.bool(forKey: Self.hasConfirmedRenewKey) }
    func markRenewConfirmed() { UserDefaults.standard.set(true, forKey: Self.hasConfirmedRenewKey) }

    private let service = DHCPLeaseService()
    private let snapshotStore: SnapshotStore
    private weak var networkMonitor: NetworkMonitorViewModel?
    private var timer: Timer?
    private var isChecking = false

    /// In-memory transition trackers, same shape (and same
    /// relaunch-during-an-ongoing-condition caveat) as
    /// `ConnectivityViewModel.wasUnhealthy` — each logs only on the actual
    /// transition, not every poll while a condition continues.
    private var wasOverdue = false
    private var wasLinkLocal = false

    /// Purely local (no network I/O), so this could poll far more often
    /// than a real network check — 5 minutes is still cheap and frequent
    /// enough that Signal 2 can't lag reality by more than that.
    private static let checkInterval: TimeInterval = 300

    /// Fired when an `AppEventRecord` gets logged, so the event log view
    /// can refresh.
    var onEventLogged: (() -> Void)?

    init(snapshotStore: SnapshotStore, networkMonitor: NetworkMonitorViewModel) {
        self.snapshotStore = snapshotStore
        self.networkMonitor = networkMonitor
        history = snapshotStore.fetchDHCPLeaseHistory()
        timer = Timer.scheduledTimer(withTimeInterval: FailureInjector.acceleratedInterval(Self.checkInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.check()
            }
        }
        check()
    }

    // `deinit` is nonisolated even on a `@MainActor` class -- reading an
    // `@Observable`-tracked stored property from it needs
    // `MainActor.assumeIsolated`, safe here since every instance is only
    // ever created/held on the main actor (see `NMSApp`).
    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
        }
    }

    /// Re-reads the stored history for whatever network is now current.
    ///
    /// The fetch in `init` above runs before the first LAN scan has
    /// identified the network, so it queries with no fingerprint set and
    /// returns nothing; the only other refresh happens when a lease
    /// actually *changes*, which on a stable network can be a day away
    /// (`leaseSeconds` is typically 86400). Without this, real history
    /// stayed invisible for that whole time. Wired to
    /// `NetworkIdentityViewModel.onNetworkRecognized` — see that property
    /// for why this class of bug only became visible once the store
    /// started opening again.
    func reloadHistory() {
        history = snapshotStore.fetchDHCPLeaseHistory()
    }

    /// `ipconfig` blocks like the `ping`/`snmpget`/`arp` shell-outs
    /// elsewhere in this app, so it runs off the main thread even though
    /// it's local-only and normally fast.
    func check() {
        guard !isChecking else { return }
        guard let interface = networkMonitor?.currentInterface else { return }
        isChecking = true
        let interfaceName = interface.interfaceName
        let ipAddress = interface.ipAddress
        let service = self.service
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lease = service.currentLease(interface: interfaceName)
            Task { @MainActor [weak self] in
                self?.apply(lease, checkedInterfaceName: interfaceName, currentIPAddress: ipAddress)
            }
        }
    }

    /// User-triggered only — never called from the poll timer. Forces a
    /// fresh DHCP negotiation via `DHCPLeaseService.renew`, which briefly
    /// disrupts the connection and (for anything but a fully local admin
    /// session) surfaces macOS's own administrator-authorization dialog.
    /// Callers are responsible for getting explicit confirmation first —
    /// see `hasConfirmedRenewBefore`/`markRenewConfirmed` above — this
    /// makes no attempt to gate that itself.
    ///
    /// No separate event-log entry for the renewal itself: a genuinely
    /// new lease always gets a fresh transaction ID, which
    /// `SnapshotStore.recordDHCPLeaseIfChanged` already turns into a new
    /// `DHCPLeaseRecord` row on its own (see that type's doc comment), so
    /// the renewal is already visible in DHCP History without a second,
    /// redundant announcement.
    func renew() {
        guard !isRenewing else { return }
        guard let interface = networkMonitor?.currentInterface else { return }
        isRenewing = true
        let interfaceName = interface.interfaceName
        let service = self.service
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = service.renew(interface: interfaceName)
            Task { @MainActor [weak self] in
                self?.isRenewing = false
                self?.check()
            }
        }
    }

    private func apply(_ lease: DHCPLeaseInfo?, checkedInterfaceName: String, currentIPAddress: String?) {
        isChecking = false
        checkLinkLocalFallback(currentIPAddress: currentIPAddress)

        // The interface can change while a check is still in flight —
        // `check()` runs off the main thread, and `ipconfig getpacket`,
        // while normally fast, is still a real subprocess round-trip.
        // Confirmed live: switching from Ethernet to Wi-Fi produced a
        // completed check for the now-departed `en0` 40ms *after*
        // `currentInterface` had already moved on to `en1`. Harmless on
        // a single clean transition (a fresh check for the new interface
        // fires right after and lands normally), but on a genuinely
        // flaky network with rapid repeated flaps — confirmed to happen
        // in the field, see BUGS.md's NAT-layer flapping bug from the
        // same field-testing session — every check could plausibly keep
        // racing against an interface that's already stale by the time
        // it lands, with none of them ever catching up to report the
        // *current* one. That's a real candidate for "Not checked"
        // persisting for minutes with no single failure to point at.
        // Retriggering immediately here, rather than waiting out
        // whatever's left of the 300s timer, is the actual fix for that.
        let isStale = checkedInterfaceName != networkMonitor?.currentInterface?.interfaceName
        defer { if isStale { check() } }

        // `nil` covers every "not applicable" case (static config, no
        // lease, interface gone) alike — nothing to persist or compare,
        // and the last known lease is left displayed rather than cleared,
        // matching how `PublicIPViewModel` keeps showing the last known
        // address through a transient interface hiccup.
        guard let lease else {
            // `DHCPLeaseService.currentLease` already logs *why* the
            // subprocess-level read came back empty; this adds the
            // surrounding app-level state at that same moment (is a
            // network even recognized yet? was this check even for the
            // interface that's still current?) -- together, enough to
            // reconstruct a real occurrence from `ui-state.log` instead
            // of guessing, the same way the NAT-layer flapping bug in
            // BUGS.md was diagnosed. Added after "Not checked" was
            // reported persisting for minutes on real field-tested
            // networks with no prior instrumentation to explain why.
            UIStateLogger.log(
                "DHCPLeaseViewModel.apply",
                "no lease; currentNetworkFingerprint=\(snapshotStore.currentNetworkFingerprint ?? "nil") checkedInterface=\(checkedInterfaceName) currentInterface=\(networkMonitor?.currentInterface?.interfaceName ?? "nil") stale=\(isStale)"
            )
            return
        }

        // Captured before the insert below, so it's the lease this poll is
        // being compared *against* — `recordDHCPLeaseIfChanged` would
        // otherwise already have replaced it. Scoped to this same
        // interface (not `snapshotStore.latestDHCPLease()`'s plain
        // "whatever's most recent") — see `latestDHCPLease(forInterface:)`'s
        // own doc comment for the real bug that fixes on a Mac running
        // both Ethernet and Wi-Fi at once.
        let previous = snapshotStore.latestDHCPLease(forInterface: checkedInterfaceName)

        let (changed, isFirstEver) = snapshotStore.recordDHCPLeaseIfChanged(lease)
        if changed {
            // Only re-queried on an actual change, not every poll — mirrors
            // `SNMPViewModel.onDeviceListChanged`'s reasoning: refetching
            // unconditionally would just repeat the same query every 5
            // minutes for a list that usually hasn't moved.
            history = snapshotStore.fetchDHCPLeaseHistory()
            // A fresh transaction ID alone isn't newsworthy — routine
            // renewals get a new one every time even when nothing else
            // moved, and logging one of those as "changed" would be exactly
            // the false-alarm-on-a-healthy-renewal problem Signal 2 already
            // takes care to avoid. Only fields that actually differ from
            // the previous lease make it into the message, and if none do,
            // no event fires at all.
            if let previous, !isFirstEver {
                let changes = Self.fieldChanges(from: previous, to: lease)
                if !changes.isEmpty {
                    snapshotStore.logEvent(.dhcpLeaseChanged, message: "DHCP lease changed: \(changes.joined(separator: ", "))")
                    onEventLogged?()
                    // See this property's own doc comment: the narrower
                    // signal `DHCPStatusRow`'s yellow needs, distinct
                    // from "a new record exists."
                    lastGenuineChangeAt = lease.checkedAt
                }
            }
        }
        checkRenewalOverdue()
    }

    /// Not `private` — `NMSTests` reaches this directly via `@testable
    /// import`, same reasoning as `TracerouteViewModel`'s many
    /// `nonisolated static` helpers: pure comparison logic (no
    /// MainActor-only state touched), directly testable without a live
    /// view model. `nonisolated` for the same reason those are.
    ///
    /// Every *substantive* field that differs between the previous lease
    /// and this one, as "`label` old → new" strings — the point (per the
    /// scenario this was built for: spotting a change someone *else* made
    /// to the network, like an admin editing the DHCP scope) is knowing
    /// exactly what changed, not just that something did. Two fields are
    /// deliberately excluded, both for the same reason: they tick on
    /// their own during a perfectly routine renewal, not because anything
    /// about the lease actually changed. The transaction ID is excluded —
    /// it changes on every renewal by protocol definition. T1/T2 are
    /// excluded too — confirmed live (2026-08-07/08): this router hands
    /// back a slightly different T1/T2 on essentially every renewal (the
    /// same address/gateway/DNS/lease duration throughout, exacerbated
    /// that session by real Wi-Fi/Ethernet interface flapping), which was
    /// firing `lastGenuineChangeAt`/`DHCPStatusRow`'s yellow "Changed
    /// recently" and logging a "DHCP lease changed" event on almost every
    /// renewal — exactly the false-alarm-on-a-healthy-renewal problem this
    /// function's callers exist to avoid. `leaseSeconds` (the actual
    /// granted lease duration) stays in the comparison — unlike T1/T2 it
    /// doesn't drift renewal to renewal on its own, so a real difference
    /// there means the server's lease policy itself changed.
    nonisolated static func fieldChanges(from previous: DHCPLeaseRecord, to lease: DHCPLeaseInfo) -> [String] {
        var changes: [String] = []
        if previous.serverIdentifier != lease.serverIdentifier {
            changes.append("server \(previous.serverIdentifier) → \(lease.serverIdentifier)")
        }
        if previous.assignedAddress != lease.assignedAddress {
            changes.append("address \(previous.assignedAddress) → \(lease.assignedAddress)")
        }
        if previous.subnetMask != lease.subnetMask {
            changes.append("subnet mask \(previous.subnetMask ?? "—") → \(lease.subnetMask ?? "—")")
        }
        if previous.broadcastAddress != lease.broadcastAddress {
            changes.append("broadcast \(previous.broadcastAddress ?? "—") → \(lease.broadcastAddress ?? "—")")
        }
        if previous.router != lease.router {
            changes.append("gateway \(previous.router ?? "—") → \(lease.router ?? "—")")
        }
        if previous.dnsServers != lease.dnsServers {
            changes.append("DNS \(previous.dnsServers.joined(separator: ",")) → \(lease.dnsServers.joined(separator: ","))")
        }
        if previous.domainName != lease.domainName {
            changes.append("domain \(previous.domainName ?? "—") → \(lease.domainName ?? "—")")
        }
        if previous.leaseSeconds != lease.leaseSeconds {
            changes.append("lease \(DHCPLeaseInfo.durationText(previous.leaseSeconds)) → \(DHCPLeaseInfo.durationText(lease.leaseSeconds))")
        }
        return changes
    }

    private func checkLinkLocalFallback(currentIPAddress: String?) {
        // `||` rather than a replacement, so injection can only ever
        // *add* a failure — a real APIPA fallback is still reported while
        // the key is set, instead of being masked by it.
        let isLinkLocal = FailureInjector.isDHCPLinkLocalForced
            || (currentIPAddress.map(IPClassifier.isLinkLocal) ?? false)
        isFallenBackToLinkLocal = isLinkLocal
        defer { wasLinkLocal = isLinkLocal }
        guard isLinkLocal != wasLinkLocal else { return }
        if isLinkLocal {
            // Prefixed when forced, matching the connectivity and SNMP
            // events. Omitting it here was a real gap: injected DHCP
            // events landed in the store indistinguishable from genuine
            // ones, and had to be identified by cross-referencing the
            // time they were run against a terminal scrollback before
            // they could be cleaned up.
            let prefix = FailureInjector.isDHCPLinkLocalForced ? "[injected] " : ""
            snapshotStore.logEvent(
                .dhcpFellBackToLinkLocal,
                message: "\(prefix)Interface fell back to a self-assigned address"
            )
        } else {
            snapshotStore.logEvent(.dhcpAddressRestored, message: "DHCP address restored")
        }
        onEventLogged?()
    }

    /// The client should have started rebinding by T2 and hasn't. Reads
    /// straight from the persisted record rather than in-memory state, so
    /// a renewal that succeeds on schedule resets this deadline (via a
    /// fresh `firstObservedAt`) before it's ever reached — no false alarms
    /// for healthy renewals.
    private func checkRenewalOverdue() {
        guard let record = snapshotStore.latestDHCPLease() else { return }
        let expectedT2At = record.firstObservedAt.addingTimeInterval(TimeInterval(record.t2Seconds))
        // Same additive shape as the link-local hook above: injection can
        // force an overdue renewal but never suppress a genuine one.
        let isOverdue = FailureInjector.isDHCPRenewalOverdueForced || Date() > expectedT2At
        isRenewalOverdue = isOverdue
        defer { wasOverdue = isOverdue }
        guard isOverdue != wasOverdue else { return }
        if isOverdue {
            let prefix = FailureInjector.isDHCPRenewalOverdueForced ? "[injected] " : ""
            snapshotStore.logEvent(.dhcpRenewalOverdue, message: "\(prefix)DHCP renewal overdue")
        } else {
            snapshotStore.logEvent(.dhcpRenewalRecovered, message: "DHCP lease renewed")
        }
        onEventLogged?()
    }
}
