import Foundation
import Combine

@MainActor
final class SNMPViewModel: ObservableObject {
    @Published private(set) var devices: [SNMPDevice] = []
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
        devices = snapshotStore.fetchSNMPDevices().map {
            SNMPDevice(
                ipAddress: $0.ipAddress,
                sysDescr: $0.sysDescr,
                sysName: $0.sysName,
                uptimeTicks: $0.uptimeTicks,
                community: $0.community,
                polledAt: $0.lastSeenAt
            )
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
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
            Task { @MainActor in
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
            Task { @MainActor in
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
        isScanning = false
        lastScanAt = Date()

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
                snapshotStore.logEvent(.snmpDeviceRestarted, message: "\(device.displayName) restarted unexpectedly")
                loggedAny = true
            case let .softwareChanged(previousDescr, restarted):
                let verb = restarted ? "restarted after software change" : "software changed"
                snapshotStore.logEvent(
                    .snmpDeviceSoftwareChanged,
                    message: "\(device.displayName) \(verb): \(previousDescr) → \(device.sysDescr)"
                )
                loggedAny = true
            }
        }
        if loggedAny {
            onEventLogged?()
        }
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
