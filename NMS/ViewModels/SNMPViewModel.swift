import Foundation
import Combine

@MainActor
final class SNMPViewModel: ObservableObject {
    @Published private(set) var devices: [SNMPDevice] = [] {
        didSet {
            UIStateLogger.log("SNMPViewModel.devices", devices)
            // Compared on ping-target identity rather than with `!=`, because
            // a plain equality check would fire on *every* poll: `uptimeTicks`
            // and `polledAt` change each time by design, so whole-value
            // inequality says nothing about whether the targets moved.
            let identity = Self.targetIdentity(devices)
            if identity != Self.targetIdentity(oldValue) {
                onDeviceListChanged?()
            }
        }
    }

    /// What `ConnectivityViewModel.buildTargets` actually consumes from a
    /// device: the address it pings and the label it files the result under.
    /// Everything else can change without affecting the target list.
    private static func targetIdentity(_ devices: [SNMPDevice]) -> [String] {
        devices.map { "\($0.ipAddress)|\($0.displayName)" }
    }
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?
    /// Read-only community strings, tried in order. `public` is the
    /// near-universal default; a list is supported because real networks
    /// routinely mix vendors or eras of gear with different strings.
    /// Editable in the popover, stored in `UserDefaults` alongside the
    /// monitored-hop setting — see the README's note on why these are
    /// deliberately not treated as Keychain-grade secrets.
    @Published private(set) var communities: [String]

    private let service = SNMPService()
    private let webDetectionService = DeviceWebDetectionService()
    private let reverseDNSService = ReverseDNSService()
    /// Only ever holds a *confirmed* result — an address stays absent
    /// (and so keeps getting retried on the next poll, via
    /// `detectWebServers`'s `newAddresses` filter) until a probe actually
    /// succeeds. Deliberately not "probed once, done regardless of
    /// outcome": confirmed live that a probe landing mid-flap on this
    /// network's own well-documented Wi-Fi/Ethernet instability can fail
    /// all five devices in one round with nothing wrong with any of
    /// them — caching that failure permanently would have been a
    /// standing false negative, not the "once, at first discovery"
    /// cadence `PUNCHLIST.md`'s "SNMP Devices: detect a web server" item
    /// actually intended (avoid re-probing a device whose answer is
    /// *known*, not give up after one unlucky round). A device that
    /// genuinely has no web server does get retried every poll
    /// indefinitely as a result — accepted, since each attempt is a
    /// handful of fast LAN connection attempts, not a real ongoing cost.
    ///
    /// Seeded from `SNMPDeviceRecord.webURL` at `activate()` — a device
    /// confirmed in an earlier session isn't re-probed just because this
    /// particular `SNMPViewModel` instance's own cache starts empty.
    private var webURLByAddress: [String: String] = [:]
    /// Same shape and reasoning as `webURLByAddress`, for
    /// `enrichHostnames`'s reverse-DNS lookups instead of the web
    /// probe — an address with no PTR record just gets retried every
    /// poll rather than caching a permanent "no hostname."
    private var hostnameByAddress: [String: String] = [:]
    /// Which network's fingerprint the two caches above were last built
    /// against — see `rebuildDeviceList()`'s use of this. Both caches are
    /// keyed by bare IP address with no network component, which is a
    /// real problem the moment two networks share a common private
    /// address (a router or printer at `192.168.1.1`/`.254` on both):
    /// reported directly from offsite testing as an old network's printer
    /// info showing up on a new one. `rebuildDeviceList()`'s patch loop
    /// reads these caches by address alone and overwrites whatever
    /// `Self.device(from:)` just read from the newly-fetched, correctly
    /// fingerprint-scoped persisted record — so a stale entry here for a
    /// reused address clobbers the *new* network's own genuinely-correct
    /// `webURL`/`hostname` with the *old* network's value for that same
    /// address. `nil` until the first successful rebuild.
    private var lastFingerprintForCaches: String?
    private let snapshotStore: SnapshotStore
    private weak var networkMonitor: NetworkMonitorViewModel?
    private weak var lanDiscovery: LANDiscoveryViewModel?
    private weak var traceroute: TracerouteViewModel?
    private var timer: Timer?
    /// So `observeFeatureFlagChanges` can tell a real flip of
    /// `FeatureFlags.snmpDevices` from `UserDefaults.didChangeNotification`
    /// firing for an unrelated key — that notification carries no
    /// information about *which* key changed, so this is compared against
    /// the flag's current value on every post rather than trusted alone.
    private var isActive = false
    private var featureFlagObserver: NSObjectProtocol?

    private static let communitiesDefaultsKey = "NMS.snmpCommunities"
    /// Superseded by `communitiesDefaultsKey`; still read once so an
    /// existing single-string setting carries over instead of silently
    /// reverting to the default.
    private static let legacyCommunityDefaultsKey = "NMS.snmpCommunity"
    private static let defaultCommunity = "public"

    /// Re-polls *already-discovered* devices for uptime/descriptor changes.
    /// Much lighter than discovery (a handful of known-responsive hosts, not
    /// a whole subnet), but still far heavier than a ping, so it sits
    /// between the two: reachability is what the fast connectivity cadence
    /// watches, this is what notices a restart or an upgrade.
    private static let pollInterval: TimeInterval = 60

