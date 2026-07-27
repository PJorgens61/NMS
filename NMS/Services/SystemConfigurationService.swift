import Foundation
import SystemConfiguration

/// Reads the current primary network interface (the one macOS is routing
/// default traffic through) using the SystemConfiguration framework, and
/// can notify a caller whenever that state changes.
///
/// This deliberately does NOT do any persistence or diffing — it's a thin,
/// testable wrapper around SCDynamicStore/SCPreferences. Snapshot storage
/// and change-correlation belong in higher-level services.
final class SystemConfigurationService {

    // MARK: - Reading current state

    /// Returns info about the currently active primary interface, or `nil`
    /// if there is no default route (e.g. fully offline).
    func currentPrimaryInterface() -> NetworkInterfaceInfo? {
        guard let store = SCDynamicStoreCreate(nil, "NMS" as CFString, nil, nil) else {
            return nil
        }

        // "Primary" here means: the interface macOS would use for a new
        // outbound connection right now. This key tracks that directly,
        // so we don't have to guess by ranking interfaces ourselves.
        guard
            let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
            let primaryInterfaceName = globalIPv4["PrimaryInterface"] as? String
        else {
            return nil
        }

        let router = globalIPv4["Router"] as? String

        let ifaceKey = "State:/Network/Interface/\(primaryInterfaceName)/IPv4" as CFString
        let ipv4Details = SCDynamicStoreCopyValue(store, ifaceKey) as? [String: Any]

        let ipAddress = (ipv4Details?["Addresses"] as? [String])?.first
        let subnetMask = (ipv4Details?["SubnetMasks"] as? [String])?.first

        // Verified directly against `scutil --dns`'s resolver #1
        // (nameserver[0]): `State:/Network/Global/DNS`'s first
        // `ServerAddresses` entry matches macOS's own effective primary
        // resolver, not just whatever's in a possibly-stale
        // `/etc/resolv.conf` stub.
        let dnsGlobal = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        let dnsServer = (dnsGlobal?["ServerAddresses"] as? [String])?.first

        return NetworkInterfaceInfo(
            interfaceName: primaryInterfaceName,
            displayName: friendlyName(forBSDName: primaryInterfaceName),
            ipAddress: ipAddress,
            subnetMask: subnetMask,
            routerAddress: router,
            dnsServer: dnsServer,
            isWiFi: wifiInterfaceNames().contains(primaryInterfaceName),
            capturedAt: Date()
        )
    }

    /// Maps a BSD name like "en0" to the human-readable service name shown
    /// in System Settings > Network, e.g. "Wi-Fi".
    private func friendlyName(forBSDName bsdName: String) -> String? {
        guard
            let prefs = SCPreferencesCreate(nil, "NMS" as CFString, nil),
            let networkSet = SCNetworkSetCopyCurrent(prefs),
            let services = SCNetworkSetCopyServices(networkSet) as? [SCNetworkService]
        else {
            return nil
        }

        for service in services {
            guard let interface = SCNetworkServiceGetInterface(service) else { continue }
            if SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
                return SCNetworkServiceGetName(service) as String?
            }
        }
        return nil
    }

    /// All BSD interface names macOS currently classifies as Wi-Fi (IEEE 802.11).
    private func wifiInterfaceNames() -> Set<String> {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return []
        }
        return Set(
            interfaces.compactMap { iface in
                guard
                    SCNetworkInterfaceGetInterfaceType(iface) as String? == (kSCNetworkInterfaceTypeIEEE80211 as String),
                    let bsdName = SCNetworkInterfaceGetBSDName(iface) as String?
                else {
                    return nil
                }
                return bsdName
            }
        )
    }

    // MARK: - Observing changes

    private var changeHandler: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var store: SCDynamicStore?

    /// Registers `handler` to be called whenever relevant network state
    /// changes: interface up/down, IP change, Wi-Fi network switch, router
    /// change, etc. Must be called from a thread with an active run loop
    /// (the main thread is fine).
    ///
    /// Keep a strong reference to this `SystemConfigurationService` instance
    /// for as long as you want notifications — the underlying run loop
    /// source is tied to its lifetime.
    @discardableResult
    func observeChanges(_ handler: @escaping () -> Void) -> Bool {
        self.changeHandler = handler

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let store = SCDynamicStoreCreate(
            nil,
            "NMS-Watcher" as CFString,
            { _, _, info in
                guard let info else { return }
                let service = Unmanaged<SystemConfigurationService>.fromOpaque(info).takeUnretainedValue()
                service.changeHandler?()
            },
            &context
        ) else {
            return false
        }

        let watchedKeys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6"
        ] as CFArray

        let watchedPatterns = [
            "State:/Network/Interface/.*/IPv4",
            "State:/Network/Interface/.*/IPv6",
            "State:/Network/Interface/.*/Link"
        ] as CFArray

        guard SCDynamicStoreSetNotificationKeys(store, watchedKeys, watchedPatterns) else {
            return false
        }

        guard let runLoopSource = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)

        self.store = store
        self.runLoopSource = runLoopSource
        return true
    }

    func stopObserving() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        store = nil
        changeHandler = nil
    }
}
