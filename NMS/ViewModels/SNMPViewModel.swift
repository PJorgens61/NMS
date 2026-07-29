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
    private let snapshotStore: SnapshotStore
    private weak var networkMonitor: NetworkMonitorViewModel?
    private weak var lanDiscovery: LANDiscoveryViewModel?
    private weak var bonjourDiscovery: BonjourDiscoveryViewModel?
    private weak var traceroute: TracerouteViewModel?
    private var timer: Timer?

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
        bonjourDiscovery: BonjourDiscoveryViewModel,
        traceroute: TracerouteViewModel
    ) {
        self.snapshotStore = snapshotStore
        self.networkMonitor = networkMonitor
        self.lanDiscovery = lanDiscovery
        self.bonjourDiscovery = bonjourDiscovery
        self.traceroute = traceroute
        let defaults = UserDefaults.standard
        if let stored = defaults.stringArray(forKey: Self.communitiesDefaultsKey), !stored.isEmpty {
            communities = stored
        } else if let legacy = defaults.string(forKey: Self.legacyCommunityDefaultsKey), !legacy.isEmpty {
            communities = [legacy]
        } else {
            communities = [Self.defaultCommunity]
        }
        // Rehydrate previously-discovered devices instead of sweeping at
        // launch. A full /24 sweep takes ~16s and forks up to 32 processes;
        // running that during startup — alongside the LAN scan, Bonjour
        // discovery, traceroute, connectivity checks and location auth —
        // is exactly the launch-time contention that already produced an
        // intermittent-empty-results bug in Bonjour discovery. Known
        // devices show (and start being polled and pinged) immediately;
        // the sweep itself is on demand via the popover's "Scan" button.
        devices = snapshotStore.fetchSNMPDevices().map(Self.device(from:))
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
    }

    deinit {
        timer?.invalidate()
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
            var byAddress = Dictionary(uniqueKeysWithValues: devices.map { ($0.ipAddress, $0) })
            for device in found {
                byAddress[device.ipAddress] = device
            }
            devices = byAddress.values.sorted {
                (SubnetCalculator.packedIPv4($0.ipAddress) ?? 0) < (SubnetCalculator.packedIPv4($1.ipAddress) ?? 0)
            }
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
    /// probe anyway (`candidateAddresses`, which covers an off-subnet
    /// router or an off-subnet local traceroute hop — both legitimate, and
    /// both invisible to a plain subnet test). Anything the subnet test
    /// can't parse counts as "can't tell" and is kept. Note this
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
        devices = Self.mergingSharedMACs(kept, macByAddress: macs)
            .sorted {
                (SubnetCalculator.packedIPv4($0.ipAddress) ?? 0) < (SubnetCalculator.packedIPv4($1.ipAddress) ?? 0)
            }
        logUnavailableInputs(macCount: macs.count, keptCount: kept.count)
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
    private static func mergingSharedMACs(
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
            polledAt: record.lastSeenAt
        )
    }

    /// The local subnet (when it's small enough to sweep safely) plus every
    /// address the app already knows about from its other discovery paths.
    /// The extras matter even alongside a sweep: the gateway and private
    /// traceroute hops are routers by definition, and a hop can sit on a
    /// *different* subnet than ours and so never appear in the sweep at all.
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
        for device in lanDiscovery?.devices ?? [] {
            addresses.insert(device.ipAddress)
        }
        for device in bonjourDiscovery?.devices ?? [] {
            if let ip = device.ipAddress {
                addresses.insert(ip)
            }
        }
        for hop in traceroute?.hops ?? [] {
            if let address = hop.address, hop.isLocal == true {
                addresses.insert(address)
            }
        }

        return addresses.sorted {
            (SubnetCalculator.packedIPv4($0) ?? 0) < (SubnetCalculator.packedIPv4($1) ?? 0)
        }
    }
}