    /// Bounds how often a missing ARP entry can trigger a LAN rescan —
    /// see `refreshARPIfMergeDataIsStale`, where it's what stops the
    /// `onScanCompleted` → `rebuildDeviceList` → scan cycle from looping.
    /// Matched to `pollInterval` because a poll is the other thing that
    /// rebuilds this list, so at worst one rescan per poll round.
    private static let macRefreshThrottle: TimeInterval = 60
    /// When the last such rescan was requested. `nil` until the first one.
    private var lastMACRefreshAt: Date?

    var isAvailable: Bool { SNMPService.isAvailable }

    /// Fired when an `AppEventRecord` gets logged (a device restarted or its
    /// software changed), so the event log view can refresh.
    var onEventLogged: (() -> Void)?

    /// Fired when the device list actually changes — these devices are the
    /// infrastructure ping targets in `ConnectivityViewModel.buildTargets`,
    /// which reads them as `snmp?.devices ?? []` and so silently monitors
    /// nothing when the list isn't ready yet.
    ///
    /// That is not hypothetical: `NMSApp` constructs `connectivity` before
    /// `snmp` and injects the back-reference afterward, so the first check
    /// round at launch runs with `snmp` still nil and pings no infrastructure
    /// at all. It recovered within ~500ms only because
    /// `traceroute.onTraceCompleted` happened to rebuild the target list
    /// shortly after — coincidental coupling, not a guarantee. Surfaced by
    /// the "unavailable: snmpDevices" line this logging now emits.
    ///
    /// Deliberately on *change*, not on every rebuild: `rebuildDeviceList()`
    /// runs after every 60s poll, and firing unconditionally would add a
    /// redundant check round every minute for a list that usually hasn't
    /// moved.
    var onDeviceListChanged: (() -> Void)?

    init(
        snapshotStore: SnapshotStore,
        networkMonitor: NetworkMonitorViewModel,
        lanDiscovery: LANDiscoveryViewModel,
        traceroute: TracerouteViewModel
    ) {
        self.snapshotStore = snapshotStore
        self.networkMonitor = networkMonitor
        self.lanDiscovery = lanDiscovery
        self.traceroute = traceroute
        let defaults = UserDefaults.standard
        if let stored = defaults.stringArray(forKey: Self.communitiesDefaultsKey), !stored.isEmpty {
            communities = stored
        } else if let legacy = defaults.string(forKey: Self.legacyCommunityDefaultsKey), !legacy.isEmpty {
            communities = [legacy]
        } else {
            communities = [Self.defaultCommunity]
        }
        // Gated by `FeatureFlags.snmpDevices` — off by default for a fresh
        // install, this view model stays fully inert: no rehydration, no
        // poll timer, `scan()`/`poll()` no-op. Not just a UI hide, since
        // this is active network probing (SNMP sweeps) against whatever
        // LAN the Mac is on, which a tester hasn't necessarily approved.
        if FeatureFlags.snmpDevices {
            activate()
        }
        observeFeatureFlagChanges()
    }

    deinit {
        timer?.invalidate()
        if let featureFlagObserver {
            NotificationCenter.default.removeObserver(featureFlagObserver)
        }
    }

