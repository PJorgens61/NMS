import Foundation
import Network

/// Discovers devices via Bonjour (mDNS/DNS-SD) using `NWBrowser`. There's no
/// "browse everything" API — discovery is always scoped to one specific
/// service type — so this checks a curated set of common ones in parallel.
///
/// Avoids `withCheckedContinuation` for the *state-tracking* parts of
/// bridging `NWBrowser`/`NWConnection`'s callback-based APIs into
/// async/await: a continuation resumed twice is a fatal error at runtime,
/// and these callbacks (state handlers, results-changed handlers) can fire
/// more than once. Instead, callback-reported state is confined to a single
/// serial `DispatchQueue` (both the callback that writes it and the final
/// read are dispatched onto the same queue, so there's a real
/// happens-before relationship between "last update" and "read," not just
/// "usually wins the race"). The *only* continuation used is a single
/// one-shot read of already-settled state after the browse/resolve window
/// has closed — nothing left to double-resume.
/// Holds state mutated from `NWBrowser`/`NWConnection`'s callback closures
/// and read back afterward. `@unchecked Sendable` because the actual safety
/// guarantee — every write and the final read all happen on the one serial
/// `DispatchQueue` passed to `start(queue:)` — is enforced by
/// Network.framework's documented callback behavior, not by anything the
/// compiler can see from a plain captured `var`; hence the "mutation of
/// captured var in concurrently-executing code" warning this exists to
/// silence correctly, by making the same invariant explicit instead of
/// implicit.
private nonisolated final class UnsafeBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

struct BonjourDiscoveryService {
    /// Common service types worth checking. Not exhaustive — Bonjour has
    /// hundreds of registered service types — but covers printers, file
    /// sharing, remote access, casting, and Apple's own device/AirPlay
    /// advertisements, which is a reasonable spread for a home/small
    /// network without browsing indefinitely many types.
    static let serviceTypes: [(type: String, label: String)] = [
        ("_airplay._tcp", "AirPlay"),
        ("_raop._tcp", "AirPlay Audio"),
        ("_ipp._tcp", "Printer"),
        ("_ipps._tcp", "Printer"),
        ("_smb._tcp", "File Sharing"),
        ("_ssh._tcp", "SSH"),
        ("_googlecast._tcp", "Chromecast"),
        ("_hap._tcp", "HomeKit"),
        ("_device-info._tcp", "Device Info"),
    ]

    // Widened from an initial 3s/2s after observing inconsistent results at
    // launch specifically — Bonjour discovery runs concurrently with LAN
    // scan, traceroute, connectivity checks, and SSID/location auth at
    // startup, and that contention can make tight windows insufficient
    // even though the same scan reliably finds everything when there's
    // less going on (confirmed: a manual re-run with more elapsed time
    // found all 7 real devices that a tighter-timed run had missed).
    private static let browseDuration: Duration = .seconds(4)
    private static let resolveDuration: Duration = .seconds(3)

    /// Browses all curated service types in parallel and resolves each
    /// discovered service's IP. Takes a few seconds (browse + resolve
    /// windows), so this is meant for a manual scan or an infrequent
    /// automatic one, not something run on every topology change the way
    /// ARP-based discovery is.
    func discover() async -> [BonjourDevice] {
        await withTaskGroup(of: [BonjourDevice].self) { group in
            for (type, label) in Self.serviceTypes {
                group.addTask {
                    await Self.discoverServiceType(type: type, label: label)
                }
            }
            var all: [BonjourDevice] = []
            for await devices in group {
                all.append(contentsOf: devices)
            }
            return all
        }
    }

    private static func discoverServiceType(type: String, label: String) async -> [BonjourDevice] {
        let found = await browse(type: type)
        return await withTaskGroup(of: BonjourDevice.self) { group in
            for (name, endpoint) in found {
                group.addTask {
                    let ip = await resolveIP(endpoint: endpoint)
                    return BonjourDevice(name: name, serviceType: type, serviceLabel: label, ipAddress: ip, discoveredAt: Date())
                }
            }
            var devices: [BonjourDevice] = []
            for await device in group {
                devices.append(device)
            }
            return devices
        }
    }

    private static func browse(type: String) async -> [(name: String, endpoint: NWEndpoint)] {
        // NWBrowser delivers `browseResultsChangedHandler` on this queue,
        // so writes below always happen serially on it — and reading the
        // final value via the same queue guarantees we see the last write,
        // not a stale pre-update snapshot.
        let queue = DispatchQueue(label: "NMS.bonjour.browse")
        let latestResults = UnsafeBox<Set<NWBrowser.Result>>([])

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: parameters)

        browser.browseResultsChangedHandler = { results, _ in
            latestResults.value = results
        }

        browser.start(queue: queue)
        try? await Task.sleep(for: Self.browseDuration)
        browser.cancel()

        let results: Set<NWBrowser.Result> = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: latestResults.value)
            }
        }

        return results.compactMap { result in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            return (name, result.endpoint)
        }
    }

    private static func resolveIP(endpoint: NWEndpoint) async -> String? {
        // Same fix as `browse`: the connection's state callback and the
        // final read both go through this one serial queue, so there's a
        // real happens-before relationship instead of a race between "did
        // the callback's effect land yet" and "we're reading now."
        let queue = DispatchQueue(label: "NMS.bonjour.resolve")
        let resolvedIP = UnsafeBox<String?>(nil)

        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            guard resolvedIP.value == nil, case .ready = state else { return }
            guard case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint else { return }
            switch host {
            case .ipv4(let addr):
                // IPv4Address's description can carry a "%interface" suffix
                // from the underlying sockaddr's scope info — meaningless
                // for IPv4 (zone IDs are an IPv6 concept) and inconsistent
                // with the plain "a.b.c.d" format ARP-based discovery
                // already uses, so strip it.
                resolvedIP.value = "\(addr)".split(separator: "%").first.map(String.init) ?? "\(addr)"
            case .ipv6(let addr):
                resolvedIP.value = "\(addr)"
            default:
                break
            }
        }
        connection.start(queue: queue)

        try? await Task.sleep(for: Self.resolveDuration)
        connection.cancel()

        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: resolvedIP.value)
            }
        }
    }
}
