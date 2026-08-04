import Foundation

@MainActor
@Observable
final class NetworkIdentityViewModel {
    private(set) var currentNetwork: KnownNetwork?
    private(set) var isNewNetwork = false
    private(set) var knownNetworks: [KnownNetwork] = []

    private let snapshotStore: SnapshotStore
    /// Guards against retrying more than once per topology change — see
    /// `onRecognitionPending`. Reset in `reset()`, which already runs at
    /// the start of every topology change, before recognition is
    /// attempted, so a later network gets its own fresh retry budget
    /// rather than inheriting an earlier one's.
    private var hasRequestedRetry = false

    /// Fired when `recognize()` failed for the one specific, retriable
    /// reason: the router answered (its address and subnet mask are both
    /// known) but its MAC hasn't shown up in the ARP cache read yet — the
    /// race documented in `BUGS.md`'s "Known Networks silently never adds
    /// an unfamiliar network." Not fired for the "no interface at all"
    /// case, which has nothing worth retrying. `NMSApp` wires this to a
    /// single delayed re-scan (`hasRequestedRetry` caps it at one, so a
    /// network that genuinely never resolves its router's MAC doesn't
    /// retry forever).
    var onRecognitionPending: (() -> Void)?

    /// Fired once the current network is known and
    /// `SnapshotStore.currentNetworkFingerprint` has been set — i.e. the
    /// moment the per-network queries can finally return anything.
    ///
    /// Everything scoped per network is fetched once at launch, from
    /// `init`, which runs *before* the first LAN scan has resolved the
    /// router's MAC. Those fetches therefore run with no current
    /// fingerprint and come back empty, and until this existed nothing
    /// re-ran them: `EventLogViewModel.refresh()` was wired only to
    /// `onEventLogged`, so a full history stayed invisible until the app
    /// happened to log a brand-new event of its own. On a healthy network
    /// that can be a long wait — events are logged on *change*, and
    /// nothing changing is the normal case.
    ///
    /// Latent all along, but only observable once the store started
    /// opening again (see `BUGS.md`): while every record was untagged, the
    /// launch-time fetch matched them anyway, so the missing refresh had
    /// nothing to reveal.
    var onNetworkRecognized: (() -> Void)?

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    /// Finds the router's MAC address among freshly-scanned LAN devices and
    /// records/looks up the network identity for it, keyed by router MAC
    /// **and subnet** — see `KnownNetwork` for why the subnet is needed
    /// too. Called after every LAN scan (automatic or manual) since that's
    /// what produces the MAC data. If the router's MAC or the subnet mask
    /// can't be resolved yet (e.g. the ARP cache hasn't populated right
    /// after connecting), leaves recognition state as-is rather than
    /// guessing at an identity.
    ///
    /// Also sets `SnapshotStore.currentNetworkFingerprint`, which is what
    /// actually scopes Events/SNMP Devices/DHCP History to this network —
    /// this method existing and being called is the one place that
    /// connects "which network are we on" to "what data should show."
    ///
    /// The two failure cases are handled differently on purpose. No
    /// interface, or no subnet mask, means there's nothing to recognize
    /// yet — silent, same as before. But the router already answering
    /// (its address and subnet are known) while its MAC is still missing
    /// from the ARP cache is a real, previously-silent bug: the scan that
    /// just ran was simply too early, macOS's own ARP resolution hadn't
    /// caught up, and — with no retry — the network would never be
    /// recognized for the rest of the session. That race is already
    /// documented elsewhere in this codebase, for the same reason, after
    /// a Wi-Fi reconnect (`SNMPViewModel.refreshARPIfMergeDataIsStale`).
    func recognize(routerAddress: String?, subnetMask: String?, from devices: [DiscoveredDevice]) {
        guard let routerAddress, let subnetMask else { return }

        guard let routerMAC = devices.first(where: { $0.ipAddress == routerAddress })?.macAddress else {
            if hasRequestedRetry {
                UIStateLogger.log(
                    "NetworkIdentityViewModel.recognize",
                    "\(routerAddress) still not in ARP cache after one retry — giving up until the next topology change"
                )
            } else {
                hasRequestedRetry = true
                UIStateLogger.log(
                    "NetworkIdentityViewModel.recognize",
                    "\(routerAddress) not yet in ARP cache — requesting one retry"
                )
                onRecognitionPending?()
            }
            return
        }

        guard let subnet = SubnetCalculator.cidr(ipAddress: routerAddress, subnetMask: subnetMask) else {
            UIStateLogger.log(
                "NetworkIdentityViewModel.recognize",
                "could not compute a subnet for \(routerAddress)/\(subnetMask)"
            )
            return
        }

        let (network, isNew) = snapshotStore.recordNetworkSeen(routerMAC: routerMAC, subnet: subnet)
        // Before declaring this the current network: anything written
        // while recognition was still pending (a real race — SNMP/DHCP
        // both run before the first LAN scan resolves this) is still
        // tagged `nil`. It was learned on this network, just before this
        // network had a name; adopt it now rather than leaving it
        // orphaned. See `SnapshotStore.adoptUntaggedRecords`.
        snapshotStore.adoptUntaggedRecords(into: network.fingerprint)
        currentNetwork = network
        isNewNetwork = isNew
        snapshotStore.setCurrentNetworkFingerprint(network.fingerprint)
        refreshKnownNetworks()
        // Last, deliberately: everything above has to be in place before
        // anything re-reads, or the refresh this triggers would run
        // against the fingerprint that was current a moment ago.
        onNetworkRecognized?()
    }