    /// Everything `init()` used to do inline, gated on the flag being on —
    /// factored out so toggling the flag on live (see
    /// `observeFeatureFlagChanges`) can run the exact same startup
    /// sequence a fresh launch would, not a second, drifted copy of it.
    private func activate() {
        isActive = true
        // Rehydrate previously-discovered devices instead of sweeping at
        // launch. A full /24 sweep takes ~16s and forks up to 32 processes;
        // running that during startup — alongside the LAN scan, traceroute,
        // connectivity checks and location auth — is exactly the
        // launch-time contention that already produced an
        // intermittent-empty-results bug in Bonjour discovery (since
        // removed entirely; see DESIGN-NOTES.md's "mDNS/Bonjour" section),
        // back when that ran at launch too. Known devices show (and start
        // being polled and pinged) immediately; the sweep itself is on
        // demand via the popover's "Scan" button.
        //
        // Also correct for a *live* toggle, not just launch: if this is
        // running because the flag just flipped on mid-session rather than
        // at `init()`, `devices` is already empty (never populated while
        // off), so this rehydrates exactly the same way a fresh launch
        // would rather than needing a separate code path.
        devices = snapshotStore.fetchSNMPDevices().map(Self.device(from:))
        // Seeded from what's already confirmed on disk, so a device
        // whose web server was found in an earlier session isn't
        // needlessly re-probed this launch just because this fresh
        // `SNMPViewModel` instance's own cache starts empty — the
        // rehydrated `devices` above already carries the answer via
        // `Self.device(from:)`, this just lets `detectWebServers`'
        // `newAddresses` filter see it too.
        for device in devices {
            if let webURL = device.webURL {
                webURLByAddress[device.ipAddress] = webURL
            }
            if let hostname = device.hostname {
                hostnameByAddress[device.ipAddress] = hostname
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: FailureInjector.acceleratedInterval(Self.pollInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        // Rehydration above restores everything ever persisted, including
        // devices from networks since left — so filter immediately rather
        // than showing them until the first poll a minute later.
        //
        // This pass cannot do the MAC merge, and that's expected: it needs
        // ARP data, and `LANDiscoveryViewModel.scan()` is asynchronous, so
        // at this moment its device list is still empty. `NMSApp` calls
        // this again from `lanDiscovery.onScanCompleted`; without that the
        // merge wouldn't happen until the first poll 60s later — observed
        // directly in the log, `arp -n -a` starting 1ms *after* this ran.
        rebuildDeviceList()

        // Nothing to rehydrate — either the very first time this feature
        // has ever been turned on, or the persisted store was wiped —
        // means there's also nothing for `poll()`'s timer above to ever
        // poll: without this, a first-time user would see an empty list
        // forever unless they separately found and clicked the manual
        // "Scan" button. This is the one case worth the launch-time-
        // contention risk the doc comment above warns about (a one-time
        // cost on first activation, not a recurring one — every later
        // launch already has something to rehydrate). A network already
        // fully explored keeps today's behavior exactly: rehydrate + poll,
        // no automatic sweep.
        if devices.isEmpty {
            scan()
        }
    }

    /// The flag flipping off live, mirroring `activate()`. Stops the timer
    /// — no further probing, the actual safety property the flag exists
    /// for — but deliberately leaves `devices` as-is rather than clearing
    /// it: those were legitimately discovered while the feature was on,
    /// and blanking the list the instant someone unchecks a box reads as
    /// data loss, not as the feature turning off. `scan()`/`poll()` both
    /// already re-check the flag themselves regardless of `isActive`, so
    /// this isn't the only thing standing between the flag and a stray
    /// probe — belt and suspenders, same as everywhere else in this file.
    private func deactivate() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }

    /// `UserDefaults.didChangeNotification` carries no information about
    /// *which* key changed — it fires for any write to any default — so
    /// every post is checked against `isActive` to detect an actual flip
    /// of `FeatureFlags.snmpDevices` specifically, not assumed to mean
    /// this one did. `[weak self]` avoids a retain cycle through
    /// `NotificationCenter`'s own strong hold on the observer token;
    /// `deinit` removes the token itself, since a weak closure alone
    /// doesn't stop the center from calling into a dead observer's slot.
    private func observeFeatureFlagChanges() {
        featureFlagObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let shouldBeActive = FeatureFlags.snmpDevices
            if shouldBeActive, !self.isActive {
                self.activate()
            } else if !shouldBeActive, self.isActive {
                self.deactivate()
            }
        }
    }

    /// Accepts a comma-separated list. Order is preserved and meaningful:
    /// strings are tried in sequence, and each one ahead of the correct one
    /// costs a full timeout on silent hosts, so the most widely-used string
    /// belongs first. Duplicates and blanks are dropped; an entirely empty
    /// input falls back to the default rather than leaving nothing to try.
    func setCommunities(_ value: String) {
        var seen: Set<String> = []
        let parsed = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let resolved = parsed.isEmpty ? [Self.defaultCommunity] : parsed
        guard resolved != communities else { return }
        communities = resolved
        UserDefaults.standard.set(resolved, forKey: Self.communitiesDefaultsKey)
        // Previously-discovered devices were found using the old strings and
        // may not answer under the new ones (and vice versa), so the current
        // list is no longer trustworthy — rediscover from scratch. `scan()`
        // itself now clears both the in-memory list and persisted history
        // before sweeping, so nothing further is needed here.
        scan()
    }

    /// Full discovery: sweeps the local subnet plus every address the app
    /// already knows about. The sweep is the expensive part (up to ~16s for
    /// a /24, mostly waiting out silent hosts), so this is launch/manual
    /// only — never tied to topology changes the way the near-instant ARP
    /// scan is.
    ///
    /// A genuine clear-and-rediscover, not just a fresh in-memory list:
    /// persisted history is wiped first (see
    /// `SnapshotStore.deleteAllSNMPDevices`), so a device no longer present
    /// (e.g. after a topology change) doesn't linger and reappear on next
    /// launch. Real cost, accepted since this only runs on an explicit,
    /// manual click: any device still around gets a fresh `firstSeenAt`
    /// instead of keeping its actual history.
    func scan() {
        guard FeatureFlags.snmpDevices else { return }
        guard !isScanning else { return }
        guard SNMPService.isAvailable else {
            lastError = "snmpget not found — SNMP discovery unavailable on this macOS version."
            return
        }

        let candidates = candidateAddresses()
        guard !candidates.isEmpty else { return }

        snapshotStore.deleteAllSNMPDevices()
        devices = []
        isScanning = true
        lastError = nil
        let service = self.service
        // Discovery is the one place every configured string gets tried,
        // since which (if any) a given address answers on is exactly what's
        // unknown here.
        let communities = self.communities
        let targets = candidates.map { SNMPService.SweepTarget(ipAddress: $0, communities: communities) }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = service.sweep(targets: targets)
            Task { @MainActor [weak self] in
                self?.apply(found, isFullScan: true)
            }
        }
    }

    /// Re-polls only the devices already known to speak SNMP — no sweep.
    func poll() {
        guard !isScanning, !devices.isEmpty, SNMPService.isAvailable else { return }

        isScanning = true
        let service = self.service
        // Each known device is queried only on the string it actually
        // answered on — retrying the others every 60s would achieve
        // nothing except filling that device's log with
        // `authenticationFailure` entries.
        let targets = devices.map { SNMPService.SweepTarget(ipAddress: $0.ipAddress, communities: [$0.community]) }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = service.sweep(targets: targets)
            Task { @MainActor [weak self] in
                self?.apply(found, isFullScan: false)
            }
        }
    }

    /// On a re-poll (not a full scan), devices that didn't answer are kept
    /// in the list rather than dropped: SNMP not answering once is much more
    /// likely to be a dropped UDP packet or a busy agent than the device
    /// having vanished, and reachability is already tracked properly by the
    /// ping checks in `ConnectivityViewModel`.
    private func apply(_ found: [SNMPDevice], isFullScan: Bool) {
        // Injected before the change detection below sees them, so
        // `recordSNMPDevice`'s real uptime/descriptor comparison runs
        // rather than being bypassed. No-op unless a debug defaults key
        // is set; see `FailureInjector`.
        let found = FailureInjector.applySNMPChanges(to: found)
        isScanning = false
        lastScanAt = Date()
        defer { rebuildDeviceList() }

        if isFullScan {
            devices = found
        } else {
            // `uniquingKeysWith:`, not `uniqueKeysWithValues:` — the latter
            // *traps* on a duplicate address, and it did: duplicate
            // `SNMPDeviceRecord` rows (see
            // `SnapshotStore.adoptUntaggedRecords`) reached here through
            // `mergingSharedMACs`' `unknownMAC` bucket and crashed the app
            // outright. That root cause is fixed, but a list this far
            // downstream has no business asserting an invariant three
            // layers up: keeping the fresher of the two is a correct answer
            // for *any* duplicate, whatever produced it, and a stale row
            // surviving is not worth a SIGILL.
            var byAddress = Dictionary(devices.map { ($0.ipAddress, $0) }) { older, newer in
                older.polledAt >= newer.polledAt ? older : newer
            }
            for device in found {
                byAddress[device.ipAddress] = device
            }
            devices = byAddress.values.sorted {
                (SubnetCalculator.packedIPv4($0.ipAddress) ?? 0) < (SubnetCalculator.packedIPv4($1.ipAddress) ?? 0)
            }
        }

        // Once, at first discovery — not every poll. See
        // `webURLByAddress`'s own doc comment for the accepted staleness
        // tradeoff this implies. Computed separately from the hostname
        // one below — a device can have one confirmed without the other
        // (e.g. a real web server but no PTR record, or vice versa).
        let addressesNeedingWebProbe = devices.map(\.ipAddress).filter { webURLByAddress[$0] == nil }
        if !addressesNeedingWebProbe.isEmpty {
            detectWebServers(for: addressesNeedingWebProbe)
        }
        let addressesNeedingHostname = devices.map(\.ipAddress).filter { hostnameByAddress[$0] == nil }
        if !addressesNeedingHostname.isEmpty {
            enrichHostnames(for: addressesNeedingHostname)
        }

        var loggedAny = false
        for device in found {
            switch snapshotStore.recordSNMPDevice(device) {
            case .firstSeen, .unchanged:
                // Deliberately no "discovered" event — the first sweep would
                // log one per device and flood a 10-row event list with
                // things that aren't changes.
                break
            case .restarted:
                // Prefixed when forced, so a test never reads as a real
                // device reboot months later — same convention as the
                // connectivity events. Empty in every normal case.
                let prefix = FailureInjector.isSNMPForced(device.displayName) ? "[injected] " : ""
                snapshotStore.logEvent(
                    .snmpDeviceRestarted,
                    message: "\(prefix)\(device.displayName) restarted unexpectedly"
                )
                loggedAny = true
            case let .softwareChanged(previousDescr, restarted):
                let prefix = FailureInjector.isSNMPForced(device.displayName) ? "[injected] " : ""
                let verb = restarted ? "restarted after software change" : "software changed"
                snapshotStore.logEvent(
                    .snmpDeviceSoftwareChanged,
                    message: "\(prefix)\(device.displayName) \(verb): \(previousDescr) → \(device.sysDescr)"
                )
                loggedAny = true
            }
        }
        if loggedAny {
            onEventLogged?()
        }
    }

    /// Probes every newly-seen address concurrently — same `withTaskGroup`
    /// shape `SaaSMonitoringViewModel.checkAll()`/`ConnectivityService
    /// .check(targets:)` already use, so N probes are bounded by the
    /// slowest one, not their sum. No explicit `@MainActor` hop needed
    /// inside — this type is itself `@MainActor`, so a plain (non-detached)
    /// `Task {}` created from one of its methods inherits that isolation,
    /// same as `PublicIPViewModel.check()`'s own `Task {}`.
    private func detectWebServers(for addresses: [String]) {
        let service = webDetectionService
        Task {
            await withTaskGroup(of: (address: String, url: String?).self) { group in
                for address in addresses {
                    group.addTask { (address, await service.detectWebURL(forAddress: address)) }
                }
                for await result in group {
                    // Only a *successful* probe is cached permanently — a
                    // `nil` here means "couldn't reach it this round,"
                    // which on this network in particular can just mean
                    // the probe landed mid-flap (confirmed live: all five
                    // devices came back nil once, exactly coinciding with
                    // an `interfaceChanged` event, and none ever retried
                    // since — a real bug, not a genuine "no web server").
                    // Leaving the address absent from `webURLByAddress`
                    // means the next poll's `newAddresses` filter picks it
                    // back up automatically; only a real success stops
                    // this permanently, matching "once, at first
                    // discovery" 's actual intent (don't keep re-probing a
                    // device once its answer is known) rather than its
                    // literal first implementation (don't keep probing a
                    // device once *anything* comes back, transient
                    // failure included).
                    if let url = result.url {
                        webURLByAddress[result.address] = url
                        // Persisted so the link shows immediately on the
                        // *next* launch instead of waiting out a fresh
                        // probe every time — see `SNMPDeviceRecord.webURL`.
                        snapshotStore.updateSNMPDeviceWebURL(address: result.address, url: url)
                    }
                    // Guards against a device having been removed by a
                    // subsequent full rescan while this probe was in
                    // flight — same staleness guard
                    // `TracerouteViewModel.enrichHostnames` already uses
                    // for its own post-hoc per-item enrichment.
                    if let index = devices.firstIndex(where: { $0.ipAddress == result.address }) {
                        devices[index].webURL = result.url
                    }
                }
            }
        }
    }

    /// Reverse-DNS enrichment for newly-seen addresses — same shape as
    /// `TracerouteViewModel.enrichHostnames`, which this mirrors almost
    /// exactly: `ReverseDNSService.hostname(for:)` is a blocking POSIX
    /// call bounded by its own internal timeout, so it's dispatched onto
    /// `DispatchQueue.global` rather than awaited directly, then hops
    /// back to the main actor to patch results in. Requested directly —
    /// "list the domain name and IP address for each" — useful for a
    /// network engineer correlating a device's actual DNS identity
    /// against its SNMP-reported `sysName`, which is often just a short
    /// local label ("router") rather than a real hostname.
    private func enrichHostnames(for addresses: [String]) {
        let service = reverseDNSService
        for address in addresses {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let hostname = service.hostname(for: address) else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.hostnameByAddress[address] = hostname
                    // Persisted so the domain name shows immediately on
                    // the next launch instead of waiting out a fresh
                    // lookup every time — see `SNMPDeviceRecord.hostname`.
                    self.snapshotStore.updateSNMPDeviceHostname(address: address, hostname: hostname)
                    // Same staleness guard `detectWebServers` above uses —
                    // a device may have been removed by a subsequent full
                    // rescan while this lookup was in flight.
                    if let index = self.devices.firstIndex(where: { $0.ipAddress == address }) {
                        self.devices[index].hostname = hostname
                    }
                }
            }
        }
    }

    /// Drops devices belonging to a network that's no longer attached, and
    /// deletes their persisted rows so they don't return on next launch.
    /// The concrete case: joining a guest SSID discovers its gateway
    /// (`10.0.102.1`), and switching back to the main LAN left that entry
    /// listed indefinitely — the same router already listed at `10.0.0.1`,
    /// showing up twice. Re-polls deliberately keep devices that don't
    /// answer (a missed SNMP reply is usually a dropped packet, not a
    /// vanished device), which is right for a device that's still on this
    /// network and wrong for one that never will be again; only the manual
    /// "Scan" cleared them, and only by clearing everything.
    ///
    /// Two independent reasons to keep a device, because pruning
    /// automatically is far worse to get wrong than leaving a stale row:
    /// it's on the current subnet, or it's an address the next sweep would
    /// probe anyway (`candidateAddresses` — redundant with the subnet test
    /// in the common case, but not when the subnet is too large to sweep
    /// safely and `candidateAddresses` falls back to just the gateway).
    /// Anything the subnet test can't parse counts as "can't tell" and is
    /// kept. Note this
    /// deliberately does *not* address a single device answering at two
    /// addresses on the *same* subnet — AP1 at `.16`/`.17` under VRRP stays
    /// listed twice; see `DESIGN-NOTES.md`.
    /// Callable from `NMSApp` so a completed LAN scan can trigger it — the
    /// MAC merge depends on ARP data this cannot produce itself.
    func rebuildDeviceList() {
        guard
            let info = networkMonitor?.currentInterface,
            let localIP = info.ipAddress,
            let mask = info.subnetMask
        else {
            // Silent no-op otherwise: the list simply keeps whatever it had,
            // which looks identical to "nothing needed changing".
            UIStateLogger.log("SNMPViewModel.rebuildDeviceList", "skipped — no current interface")
            return
        }

        // Clear the address-keyed caches the moment the recognized network
        // actually changes — see `lastFingerprintForCaches`'s doc comment
        // for the cross-network collision this prevents. Only acts on a
        // *resolved* fingerprint change (`if let`): while recognition is
        // still pending after a topology change, `currentNetworkFingerprint`
        // is momentarily `nil` and `fetchSNMPDevices()` already returns
        // nothing for it, so there's nothing yet for a stale cache entry to
        // corrupt — clearing waits for the new network to actually be known
        // rather than firing on every transient `nil`.
        if let fingerprint = snapshotStore.currentNetworkFingerprint, fingerprint != lastFingerprintForCaches {
            webURLByAddress.removeAll()
            hostnameByAddress.removeAll()
            lastFingerprintForCaches = fingerprint
            logIfSubnetTooLargeToScan(localIP: localIP, mask: mask, fingerprint: fingerprint)
        }

        let probeable = Set(candidateAddresses())
        // Rebuilt from the store rather than filtered in place, and nothing
        // is deleted. The first cut deleted the rows, which was actively
        // destructive: joining a guest SSID makes *every* main-LAN device
        // off-subnet at once, so a brief visit to the guest network wiped
        // the entire inventory permanently — recoverable only by a manual
        // Scan from the main network. Re-reading the persisted set here
        // means leaving a network hides its devices and returning brings
        // them straight back. `apply` upserts every polled device before
        // this runs, so the store is never staler than memory.
        let kept = snapshotStore.fetchSNMPDevices()
            .map(Self.device(from:))
            .filter { device in
                if probeable.contains(device.ipAddress) { return true }
                // `nil` (unparseable) means "can't tell", which keeps it —
                // only a definite `false` hides a device.
                return SubnetCalculator.isOnSameSubnet(device.ipAddress, as: localIP, subnetMask: mask) != false
            }
        let macs = macByAddress()
        var rebuilt = Self.mergingSharedMACs(kept, macByAddress: macs)
            .sorted {
                (SubnetCalculator.packedIPv4($0.ipAddress) ?? 0) < (SubnetCalculator.packedIPv4($1.ipAddress) ?? 0)
            }
        // `Self.device(from:)` above already reads `webURL` from the
        // persisted record (`kept`), so a value confirmed in an *earlier*
        // session already survives this rebuild on its own. This loop is
        // only for a value confirmed *this* session, possibly moments
        // ago: `detectWebServers` patches `devices` directly, in memory,
        // and this function reconstructs `devices` from scratch after
        // *every* `apply()` (via its `defer`) and every completed LAN
        // scan — without checking the cache too, that patch would be
        // silently wiped the next time this ran, before the persisted
        // write even lands. Only overwrite when the cache actually has
        // something newer; an address it hasn't (re)confirmed yet keeps
        // whatever the persisted record already said, rather than being
        // blanked out just because this session hasn't touched it.
        for index in rebuilt.indices {
            if let cached = webURLByAddress[rebuilt[index].ipAddress] {
                rebuilt[index].webURL = cached
            }
            if let cached = hostnameByAddress[rebuilt[index].ipAddress] {
                rebuilt[index].hostname = cached
            }
        }
        devices = rebuilt
        refreshARPIfMergeDataIsStale(kept: kept, macs: macs, localIP: localIP, mask: mask)
        // Keeps every alias row's persisted state as fresh as its primary
        // — see `SnapshotStore.syncAliasFreshness`. Runs on every rebuild
        // (after each poll, each scan, and each completed LAN scan), which
        // is exactly as often as the primary's own row can have changed.
        for device in devices where !device.aliasAddresses.isEmpty {
            snapshotStore.syncAliasFreshness(primary: device)
        }
        logUnavailableInputs(macCount: macs.count, keptCount: kept.count)
    }

    /// Re-runs the LAN scan when a device we can reach over SNMP has no
    /// ARP entry in our own cached copy — the condition that silently
    /// breaks the shared-MAC merge.
    ///
    /// Observed for real: after a Wi-Fi reconnect, a LAN scan landed
    /// before the OS had ARP-resolved `10.0.0.17`, so `macByAddress()`
    /// knew `.16` but not `.17` and AP1 rendered as two rows. The live
    /// system `arp -n -a` had both, with the same MAC — only our cached
    /// copy was short. Nothing re-triggered a scan, so it stayed wrong
    /// until the next topology change or relaunch.
    ///
    /// `logUnavailableInputs` below couldn't catch this: it only fires
    /// when the ARP table is *entirely* empty, and this is the partial
    /// case, which is both more common and more confusing to look at.
    ///
    /// **Scoped to same-subnet devices only.** An off-subnet device (an
    /// off-subnet router, a local traceroute hop) legitimately never
    /// appears in ARP, so treating its absence as staleness would rescan
    /// forever. An on-subnet device is different: we just polled it over
    /// SNMP, so the OS must have resolved its MAC to send those packets
    /// — if our copy lacks it, our copy is stale, not the network.
    ///
    /// **Throttled, and that's load-bearing rather than defensive.**
    /// `NMSApp` wires `lanDiscovery.onScanCompleted` straight back to
    /// `rebuildDeviceList()`, so an unthrottled rescan here would loop:
    /// rebuild → scan → rebuild → scan. The throttle bounds it to one
    /// attempt per interval, which terminates even when a device
    /// genuinely never shows up in ARP.
    private func refreshARPIfMergeDataIsStale(
        kept: [SNMPDevice],
        macs: [String: String],
        localIP: String,
        mask: String
    ) {
        let missing = kept.filter { device in
            guard macs[device.ipAddress] == nil else { return false }
            // Strictly `true` — `nil` means "couldn't parse", which is not
            // evidence of anything and must not trigger a rescan.
            return SubnetCalculator.isOnSameSubnet(device.ipAddress, as: localIP, subnetMask: mask) == true
        }
        guard !missing.isEmpty else { return }

        // A scan already running will finish and call `rebuildDeviceList`
        // again through `onScanCompleted`, so requesting another would be
        // dropped by `LANDiscoveryViewModel.scan`'s own `guard
        // !isScanning` anyway. Returning *before* touching the throttle is
        // the point: spending it here would burn the one attempt per
        // interval on a request that never ran, leaving a genuine
        // staleness moments later with nothing left to trigger a refresh.
        //
        // Note this does *not* fire at launch, which was the first guess:
        // traced directly, `SNMPViewModel.init` calls `rebuildDeviceList`
        // *before* `NMSApp` gets to `lanDiscovery.scan()`, so `isScanning`
        // is still false here and this path legitimately initiates the
        // launch scan itself — `NMSApp`'s later call is the one dropped.
        // One `arp` run either way; the throttle is spent on a scan that
        // really happened, which is correct. This guard is for the
        // genuinely concurrent cases (a topology change or manual Scan
        // already in flight).
        guard lanDiscovery?.isScanning != true else { return }

        if let lastMACRefreshAt, Date().timeIntervalSince(lastMACRefreshAt) < Self.macRefreshThrottle {
            return
        }
        lastMACRefreshAt = Date()
        UIStateLogger.log(
            "SNMPViewModel.rebuildDeviceList",
            "no ARP entry for \(missing.map(\.ipAddress).sorted().joined(separator: ", ")) — rescanning to refresh merge data"
        )
        lanDiscovery?.scan()
    }

    /// Records when the merge ran without the ARP data it depends on. That
    /// read is `lanDiscovery?.devices ?? []`, so an empty table isn't an
    /// error — it just means no addresses get merged, silently, and the
    /// duplicate stays visible until something recomputes this later. It is
    /// exactly how the AP1 `.16`/`.17` merge failed to land for 60 seconds at
    /// launch while looking entirely healthy.
    ///
    /// Only logged when the ARP table is actually empty, so the normal case
    /// adds nothing.
    private func logUnavailableInputs(macCount: Int, keptCount: Int) {
        #if DEBUG
        guard macCount == 0 else { return }
        UIStateLogger.log(
            "SNMPViewModel.rebuildDeviceList",
            "\(keptCount) devices — unavailable: arpMACs (no MAC merge this pass)"
        )
        #endif
    }

    /// Logs `.subnetTooLargeToScan` the moment a too-large network is
    /// recognized, so the gateway-only fallback in `candidateAddresses()`
    /// isn't silent. Called only from inside `rebuildDeviceList`'s
    /// fingerprint-transition guard — once per network join, not once per
    /// poll, the same cadence `wifiNetworkChanged` already logs at.
    private func logIfSubnetTooLargeToScan(localIP: String, mask: String, fingerprint: String) {
        guard
            let count = SubnetCalculator.usableHostCount(ipAddress: localIP, subnetMask: mask),
            count > SubnetCalculator.maxSweepHosts
        else { return }
        let cidr = SubnetCalculator.cidr(ipAddress: localIP, subnetMask: mask) ?? "\(localIP)/\(mask)"
        snapshotStore.logEvent(
            .subnetTooLargeToScan,
            message: "\(cidr) has \(count) usable addresses — SNMP discovery limited to the gateway only",
            networkFingerprint: fingerprint
        )
    }

    /// IP → MAC from the ARP table `LANDiscoveryService` already collects.
    /// Devices with no ARP entry simply don't appear, and are then left
    /// alone by the merge below.
    private func macByAddress() -> [String: String] {
        (lanDiscovery?.devices ?? []).reduce(into: [:]) { table, device in
            guard let mac = device.macAddress, !mac.isEmpty else { return }
            table[device.ipAddress] = mac
        }
    }

    /// Collapses entries whose addresses resolve to the *same MAC* — one
    /// physical interface answering at several addresses. The case this
    /// exists for: AP1 answering both its own `10.0.0.17` and the VRRP
    /// virtual `10.0.0.16`, which ARP shows sharing `e8:10:98:ca:a9:22`
    /// while AP2 at `.18` has its own.
    ///
    /// Deliberately keyed on MAC rather than `sysName` (which was tried and
    /// reverted): two addresses sharing a MAC is a fact about the hardware,
    /// needs no community string, and can't be fooled by two devices
    /// configured with the same name. Two devices cannot share a NIC.
    ///
    /// The asymmetry is worth stating, because it bounds what this can do: a
    /// MAC match proves one device, but a MAC *mismatch* proves nothing.
    /// This works here because Aruba answers the virtual address from the
    /// master's own physical MAC; a proper VRRP virtual MAC
    /// (`00:00:5e:00:01:XX`, RFC 5798) would resolve differently and the two
    /// would correctly-but-unhelpfully look like separate devices. So this
    /// is a sound positive signal, not a complete VRRP solution — see
    /// `DESIGN-NOTES.md`.
    ///
    /// Neither address is discarded: the lowest becomes the primary (a
    /// deterministic tie-break, not a claim about which is "real" — nothing
    /// available here can tell a virtual address from an individual one) and
    /// the rest are carried as `aliasAddresses` so the UI can show them.
    /// Internal rather than `private`, and `nonisolated`, so the merge
    /// rules can be unit tested directly — it reads no instance state,
    /// so it inherits `@MainActor` from the enclosing class for no
    /// reason, and the tests need nothing but inputs.
    nonisolated static func mergingSharedMACs(
        _ devices: [SNMPDevice],
        macByAddress: [String: String]
    ) -> [SNMPDevice] {
        var primaryByMAC: [String: SNMPDevice] = [:]
        var unknownMAC: [SNMPDevice] = []

        for device in devices {
            guard let mac = macByAddress[device.ipAddress] else {
                unknownMAC.append(device)
                continue
            }
            guard var primary = primaryByMAC[mac] else {
                primaryByMAC[mac] = device
                continue
            }
            let primaryPacked = SubnetCalculator.packedIPv4(primary.ipAddress) ?? .max
            let candidatePacked = SubnetCalculator.packedIPv4(device.ipAddress) ?? .max
            if candidatePacked < primaryPacked {
                var promoted = device
                promoted.aliasAddresses = (primary.aliasAddresses + [primary.ipAddress]).sorted()
                primaryByMAC[mac] = promoted
            } else {
                primary.aliasAddresses = (primary.aliasAddresses + [device.ipAddress]).sorted()
                primaryByMAC[mac] = primary
            }
        }
        return Array(primaryByMAC.values) + unknownMAC
    }

    /// Shared by rehydration and by `rebuildDeviceList`, which both need to
    /// turn persisted rows back into the value type.
    private static func device(from record: SNMPDeviceRecord) -> SNMPDevice {
        SNMPDevice(
            ipAddress: record.ipAddress,
            sysDescr: record.sysDescr,
            sysName: record.sysName,
            uptimeTicks: record.uptimeTicks,
            community: record.community,
            polledAt: record.lastSeenAt,
            webURL: record.webURL,
            hostname: record.hostname
        )
    }

    /// Strictly the current `/24` (or whatever mask is actually in effect):
    /// every host address in the local subnet, plus the gateway explicitly
    /// (normally already inside that sweep — this is just a safety net for
    /// an edge-case mask where it wouldn't be). Nothing here is ever
    /// off-subnet; SNMP discovery only looks at addresses structurally
    /// part of *this* network.
    ///
    /// This function used to also pull in two off-subnet sources — the raw
    /// ARP cache (`lanDiscovery.devices`) and any "local" (RFC 1918/CGNAT)
    /// traceroute hop, the latter specifically to catch an ISP edge router
    /// sitting one hop past the gateway. Both are gone now, for the same
    /// reason: an address doesn't need to be *on this network* to end up
    /// in either source, just recently visible to this Mac. The ARP cache
    /// leak was real and live-confirmed (see DESIGN-NOTES.md's "A router
    /// serving two VLANs..." — a dual-VLAN router's guest-side gateway kept
    /// getting swept and mis-tagged with the Home network's fingerprint
    /// purely because its ARP entry hadn't expired yet). The traceroute-hop
    /// source had the identical shape: "local" there means "private/CGNAT
    /// address space," not "on your subnet" — an ISP's edge router
    /// routinely lives on the ISP's own private infrastructure, a distinct
    /// network this Mac was never a member of. Losing that means SNMP no
    /// longer auto-discovers an ISP edge router reachable only as a
    /// traceroute hop; that's the accepted tradeoff for never scanning
    /// outside the current subnet. Doesn't touch `lanDiscovery.devices`'
    /// other, unrelated use in this file (`macByAddress()`, feeding the
    /// VRRP shared-MAC alias merge) — that reads it independently, not
    /// through this function.
    private func candidateAddresses() -> [String] {
        var addresses: Set<String> = []

        if let info = networkMonitor?.currentInterface {
            if let ip = info.ipAddress, let mask = info.subnetMask,
               let hosts = SubnetCalculator.hostAddresses(ipAddress: ip, subnetMask: mask) {
                addresses.formUnion(hosts)
            }
            if let router = info.routerAddress {
                addresses.insert(router)
            }
        }

        return addresses.sorted {
            (SubnetCalculator.packedIPv4($0) ?? 0) < (SubnetCalculator.packedIPv4($1) ?? 0)
        }
    }
}