    /// Clears recognition state and the store's current-network fingerprint
    /// — called right when a topology change is first detected, before the
    /// LAN scan that will re-`recognize` the new network completes. Without
    /// this, `currentNetworkFingerprint` would keep pointing at the
    /// *previous* network for the gap between the change and re-
    /// recognition, during which any data recorded would be wrongly
    /// attributed to it — exactly the cross-network leakage this whole
    /// feature exists to prevent.
    ///
    /// Returns the fingerprint that was just cleared — the network being
    /// left, `nil` if there wasn't one recognized yet. `NMSApp`'s
    /// topology-change wiring needs this: `wifiSSID.refresh(...)` runs
    /// right after this call and can log a network-change event describing
    /// the departure, but by then `currentNetworkFingerprint` has already
    /// moved to `nil` — capturing it here, before that happens, is the only
    /// way that event can still be tagged with the network it's actually
    /// about. See `BUGS.md`'s "A network-transition event can be filed
    /// under the wrong network's Events tab."
    @discardableResult
    func reset() -> String? {
        let departingFingerprint = snapshotStore.currentNetworkFingerprint
        currentNetwork = nil
        isNewNetwork = false
        hasRequestedRetry = false
        snapshotStore.setCurrentNetworkFingerprint(nil)
        return departingFingerprint
    }

    /// Names a network — any known network, not just the current one,
    /// which is the whole point: `KnownNetworksView` lists every network
    /// this Mac has seen, and a field technician labelling a site they
    /// visited last week is exactly the case that matters. (The previous
    /// version of this took no network and silently only worked on
    /// `currentNetwork`; nothing ever called it, so it was dead code
    /// enforcing a restriction no caller wanted.)
    ///
    /// An empty label clears it rather than storing `""` — see
    /// `SnapshotStore.setLabel` — so the display falls back to the Wi-Fi
    /// SSID or "Ethernet" again, which is what an emptied field should
    /// mean.
    func setLabel(_ label: String, for network: KnownNetwork) {
        snapshotStore.setLabel(label, for: network)
        refreshKnownNetworks()
    }

    /// See `SnapshotStore.setHome` — a singleton designation, so marking
    /// one network home un-marks whichever one previously held it.
    func setHome(_ isHome: Bool, for network: KnownNetwork) {
        snapshotStore.setHome(isHome, for: network)
        refreshKnownNetworks()
    }

    func refreshKnownNetworks() {
        knownNetworks = snapshotStore.fetchKnownNetworks()
    }

    /// Forgets a network entirely, including every event/lease/device it
    /// was ever the source of. See `SnapshotStore.deleteNetwork`.
    func deleteNetwork(_ network: KnownNetwork) {
        snapshotStore.deleteNetwork(network)
        if currentNetwork?.fingerprint == network.fingerprint {
            currentNetwork = nil
            isNewNetwork = false
        }
        refreshKnownNetworks()
    }
}
