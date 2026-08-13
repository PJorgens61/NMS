import Foundation
import Network

/// A local-only, on-demand HTTP server serving a chronological log of
/// recent diagnostic activity — Events, plus every test result
/// (`NetworkQualityRecord`, `WiFiStressTestRecord`) and the SNMP device
/// list — as a plain web page. The first, simplest use case of the
/// local-HTTP-server idea in `PUNCHLIST.md` ("A local-only HTTP
/// server"), built first specifically to prove the server plumbing
/// before the two heavier, shipped-feature use cases (Apple
/// networkQuality report formatting, the Mermaid diagram privacy fix)
/// build their own content generators on top of it.
///
/// **Un-gated from `#if DEBUG`, 2026-08-12** — ships in Release now, a
/// deliberate divergence from this file's own original "debug-only, dev/
/// testing tooling" framing above (kept for history, no longer current).
/// Part of the popover conversion: the main window's ten data-dense tiles
/// are being replaced by a small `MenuBarExtra` popover
/// (`MenuBarView.swift`) whose status lines/links open pages this server
/// renders — so the server has to be a normal, always-available feature,
/// not a dev tool, for the app to have anywhere to show that content at
/// all. Matches RoonWatch's own explicit precedent and reasoning for the
/// same choice: "a real end user needs the same drill-down an agent/
/// developer would get" (`RoonWatch/RoonWatch/Platform/DiagnosticServer/
/// LocalDiagnosticServer.swift`). Real, worth naming plainly: device
/// names/IPs/network fingerprints become reachable via a shipped
/// loopback HTTP server to end users now, not just during development —
/// mitigated the same way it always was (loopback-only binding,
/// ephemeral port, random per-launch token below), just now exposed to a
/// wider audience than "whoever's running a debug build."
///
/// Deliberately not named anything with "field test" in it —
/// `FieldTestFrameReporter` already owns that term for a different,
/// unrelated meaning (a SwiftUI view reporting its own on-screen frame
/// for layout verification). This is about reviewing real-world network
/// diagnostic history from an actual field-testing trip, a different
/// "field test" entirely — naming it distinctly avoids the collision
/// rather than overloading one term for two things.
///
/// Real constraints, from that same punchlist item, followed here:
/// **loopback-only** (`127.0.0.1`, via `requiredLocalEndpoint` —
/// binding to every interface would make locally-generated diagnostic
/// data reachable from other devices on whatever LAN this Mac is on,
/// exactly the opposite of the point), **no third-party dependency**
/// (`Network.framework`'s `NWListener` plus hand-written minimal
/// HTTP/1.1, not a package), **on-demand lifecycle** (started
/// explicitly, stops itself after an idle timeout rather than running
/// for the app's whole lifetime), and an **ephemeral port plus a random
/// per-launch path token** (defense in depth on top of the loopback
/// binding — another local process can't guess the URL either).
///
/// **Regenerated on every request, not cached from `start()`** — raised
/// directly ("will it log tests as I do them?"): a field-test session
/// keeps producing new events and test results after the page is first
/// opened, so reloading the browser tab needs to show what's happened
/// since, not a frozen snapshot from the moment the button was clicked.
/// Cheap to do — the underlying `fetch*History` calls are the same ones
/// `script/export-diagnostic.sh` already makes, not expensive queries.
@MainActor
final class LocalDiagnosticServer {
    /// The diagnostic log (`SnapshotStore`-backed) and a Path Discovery
    /// reverse-trace result set are two *sections* of the one server, not
    /// two competing modes. Previously each had its own `start(...)` that
    /// unconditionally tore down the listener and minted a fresh token —
    /// which meant opening one silently broke whichever page was already
    /// open in another browser tab (raised directly, live: "dianostic log
    /// webpage didn't work. conflict with path discovery?"). Now the
    /// listener/token, once started, stays up and serves both sections —
    /// `/log` and `/path-discovery` — with in-page navigation between
    /// them ("should the webpage selection be builtin to a single webpage
    /// instead?"), so starting either one doesn't disturb a tab already
    /// open on the other.
    private struct ReverseTraceContent {
        let target: String
        let results: [GlobalpingReverseTraceService.ProbeTraceResult]
        let confirmedAddress: String?
        let siblingAddresses: [String: [String: String]]
        let frontsideHops: [TracerouteHop]
        let networkName: String?
        let geoHints: [String: String]
        let scamperVerdicts: [String: Bool]
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var snapshotStore: SnapshotStore?
    /// `/saas` reads this directly, live — unlike `/log`/`/network`,
    /// SaaS status is current-state-only (no history worth persisting,
    /// same reasoning `SaaSStatusTile` already had), so there's no
    /// `SnapshotStore` fetch to read from instead. A real, deliberate
    /// divergence from this server's normal "read fresh from disk on
    /// every request" pattern, not an oversight — set once via
    /// `setSaaSMonitoring(_:)` when the app starts (see `NMSApp`).
    private var saasMonitoring: SaaSMonitoringViewModel?
    /// `/network` reads these seven directly, live — same "current
    /// status, not history" reasoning as `saasMonitoring` above.
    /// Deliberately a port of `NetworkTile.connectionLayersLowToHigh`'s
    /// logic (see that type's own doc comment), not a live shared
    /// extraction — `NetworkTile.swift` is being deleted outright once
    /// the popover conversion's tile migration reaches it, so this is
    /// each piece of logic's actual permanent home, not a temporary
    /// duplicate of it.
    private var networkViewModels: NetworkViewModels?
    private var reverseTraceContent: ReverseTraceContent?
    private var pathToken = ""
    private var idleTimer: Timer?

    private static let idleTimeout: TimeInterval = 600 // 10 minutes, matches no other magic number in this app -- picked as "long enough to actually read the page, short enough not to linger."

    var isRunning: Bool { listener != nil }

    /// Makes the diagnostic log available and returns the URL to open it
    /// directly. Starts the server if it isn't already running; if it is
    /// (e.g. Path Discovery started it first), reuses the same listener
    /// and token rather than restarting — restarting would invalidate the
    /// token any other already-open tab is using.
    func start(snapshotStore: SnapshotStore) async -> URL? {
        self.snapshotStore = snapshotStore
        guard let base = await ensureRunning() else { return nil }
        return base.appendingPathComponent("log")
    }

    /// Registers the live SaaS view model `/saas` reads from — see that
    /// property's own doc comment for why this doesn't go through
    /// `SnapshotStore` the way everything else does. Safe to call any
    /// time before the server needs to render `/saas` (idempotent,
    /// doesn't itself start the listener) — called once from `NMSApp`
    /// alongside the rest of its view-model wiring.
    func setSaaSMonitoring(_ saasMonitoring: SaaSMonitoringViewModel) {
        self.saasMonitoring = saasMonitoring
    }

    /// Bundles every view model `/network` needs — same "set once
    /// alongside the rest of `NMSApp`'s wiring, read live thereafter"
    /// shape as `setSaaSMonitoring` above, just seven view models
    /// instead of one.
    struct NetworkViewModels {
        let viewModel: NetworkMonitorViewModel
        let connectivity: ConnectivityViewModel
        let wifiSSID: WiFiSSIDViewModel
        let networkIdentity: NetworkIdentityViewModel
        let publicIP: PublicIPViewModel
        let ispIdentity: ISPIdentityViewModel
        let traceroute: TracerouteViewModel
        let dhcpLease: DHCPLeaseViewModel
        let ethernetLink: EthernetLinkViewModel
        let ddns: DDNSViewModel
    }

    func setNetworkViewModels(_ networkViewModels: NetworkViewModels) {
        self.networkViewModels = networkViewModels
    }

    /// Ensures the listener is up and returns its base URL, without
    /// staging any particular page's content — used by callers (the
    /// popover's status-line/link taps) that just need *a* URL to open a
    /// specific `appendingPathComponent` path against, the same shape
    /// RoonWatch's `AppCoordinator.diagnosticServerURL(path:)` already
    /// uses. `start(snapshotStore:)` above stays as its own entry point
    /// rather than being rewritten in terms of this one, since it also
    /// has the one-time job of storing `snapshotStore` for every route
    /// that needs it, not just `/log`.
    func diagnosticServerURL(path: String = "") async -> URL? {
        guard let base = await ensureRunning() else { return nil }
        return path.isEmpty ? base : base.appendingPathComponent(path)
    }

    /// Makes a Path Discovery reverse-trace result set available and
    /// returns the URL to open it directly. The Globalping network calls
    /// themselves (`GlobalpingReverseTraceService.createMeasurement`/
    /// `fetchResult`) already happened by the time this is called — this
    /// server only renders already-fetched results, it doesn't make its
    /// own network calls per-request the way the diagnostic log re-reads
    /// `SnapshotStore` on every request. A live multi-second Globalping
    /// round trip on every page reload would be a worse experience than
    /// showing one run's results until a fresh "Path Discovery…" click
    /// replaces them.
    /// `confirmedAddress` is Path to Internet's currently confirmed ISP
    /// edge hop, if any -- lets the results page mark which probe(s)
    /// actually corroborate it. `siblingAddresses` is the supplementary
    /// `dig`-sourced lookup for each edge-candidate device stem (see
    /// `DebugToolsView.lookUpSiblingAddresses`) -- both optional/empty by
    /// default so this stays callable the same simple way for a plain
    /// run with no confirmed hop yet. `frontsideHops` is this Mac's own
    /// outbound trace (`TracerouteViewModel.hops`) -- the "frontside" half
    /// of the topology diagram, `results` being the "backside" half.
    /// `networkName` is a label for *this run's own network* (raised
    /// directly, live field testing across several locations in one
    /// session: "topology display should include the network name for
    /// reference later") -- a known network's own `label` if the user
    /// set one, else the current SSID, resolved by the caller
    /// (`DebugToolsView`) since this type has no network-identity
    /// dependency of its own. `nil` when neither is available (e.g.
    /// Ethernet with no `KnownNetwork` label).
    /// `geoHints` is Hoiho's own hostname -> display-string lookup
    /// (`HoihoService.lookup`, already resolved by the caller before this
    /// is called -- see `TopologyBuilder.renderMermaid`'s own doc comment
    /// for why that stays a pure caller-supplied dictionary rather than a
    /// network call made in here or in `TopologyBuilder` itself). Empty
    /// by default, same "stays callable the simple way" reasoning as
    /// `confirmedAddress`/`siblingAddresses` above.
    /// `scamperVerdicts` maps a candidate address to scamper's Ally
    /// verdict (`true`/`false`) for whether it's the same device as the
    /// confirmed hop — only present for addresses `DebugToolsView`
    /// already flagged as a device-stem match, a real second opinion on
    /// that specific claim. See `ScamperService`'s own doc comment for
    /// why this is `[String: Bool]`, not `[String: Bool?]`: an
    /// inconclusive result (`nil`) is simply never inserted, same
    /// "absence means unknown" shape `geoHints` already uses.
    func showReverseTrace(
        target: String,
        results: [GlobalpingReverseTraceService.ProbeTraceResult],
        confirmedAddress: String? = nil,
        siblingAddresses: [String: [String: String]] = [:],
        frontsideHops: [TracerouteHop] = [],
        networkName: String? = nil,
        geoHints: [String: String] = [:],
        scamperVerdicts: [String: Bool] = [:]
    ) async -> URL? {
        reverseTraceContent = ReverseTraceContent(target: target, results: results, confirmedAddress: confirmedAddress, siblingAddresses: siblingAddresses, frontsideHops: frontsideHops, networkName: networkName, geoHints: geoHints, scamperVerdicts: scamperVerdicts)
        Self.exportReverseTraceHTML(target: target, results: results, confirmedAddress: confirmedAddress, siblingAddresses: siblingAddresses, frontsideHops: frontsideHops, networkName: networkName, geoHints: geoHints, scamperVerdicts: scamperVerdicts)
        guard let base = await ensureRunning() else { return nil }
        return base.appendingPathComponent("path-discovery")
    }

    /// Also written to disk on every run, automatically — raised directly
    /// ("is their a way for you to see the web page automatically? a
    /// local copy in nms?"): browser automation has been unreliable this
    /// session, so a plain file on disk can just be read directly instead
    /// of needing a working browser session. Same directory
    /// `export-diagnostic.sh` already writes to (gitignored, local-only,
    /// same `<name>-<yyyyMMdd-HHmmss>` naming). `#filePath` is this
    /// source file's own on-disk location at compile time -- a Debug
    /// build always compiles straight from the local checkout it's part
    /// of, so walking up from it to the project root is more portable
    /// than hardcoding this machine's path, and it's the only signal
    /// available at all: a compiled app bundle has no other way to know
    /// where its own source checkout lives.
    private static func exportReverseTraceHTML(
        target: String,
        results: [GlobalpingReverseTraceService.ProbeTraceResult],
        confirmedAddress: String?,
        siblingAddresses: [String: [String: String]],
        frontsideHops: [TracerouteHop],
        networkName: String?,
        geoHints: [String: String],
        scamperVerdicts: [String: Bool]
    ) {
        let dir = projectRoot().appendingPathComponent("script/diagnostic-exports")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // Slugged into the filename (not just the page body) so a folder of
        // these exports is scannable/greppable by network without opening
        // each one -- the actual gap raised directly ("save the topology
        // output for later reference"): today's exports are otherwise only
        // distinguishable by timestamp.
        let networkSlug = networkName.flatMap { name -> String? in
            let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            let collapsed = String(slug).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return collapsed.isEmpty ? nil : String(collapsed.prefix(40))
        }
        let fileStem = networkSlug.map { "path-discovery-\($0)" } ?? "path-discovery"
        let file = dir.appendingPathComponent("\(fileStem)-\(formatter.string(from: Date())).html")

        let html = renderReverseTracePage(target: target, results: results, confirmedAddress: confirmedAddress, siblingAddresses: siblingAddresses, frontsideHops: frontsideHops, networkName: networkName, geoHints: geoHints, scamperVerdicts: scamperVerdicts)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try html.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            print("LocalDiagnosticServer: failed to export Path Discovery page: \(error)")
        }
    }

    /// Returns the base `http://127.0.0.1:<port>/<token>` URL, starting
    /// the listener first if it isn't already up. Reuses an already-ready
    /// listener as-is instead of restarting it, which is the actual fix
    /// for the "starting one page kills the other" bug above.
    ///
    /// Calls `stopListener()`, not the public `stop()` -- a real bug,
    /// found while adding the topology diagram and confirmed by actually
    /// reading a fetched page's body rather than just checking it
    /// contained an expected word (which a fallback "not yet available"
    /// page also does, since its own title/heading repeat the section
    /// name -- the existing tests here were accidentally too weak to
    /// catch this). `start`/`showReverseTrace` both set their content
    /// field *before* calling this -- on the very first call ever (no
    /// listener exists yet), the old code path called the full `stop()`
    /// right here, which wiped that just-set content back to `nil` before
    /// the listener even came up, so the first-ever open of either page
    /// each launch silently served "not yet available" instead of the
    /// real content. A second click worked by accident, because by then
    /// the listener was already `.ready` and this whole branch was
    /// skipped.
    private func ensureRunning() async -> URL? {
        if let listener, listener.state == .ready, let port = listener.port {
            return URL(string: "http://127.0.0.1:\(port.rawValue)/\(pathToken)")
        }
        stopListener()
        pathToken = Self.randomToken()
        return await startListener()
    }

    /// The actual `NWListener` setup.
    private func startListener() async -> URL? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        guard let listener = try? NWListener(using: parameters) else {
            print("LocalDiagnosticServer: failed to create listener")
            return nil
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }

        return await withCheckedContinuation { continuation in
            // `resumed` guards against `withCheckedContinuation`'s own
            // "resume more than once" fatal error -- `.cancelled` can
            // follow a `.failed` state in the same handler's lifetime,
            // and only the first should settle the continuation. A plain
            // class, not a struct -- every read/write happens inside a
            // `Task { @MainActor in ... }` block below, already
            // serialized, so no atomic/lock type is needed for safety,
            // just a mutable reference to share across invocations.
            final class ResumedFlag { var value = false }
            let resumed = ResumedFlag()
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else {
                            if !resumed.value { resumed.value = true; continuation.resume(returning: nil) }
                            return
                        }
                        self.scheduleIdleTimeout()
                        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.pathToken)")
                        if !resumed.value { resumed.value = true; continuation.resume(returning: url) }
                    case .failed, .cancelled:
                        self.stop()
                        if !resumed.value { resumed.value = true; continuation.resume(returning: nil) }
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    /// Tears down the listener/connections/idle-timer only -- no content
    /// change. Split out of `stop()` specifically for `ensureRunning()`,
    /// which needs to reset listener state before (re)starting without
    /// discarding whatever `start`/`showReverseTrace` just staged to
    /// serve once that listener comes up.
    private func stopListener() {
        idleTimer?.invalidate()
        idleTimer = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    /// Full teardown -- also clears staged content, unlike `stopListener()`.
    /// Correct here: an idle timeout or an explicit `stop()` call both mean
    /// "nothing should be servable anymore," not "about to restart."
    func stop() {
        stopListener()
        snapshotStore = nil
        reverseTraceContent = nil
    }

    private func scheduleIdleTimeout() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .cancelled = state { self?.connections.removeValue(forKey: id) }
                if case .failed = state { self?.connections.removeValue(forKey: id) }
            }
        }
        connection.start(queue: .main)
        receiveRequest(on: connection)
    }

    /// A single `receive` is enough for a bare browser `GET` with no
    /// body -- confirmed sufficient for this narrow use (one request
    /// line, a handful of headers, all in one TCP segment in practice).
    /// Not a general-purpose HTTP parser; this app already shells out to
    /// real tools rather than reinventing them everywhere else, and a
    /// full HTTP/1.1 request parser would be exactly the kind of thing
    /// this app's "no dependencies, and don't reinvent what already
    /// exists" posture argues against building more of than necessary.
    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard error == nil, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { @MainActor in self?.respond(to: request, on: connection) }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let requestLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let prefix = "/\(pathToken)"
        let section = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil

        let response: Data
        switch section {
        case "":
            // Redirect to the trailing-slash form so the index page's own
            // relative nav links ("log", "path-discovery") resolve against
            // the token as a path segment, not get merged over it.
            response = Self.redirectResponse(to: "\(prefix)/")
        case "/":
            response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderIndexPage(hasReverseTrace: reverseTraceContent != nil))
        case "/log":
            if let snapshotStore {
                // Fresh query on every request, not a cached string --
                // see this type's own doc comment for why.
                response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderPage(snapshotStore: snapshotStore))
            } else {
                response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderNotYetAvailablePage(title: "Diagnostic Log", message: "Not started yet — click \u{201c}Diagnostic Log\u{2026}\u{201d} in Debug Tools."))
            }
        case "/network":
            if let networkViewModels {
                response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderNetworkPage(networkViewModels))
            } else {
                response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderNotYetAvailablePage(title: "Network", message: "Network monitoring hasn\u{2019}t reported in yet."))
            }
        case "/saas":
            if let saasMonitoring {
                response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderSaaSPage(saasMonitoring: saasMonitoring))
            } else {
                response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderNotYetAvailablePage(title: "SaaS Status", message: "SaaS monitoring hasn\u{2019}t reported in yet."))
            }
        case "/quickcheck":
            // Real content needs `QuickCheckRunner` (Phase 3) to actually
            // run the bundle and hand this server a result to render --
            // stubbed here so the nav link and route both exist now
            // rather than 404ing until that lands.
            response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderNotYetAvailablePage(title: "Quick Check", message: "No Quick Check run yet — click \u{201c}Run Quick Check\u{201d} in the popover."))
        case "/path-discovery":
            if let content = reverseTraceContent {
                // Not regenerated per-request the same way -- see
                // `showReverseTrace`'s own doc comment for why a live
                // Globalping round trip per page reload would be the
                // wrong tradeoff here.
                response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderReverseTracePage(target: content.target, results: content.results, confirmedAddress: content.confirmedAddress, siblingAddresses: content.siblingAddresses, frontsideHops: content.frontsideHops, networkName: content.networkName, geoHints: content.geoHints, scamperVerdicts: content.scamperVerdicts))
            } else {
                response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderNotYetAvailablePage(title: "Path Discovery", message: "No run yet — click \u{201c}Path Discovery\u{2026}\u{201d} in Debug Tools."))
            }
        default:
            response = Self.httpResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: "Not found.")
        }

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func redirectResponse(to location: String) -> Data {
        Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private static func httpResponse(status: String, contentType: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bodyData
    }

    private static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// This source file's own on-disk project root — shared by every
    /// asset/export path below. Same reasoning `exportReverseTraceHTML`
    /// already established: a Debug build always compiles straight from
    /// the local checkout it's part of, so `#filePath` is a more portable
    /// anchor than hardcoding this machine's path, and it's the only
    /// signal available at all -- a compiled app bundle has no other way
    /// to know where its own source checkout lives.
    private static func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NMS/Services
            .deletingLastPathComponent() // NMS
            .deletingLastPathComponent() // project root
    }

    /// Reads a page asset (CSS/JS) fresh from `LocalDiagnosticServerAssets/`
    /// on every call, not bundled into the compiled binary — raised
    /// directly ("can the rendering rules be in a separate file so that we
    /// don't need to rebuild? just patch the file at runtime?"), after
    /// several rounds of pure visual feedback (arrows vs. lines, font
    /// size, box layout) each needing a full Swift rebuild + relaunch to
    /// see. Editing the `.css`/`.js` file directly and reloading the
    /// browser tab is now enough — no rebuild, no relaunch. Falls back to
    /// `fallback` if the file's missing or unreadable (e.g. a typo mid-
    /// edit) rather than serving a broken page.
    private static func readAsset(_ relativePath: String, fallback: String) -> String {
        let url = projectRoot().appendingPathComponent("NMS/Services/LocalDiagnosticServerAssets").appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("LocalDiagnosticServer: couldn't read \(relativePath), using built-in fallback")
            return fallback
        }
        return content
    }

    /// One shared stylesheet for all four pages this server renders —
    /// raised directly ("can we make the webpage ui more 'mac-like'?
    /// similar buttons?"): system font instead of all-monospace, a
    /// native macOS color palette (incl. dark mode via
    /// `prefers-color-scheme`), card-style panels, and the nav rendered
    /// as a real segmented-control-style button group instead of plain
    /// text links — the same widget shape across all four pages, not
    /// just visually similar by coincidence. CSS custom properties so
    /// the semantic per-row colors (`var(--positive)` etc.) used inline
    /// by both `renderPage` and `renderReverseTracePage` stay in sync
    /// with light/dark mode automatically, rather than each page
    /// hardcoding its own hex values. `var`, not `let` -- re-reads
    /// `style.css` from disk on every access, see `readAsset`.
    private static var sharedCSS: String {
        readAsset("style.css", fallback: "body { font-family: -apple-system, sans-serif; }")
    }

    /// The `mermaid.initialize({...})` call for the topology diagram,
    /// same "read fresh, not compiled in" reasoning as `sharedCSS`.
    private static var mermaidInitScript: String {
        readAsset("mermaid-init.js", fallback: "mermaid.initialize({ startOnLoad: true });")
    }

    /// The topology diagram's three node colors (this Mac, path/hop
    /// devices, external vantage points) — raised directly, right after
    /// adding them ("can those parameters go in the config file?"), same
    /// "edit and reload, no rebuild" reasoning as `sharedCSS`/
    /// `mermaidInitScript`. Falls back to `TopologyBuilder.NodeColors
    /// .default` (the same values `topology-colors.json` ships with) on
    /// a missing file, bad JSON, or a bad hex value mid-edit.
    private static var topologyColors: TopologyBuilder.NodeColors {
        let url = projectRoot()
            .appendingPathComponent("NMS/Services/LocalDiagnosticServerAssets")
            .appendingPathComponent("topology-colors.json")
        guard let data = try? Data(contentsOf: url),
              let colors = try? JSONDecoder().decode(TopologyBuilder.NodeColors.self, from: data) else {
            print("LocalDiagnosticServer: couldn't read topology-colors.json, using built-in defaults")
            return .default
        }
        return colors
    }

    /// One row of the merged chronological log -- built from three
    /// different record types (`AppEventRecord`, `NetworkQualityRecord`,
    /// `WiFiStressTestRecord`), each contributing its own summary text
    /// and color, then sorted together by date. Merging at this level
    /// rather than three separate tables is the actual point: "what
    /// happened, in order" spans all three kinds of activity, not just
    /// state-change events.
    private struct LogRow {
        let date: Date
        let color: String
        let text: String
    }

    /// Plain, self-contained HTML -- inline `<style>`, no external
    /// stylesheet or script, matching the "no dependencies" posture at
    /// the page level too.
    private static func renderPage(snapshotStore: SnapshotStore) -> String {
        let neutral = "var(--label)", positive = "var(--positive)", negative = "var(--negative)"

        var rows: [LogRow] = snapshotStore.fetchRecentEvents(limit: 200).map { event in
            let kind = AppEventKind(rawValue: event.kind)
            let color: String
            switch kind?.polarity {
            case .positive: color = positive
            case .negative: color = negative
            case .neutral, .none: color = neutral
            }
            return LogRow(date: event.occurredAt, color: color, text: event.message)
        }

        // All three `NetworkQualityResult.Source` cases come back mixed
        // from one fetch -- see `fetchNetworkQualityHistory`'s own doc
        // comment, it isn't filtered by source the way
        // `fetchQuickCheckHistory` is.
        rows += snapshotStore.fetchNetworkQualityHistory(limit: 100).map { record in
            let text: String
            switch NetworkQualityResult.Source(rawValue: record.source) {
            case .quickCheck:
                text = "networkQuality quick check: \(record.combinedResponsivenessRPM.map { "\($0) RPM" } ?? "no result")"
            case .appleNetworkQuality:
                text = "Apple networkQuality: ↓\(rpmText(record.downloadResponsivenessRPM)) / ↑\(rpmText(record.uploadResponsivenessRPM)) RPM"
            case .cloudflareEndpoint, .none:
                text = "Speed Test: ↓\(mbpsText(record.downloadMbps)) / ↑\(mbpsText(record.uploadMbps)) Mbps"
            }
            return LogRow(date: record.testedAt, color: neutral, text: text)
        }

        rows += snapshotStore.fetchWiFiStressTestHistory(limit: 50).map { record in
            let rtt = record.avgRTTMs.map { String(format: "%.0f ms avg RTT", $0) } ?? "no RTT recorded"
            let color = record.packetLossPercent > 0 ? negative : positive
            return LogRow(
                date: record.testedAt,
                color: color,
                text: "Local Stress Test: \(String(format: "%.1f", record.packetLossPercent))% loss, \(rtt)"
            )
        }

        rows.sort { $0.date > $1.date }

        let logRowsHTML = rows.map { row in
            """
            <tr>
              <td class="ts">\(escape(row.date.formatted(date: .abbreviated, time: .standard)))</td>
              <td style="color: \(row.color)">\(escape(row.text))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let logBody = rows.isEmpty
            ? "<p class=\"empty\">Nothing recorded yet.</p>"
            : "<div class=\"card\"><table>\n\(logRowsHTML)\n</table></div>"

        // SNMP devices are a standing inventory, not a time series --
        // same "every device is relevant context, not just the newest
        // few" reasoning `export-diagnostic.sh` already uses, not merged
        // into the chronological log above.
        let devices = snapshotStore.fetchSNMPDevices(limit: 200)
        let deviceRowsHTML = devices.map { device in
            let hostnameCell = device.hostname.map { escape($0) } ?? "<span class=\"secondary\">—</span>"
            let webURLCell = device.webURL.map { url in "<a href=\"\(escape(url))\">\(escape(url))</a>" } ?? "<span class=\"secondary\">—</span>"
            return """
            <tr>
              <td>\(escape(device.displayName))</td>
              <td class="secondary">\(escape(device.ipAddress))</td>
              <td class="secondary">\(escape(device.uptimeDescription))</td>
              <td class="secondary">\(hostnameCell)</td>
              <td class="secondary">\(webURLCell)</td>
              <td class="secondary">\(escape(device.sysDescr))</td>
              <td class="ts">\(escape(device.lastSeenAt.formatted(date: .abbreviated, time: .standard)))</td>
            </tr>
            """
        }.joined(separator: "\n")
        let deviceBody = devices.isEmpty
            ? "<p class=\"empty\">No SNMP devices recorded.</p>"
            : "<div class=\"card\"><table>\n\(deviceRowsHTML)\n</table></div>"

        // New, 2026-08-12 -- DHCP lease history had no web route at all
        // before this (confirmed: nothing in this file read
        // fetchDHCPLeaseHistory). Same two-line-per-record shape
        // `DHCPHistoryTile.historyRows` already renders natively, since
        // that native tile is going away as part of the popover
        // conversion and this is its only remaining home.
        let leases = snapshotStore.fetchDHCPLeaseHistory(limit: 100)
        let leaseRowsHTML = leases.map { lease in
            """
            <tr>
              <td class="ts">\(escape(lease.observedAt.formatted(date: .abbreviated, time: .standard)))</td>
              <td>\(escape(lease.primaryDetail))<br><span class="secondary">\(escape(lease.secondaryDetail))</span></td>
            </tr>
            """
        }.joined(separator: "\n")
        let leaseBody = leases.isEmpty
            ? "<p class=\"empty\">No DHCP lease observed yet.</p>"
            : "<div class=\"card\"><table>\n\(leaseRowsHTML)\n</table></div>"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>NMS — Diagnostic Log</title>
        <style>\(sharedCSS)</style>
        </head>
        <body>
        <h1>NMS — Diagnostic Log</h1>
        \(navHTML(current: "log"))
        <p class="subtitle">Generated \(escape(Date().formatted(date: .abbreviated, time: .standard))) — reload this page to see anything that's happened since.</p>
        \(logBody)
        <h2>SNMP Devices</h2>
        \(deviceBody)
        <h2>DHCP History</h2>
        \(leaseBody)
        </body>
        </html>
        """
    }

    /// The ISP edge specifically is the interesting part — raised
    /// directly ("the focus is the isp edge router") — so the primary
    /// view is a comparison table across sources, not a wall of
    /// per-probe hop lists (kept below, in a collapsed `<details>`, for
    /// reference, not deleted). Each row is one probe's own "last real
    /// hop before its own destination" (`TracerouteViewModel
    /// .lastHopBeforeDestination`, the exact same extraction the
    /// corroboration check already uses), so convergence/divergence
    /// across independent vantage points is visible at a glance instead
    /// of requiring a mental diff across several separate tables.
    private static func renderReverseTracePage(
        target: String,
        results: [GlobalpingReverseTraceService.ProbeTraceResult],
        confirmedAddress: String?,
        siblingAddresses: [String: [String: String]],
        frontsideHops: [TracerouteHop],
        networkName: String?,
        geoHints: [String: String] = [:],
        scamperVerdicts: [String: Bool] = [:]
    ) -> String {
        let neutral = "var(--label)", positive = "var(--positive)", warning = "var(--warning)"

        // The confirmed hop's own hostname, looked up from this Mac's own
        // trace -- needed so the comparison table below can fall back to
        // a device-stem match, not just an exact address match. See
        // `TracerouteViewModel.reverseTraceCorroborates`'s own doc
        // comment for the real case this fixes: a multi-homed edge
        // router answering a different probe's inbound path on a
        // different interface address than the one this Mac's own trace
        // confirmed, which used to read as "no match" even though it's
        // the same physical device.
        let confirmedHostname = confirmedAddress.flatMap { address in
            frontsideHops.first(where: { $0.address == address })?.hostname
        }

        // Layered ISP-topology diagram -- merges frontside (this Mac's own
        // trace) and backside (these probes) by hop-distance, raised
        // directly with the exact layering ("bottom line is my network
        // router... keep expanding upwards until the 5 paths diverge").
        // See `TopologyBuilder`'s own doc comment for the full algorithm.
        let topology = TopologyBuilder.build(frontsideHops: frontsideHops, backsideResults: results, siblingAddresses: siblingAddresses)
        let mermaidText = TopologyBuilder.renderMermaid(tiers: topology.tiers, sources: topology.sources, colors: topologyColors, geoHints: geoHints)
        let topologySection = results.isEmpty ? "" : """
            <h2>ISP topology</h2>
            <div class="card diagram-card">
            <pre class="mermaid">
            \(mermaidText)
            </pre>
            </div>
            """

        struct EdgeRow {
            let probe: GlobalpingReverseTraceService.ProbeTraceResult
            let hop: GlobalpingReverseTraceService.ProbeTraceResult.Hop?
            let stem: String?
            let hasGap: Bool
        }
        let edgeRows: [EdgeRow] = results.map { probe in
            let hop = TracerouteViewModel.lastHopBeforeDestination(probe.hops, destination: probe.resolvedAddress)
            let stem = hop?.hostname.flatMap { GlobalpingReverseTraceService.deviceStem(fromHostname: $0) }
            let hasGap = TracerouteViewModel.hasGapBeforeDestination(probe.hops, destination: probe.resolvedAddress)
            return EdgeRow(probe: probe, hop: hop, stem: stem, hasGap: hasGap)
        }

        let comparisonRowsHTML = edgeRows.map { row -> String in
            let location = [row.probe.city, row.probe.country].compactMap { $0 }.joined(separator: ", ")
            let networkLabel = [row.probe.network, row.probe.asn.map { "ASN \($0)" }].compactMap { $0 }.joined(separator: " · ")
            let address = row.hop?.address ?? "*"
            let hostname = row.hop?.hostname.map { " (\($0))" } ?? ""
            let exactMatch = confirmedAddress != nil && row.hop?.address == confirmedAddress
            // Same device, different interface -- see the doc comment on
            // `confirmedHostname` above and on `TracerouteViewModel
            // .reverseTraceCorroborates` for the real case this covers.
            // Kept visually distinct from an exact match rather than
            // folded into the same "✓", since it's genuinely a weaker
            // claim (same box, not the same address this Mac itself
            // confirmed).
            let stemMatch = !exactMatch
                && TracerouteViewModel.reverseTraceCorroborates(
                    row.probe.hops,
                    destination: row.probe.resolvedAddress,
                    confirmedAddress: confirmedAddress ?? "",
                    confirmedHostname: confirmedHostname
                )
            // A gap means the real last hop is unknown -- not a confident
            // "confirmed different device," and not a confident match
            // either. Flagged distinctly rather than silently read as a
            // divergence, per the real Ashburn case this was built from:
            // the usual edge device just didn't reply to that probe, the
            // path likely continued past what's shown here.
            let matchCell: String
            let matchColor: String
            if row.hasGap {
                matchCell = "likely continues — no reply"
                matchColor = warning
            } else if confirmedAddress == nil {
                matchCell = "—"
                matchColor = neutral
            } else if exactMatch {
                matchCell = "✓"
                matchColor = positive
            } else if stemMatch {
                // A real, protocol-level second opinion on this exact
                // guess -- see `ScamperService`'s own doc comment.
                // Absent (not run, or scamper wasn't `.ready`) leaves
                // today's wording untouched; present but `false` is
                // real, worth surfacing information (the hostname-stem
                // heuristic guessed wrong), not hidden just because it
                // contradicts the guess above.
                let scamperNote: String
                if let verdict = row.hop?.address.flatMap({ scamperVerdicts[$0] }) {
                    scamperNote = verdict ? " — confirmed by scamper" : " — scamper disagrees"
                } else {
                    scamperNote = ""
                }
                matchCell = "✓ (same device, different interface)\(scamperNote)"
                matchColor = positive
            } else {
                matchCell = ""
                matchColor = neutral
            }
            let gapNote = row.hasGap ? " <span style=\"color: \(warning)\">(likely continues past here — this hop is the last one that replied, not necessarily the edge)</span>" : ""
            return """
            <tr>
              <td>\(escape(location.isEmpty ? "Unknown location" : location))<br><span class="secondary">\(escape(networkLabel))</span></td>
              <td>\(escape(address))\(escape(hostname))\(gapNote)</td>
              <td style="color: \(matchColor)">\(matchCell)</td>
            </tr>
            """
        }.joined(separator: "\n")
        let comparisonTable = results.isEmpty
            ? "<p class=\"empty\">No results.</p>"
            : """
              <div class="card">
              <table>
              <tr><th>Source</th><th>ISP edge candidate</th><th>Matches confirmed hop</th></tr>
              \(comparisonRowsHTML)
              </table>
              </div>
              """

        // Cross-reference every hop across every probe's *full* path
        // (not just the edge-candidate row) that shares a device stem
        // with an edge candidate -- these are addresses already present
        // in this same run's own data, not guessed. Merged with the
        // supplementary dig lookups (`siblingAddresses`), which fill in
        // a couple of patterns confirmed to reliably resolve but not
        // necessarily hit by any probe's own path.
        let edgeStems = Set(edgeRows.compactMap(\.stem))
        let knownAddressesHTML = edgeStems.sorted().map { stem -> String in
            var seen: [String: String] = [:] // hostname -> address
            for probe in results {
                for hop in probe.hops {
                    guard let hostname = hop.hostname, let address = hop.address,
                          GlobalpingReverseTraceService.deviceStem(fromHostname: hostname) == stem
                    else { continue }
                    seen[hostname] = address
                }
            }
            for (hostname, address) in siblingAddresses[stem] ?? [:] {
                seen[hostname] = address
            }
            let rows = seen.sorted(by: { $0.key < $1.key }).map { hostname, address in
                "<tr><td>\(escape(hostname))</td><td class=\"secondary\">\(escape(address))</td></tr>"
            }.joined(separator: "\n")
            return """
            <h3>\(escape(stem))</h3>
            <div class="card"><table>\(rows)</table></div>
            """
        }.joined(separator: "\n")
        let knownAddressesSection = edgeStems.isEmpty
            ? ""
            : """
              <h2>Known addresses near the edge</h2>
              <p class="secondary">Every address seen for the same device across this run's own data, plus a couple of confirmed-reliable supplementary lookups (bare device name, its <code>lo0.</code> form) — not a complete inventory, since numbered sibling interfaces (e.g. <code>305.ae0...</code>) can only be cross-referenced when already observed, not guessed.</p>
              \(knownAddressesHTML)
              """

        let fullPathsHTML = results.map { probe -> String in
            let location = [probe.city, probe.country].compactMap { $0 }.joined(separator: ", ")
            let networkLabel = [probe.network, probe.asn.map { "ASN \($0)" }].compactMap { $0 }.joined(separator: " · ")
            let hopRowsHTML = probe.hops.map { hop -> String in
                let address = hop.address ?? "*"
                let hostname = hop.hostname.map { " (\($0))" } ?? ""
                let rtt = hop.roundTripTimesMs.isEmpty
                    ? "—"
                    : hop.roundTripTimesMs.map { String(format: "%.1f ms", $0) }.joined(separator: " / ")
                return """
                <tr>
                  <td class="secondary">\(hop.hopNumber)</td>
                  <td>\(escape(address))\(escape(hostname))</td>
                  <td class="secondary">\(escape(rtt))</td>
                </tr>
                """
            }.joined(separator: "\n")
            let hopBody = probe.hops.isEmpty
                ? "<p class=\"empty\">No hops recorded.</p>"
                : "<div class=\"card\"><table>\n\(hopRowsHTML)\n</table></div>"
            let statusNote = probe.status == "finished" ? "" : "<p class=\"secondary\">Status: \(escape(probe.status))</p>"
            return """
            <h3>\(escape(location.isEmpty ? "Unknown location" : location))</h3>
            <p class="secondary">\(escape(networkLabel))\(probe.resolvedAddress.map { " · resolved \($0)" } ?? "")</p>
            \(statusNote)
            \(hopBody)
            """
        }.joined(separator: "\n")

        let networkSuffix = networkName.map { " — \($0)" } ?? ""
        let networkNote = networkName.map { " on <strong>\(escape($0))</strong>" } ?? ""
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>NMS — Path Discovery\(escape(networkSuffix))</title>
        <style>\(sharedCSS)</style>
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        <script>\(mermaidInitScript)</script>
        </head>
        <body>
        <h1>NMS — Path Discovery\(escape(networkSuffix))</h1>
        \(navHTML(current: "path-discovery"))
        <p class="subtitle">Reverse traceroute toward \(escape(target))\(networkNote), from \(results.count) external vantage point\(results.count == 1 ? "" : "s") via Globalping. Generated \(escape(Date().formatted(date: .abbreviated, time: .standard))) — this page is a snapshot of that one run, not live.</p>
        \(topologySection)
        <h2>ISP edge, compared across sources</h2>
        \(comparisonTable)
        \(knownAddressesSection)
        <details>
        <summary>Full path per source</summary>
        \(fullPathsHTML)
        </details>
        </body>
        </html>
        """
    }

    /// Ported directly from `NetworkTile.connectionLayersLowToHigh` (see
    /// that property's own doc comment for the full per-layer reasoning
    /// — kept there in full rather than repeated here, since it's the
    /// authoritative version until `NetworkTile.swift` is deleted).
    /// Ordered low (most fundamental) to high (most dependent on
    /// everything below it working first).
    private static func connectionLayersLowToHigh(_ vm: NetworkViewModels) -> [ConnectionLayer] {
        let info = vm.viewModel.currentInterface

        func checkDetail(for check: ConnectivityCheck) -> String {
            check.success ? String(format: "%.0f ms", check.latencyMs ?? 0) : "unreachable"
        }
        func standardLayer(id: String, label: String) -> ConnectionLayer {
            let check = vm.connectivity.checks.first { $0.label == label }
            return ConnectionLayer(
                id: id,
                label: label,
                detail: check.map(checkDetail) ?? "Not checked",
                status: check.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: check?.correlatedWithChange ?? false
            )
        }
        func networkDisplay(_ info: NetworkInterfaceInfo) -> String {
            let type = info.isWiFi ? "Wi-Fi" : "Ethernet"
            let label = vm.networkIdentity.currentNetwork?.label
            let name: String? = info.isWiFi
                ? vm.wifiSSID.currentSSID
                : (label?.isEmpty == false ? label : nil)
            guard let name else { return type }
            return "\(name) \(type)"
        }
        func ipAddressDisplay(_ info: NetworkInterfaceInfo) -> String {
            guard let ip = info.ipAddress else { return "—" }
            guard let mask = info.subnetMask, let prefix = SubnetCalculator.prefixLength(subnetMask: mask) else {
                return ip
            }
            return "\(ip)/\(prefix)"
        }

        let networkLayer: ConnectionLayer
        if let info {
            let hasName = vm.wifiSSID.currentSSID != nil
            let knownNetworkSuffix = vm.networkIdentity.currentNetwork.map { network in
                " · \(vm.networkIdentity.isNewNetwork ? "new" : "seen \(network.timesSeen)×")"
            } ?? ""
            let detail = networkDisplay(info) + " · \(ipAddressDisplay(info))" + knownNetworkSuffix
            networkLayer = ConnectionLayer(id: "network", label: "Network", detail: detail, status: (info.isWiFi && !hasName) ? .unknown : .healthy)
        } else {
            networkLayer = ConnectionLayer(id: "network", label: "Network", detail: "Down", status: .unhealthy)
        }

        let routerCheck = vm.connectivity.checks.first { $0.label == OverallStatus.routerLabel }
        let localRouterLayer: ConnectionLayer
        if info == nil {
            localRouterLayer = ConnectionLayer(id: "localRouter", label: OverallStatus.routerLabel, detail: "—", status: .unhealthy)
        } else {
            let addressPrefix = info?.routerAddress.map { "\($0) · " } ?? ""
            localRouterLayer = ConnectionLayer(
                id: "localRouter",
                label: OverallStatus.routerLabel,
                detail: addressPrefix + (routerCheck.map(checkDetail) ?? "Not checked"),
                status: routerCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: routerCheck?.correlatedWithChange ?? false,
                url: info?.routerAddress.map { "http://\($0)" }
            )
        }

        let publicIPCheck = vm.connectivity.checks.first { $0.label == OverallStatus.publicIPLabel }
        let publicIPLayer: ConnectionLayer
        if info == nil {
            publicIPLayer = ConnectionLayer(id: "publicIP", label: OverallStatus.publicIPLabel, detail: "—", status: .unhealthy)
        } else if let currentPublicIP = vm.publicIP.currentIP {
            publicIPLayer = ConnectionLayer(
                id: "publicIP",
                label: OverallStatus.publicIPLabel,
                detail: "\(currentPublicIP) · " + (publicIPCheck.map(checkDetail) ?? "Not checked"),
                status: publicIPCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: publicIPCheck?.correlatedWithChange ?? false
            )
        } else {
            publicIPLayer = ConnectionLayer(id: "publicIP", label: OverallStatus.publicIPLabel, detail: "Not checked", status: .unknown)
        }

        let ispPrefix = vm.ispIdentity.shortOrganizationName.map { "\($0) · " } ?? ""
        let peRouterLayer: ConnectionLayer
        if info == nil {
            peRouterLayer = ConnectionLayer(id: "peRouter", label: OverallStatus.peRouterLabel, detail: "—", status: .unhealthy)
        } else if vm.traceroute.monitoredHop == nil {
            peRouterLayer = ConnectionLayer(
                id: "peRouter",
                label: OverallStatus.peRouterLabel,
                detail: ispPrefix + "Not confirmed",
                status: .unknown,
                url: vm.ispIdentity.statusPageURL
            )
        } else {
            let peRouterCheck = vm.connectivity.checks.first { $0.label == OverallStatus.peRouterLabel }
            peRouterLayer = ConnectionLayer(
                id: "peRouter",
                label: OverallStatus.peRouterLabel,
                detail: ispPrefix + (peRouterCheck.map(checkDetail) ?? "Not checked"),
                status: peRouterCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
                correlatedWithChange: peRouterCheck?.correlatedWithChange ?? false,
                url: vm.ispIdentity.statusPageURL
            )
        }

        let internetLayer = standardLayer(id: "internet", label: OverallStatus.internetLabel)
        let dnsCheck = vm.connectivity.checks.first { $0.label == OverallStatus.dnsLabel }
        let dnsAddressPrefix = info?.dnsServer.map { "\($0) · " } ?? ""
        let dnsLayer = ConnectionLayer(
            id: "dns",
            label: OverallStatus.dnsLabel,
            detail: dnsAddressPrefix + (dnsCheck.map(checkDetail) ?? "Not checked"),
            status: dnsCheck.map { $0.success ? .healthy : .unhealthy } ?? .unknown,
            correlatedWithChange: dnsCheck?.correlatedWithChange ?? false
        )
        let httpLayer = standardLayer(id: "http", label: OverallStatus.httpLabel)

        return [networkLayer, localRouterLayer, publicIPLayer, peRouterLayer, internetLayer, dnsLayer, httpLayer]
    }

    private static func statusColor(_ status: LayerStatus) -> String {
        switch status {
        case .healthy: return "var(--positive)"
        case .unhealthy: return "var(--negative)"
        case .unknown: return "var(--secondary)"
        }
    }

    /// Full page: the core layer grid (ported from `NetworkTile`, above),
    /// plus DHCP status (ported from `DHCPStatusRow`), DDNS (ported from
    /// `DDNSRow`), a Wi-Fi/Ethernet glance card (ported from
    /// `WiFiTile`/`EthernetTile`), and Path to Internet's current hop
    /// list — everything that used to be this app's most data-dense
    /// native tile, now a page instead.
    private static func renderNetworkPage(_ vm: NetworkViewModels) -> String {
        let layers = connectionLayersLowToHigh(vm)
        let layerRowsHTML = layers.map { layer in
            let label = layer.url.map { "<a href=\"\(escape($0))\">\(escape(layer.label))</a>" } ?? escape(layer.label)
            return """
            <tr>
              <td style="color: \(statusColor(layer.status))">●</td>
              <td>\(label)</td>
              <td class="secondary">\(escape(layer.detail))</td>
            </tr>
            """
        }.joined(separator: "\n")

        // DHCP -- ported from DHCPStatusRow.color/detailText.
        let dhcpColor: String
        let dhcpDetail: String
        if vm.dhcpLease.isFallenBackToLinkLocal {
            dhcpColor = "var(--negative)"; dhcpDetail = "Link-local fallback"
        } else if vm.dhcpLease.isRenewalOverdue {
            dhcpColor = "var(--negative)"; dhcpDetail = "Renewal overdue"
        } else if vm.dhcpLease.history.isEmpty {
            dhcpColor = "var(--secondary)"; dhcpDetail = "Not checked"
        } else if let lastChange = vm.dhcpLease.lastGenuineChangeAt, Date().timeIntervalSince(lastChange) < 600 {
            dhcpColor = "var(--warning)"; dhcpDetail = "Changed recently"
        } else {
            dhcpColor = "var(--positive)"; dhcpDetail = "Nominal"
        }

        // DDNS -- ported from DDNSRow.summaryColor/summaryText.
        let ddnsSection: String
        if vm.ddns.statuses.isEmpty {
            ddnsSection = ""
        } else {
            let states = vm.ddns.statuses.compactMap(\.syncState)
            let ddnsColor: String
            if states.contains(.stale) { ddnsColor = "var(--negative)" }
            else if states.contains(.blockedByCGNAT) { ddnsColor = "var(--warning)" }
            else if states.count == vm.ddns.statuses.count, states.allSatisfy({ $0 == .current }) { ddnsColor = "var(--positive)" }
            else { ddnsColor = "var(--secondary)" }
            let name = vm.ddns.statuses.count == 1 ? vm.ddns.statuses[0].hostname : "\(vm.ddns.statuses.count) hostnames"
            ddnsSection = """
            <tr>
              <td style="color: \(ddnsColor)">●</td>
              <td>DDNS</td>
              <td class="secondary">\(escape(name))</td>
            </tr>
            """
        }

        // Wi-Fi/Ethernet glance -- ported from WiFiTile/EthernetTile.
        let glanceBody: String
        if let ssid = vm.wifiSSID.currentSSID {
            let signal = vm.wifiSSID.currentRSSI.map { rssi -> String in
                if let noise = vm.wifiSSID.currentNoise {
                    return "\(rssi) dBm (SNR \(rssi - noise) dB)"
                }
                return "\(rssi) dBm"
            } ?? "—"
            let channel = vm.wifiSSID.currentChannelNumber.map { number -> String in
                vm.wifiSSID.currentChannelBand.map { "\(number) (\($0))" } ?? "\(number)"
            } ?? "—"
            let security = vm.wifiSSID.currentSecurity ?? "—"
            glanceBody = "<p class=\"secondary\">Wi-Fi \(escape(ssid)) · \(escape(signal)) · Ch \(escape(channel)) · \(escape(security))</p>"
        } else if let speed = vm.ethernetLink.currentSpeedMbps {
            let duplex = vm.ethernetLink.currentDuplex.map { " · \($0)" } ?? ""
            glanceBody = "<p class=\"secondary\">Ethernet \(Int(speed)) Mbps\(escape(duplex))</p>"
        } else {
            glanceBody = "<p class=\"empty\">No active link.</p>"
        }

        // Path to Internet -- current confirmed hop list.
        let hopRowsHTML = vm.traceroute.hops.map { hop -> String in
            let address = hop.address ?? "*"
            let hostname = hop.hostname.map { " (\(escape($0)))" } ?? ""
            let rtt = hop.roundTripMs.map { String(format: "%.1f ms", $0) } ?? "—"
            let confirmed = hop.hopNumber == vm.traceroute.monitoredHopNumber ? " <span class=\"secondary\">★ ISP edge</span>" : ""
            return """
            <tr>
              <td class="secondary">\(hop.hopNumber)</td>
              <td>\(escape(address))\(hostname)\(confirmed)</td>
              <td class="secondary">\(escape(rtt))</td>
            </tr>
            """
        }.joined(separator: "\n")
        let hopsBody = vm.traceroute.hops.isEmpty
            ? "<p class=\"empty\">No trace run yet.</p>"
            : "<div class=\"card\"><table>\n\(hopRowsHTML)\n</table></div>"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>NMS — Network</title>
        <style>\(sharedCSS)</style>
        </head>
        <body>
        <h1>NMS — Network</h1>
        \(navHTML(current: "network"))
        <div class="card">
        <table>
        \(layerRowsHTML)
        <tr>
          <td style="color: \(dhcpColor)">●</td>
          <td>DHCP</td>
          <td class="secondary">\(escape(dhcpDetail))</td>
        </tr>
        \(ddnsSection)
        </table>
        </div>
        \(glanceBody)
        <h2>Path to Internet</h2>
        \(hopsBody)
        </body>
        </html>
        """
    }

    /// Same curated/user-added split `SaaSStatusTile` already renders
    /// natively — this is that tile's content moved to the web, not a
    /// redesign, per the popover conversion (the tile itself is being
    /// deleted; the popover's MyApps status line shows only a one-line
    /// worst-of-N rollup, this page is where the full per-service detail
    /// it used to show natively now lives).
    private static func renderSaaSPage(saasMonitoring: SaaSMonitoringViewModel) -> String {
        func rowsHTML(_ statuses: [SaaSMonitoringViewModel.ServiceStatus]) -> String {
            statuses.map { status in
                let color: String
                switch status.indicator {
                case .none: color = "var(--positive)"
                case .minor, .maintenance: color = "var(--warning)"
                case .major, .critical: color = "var(--negative)"
                case .unknown: color = "var(--label)"
                }
                return """
                <tr>
                  <td><span style="color: \(color)">●</span> \(escape(status.name))</td>
                  <td class="secondary">\(escape(status.description))</td>
                  <td><a href="\(escape(status.url))">\(escape(status.url))</a></td>
                </tr>
                """
            }.joined(separator: "\n")
        }
        let curatedBody = saasMonitoring.statuses.isEmpty
            ? "<p class=\"empty\">No services monitored yet.</p>"
            : "<div class=\"card\"><table>\n\(rowsHTML(saasMonitoring.statuses))\n</table></div>"
        let userAddedSection = saasMonitoring.userAddedStatuses.isEmpty
            ? ""
            : """
              <h2>Your Own Sites</h2>
              <p class="secondary">A plain reachability check, not a real vendor status page — a genuinely weaker signal than the curated list above.</p>
              <div class="card"><table>\n\(rowsHTML(saasMonitoring.userAddedStatuses))\n</table></div>
              """
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>NMS — SaaS Status</title>
        <style>\(sharedCSS)</style>
        </head>
        <body>
        <h1>NMS — SaaS Status</h1>
        \(navHTML(current: "saas"))
        \(curatedBody)
        \(userAddedSection)
        </body>
        </html>
        """
    }

    /// Shared nav shown atop every page, so any one of them can jump to
    /// another without going back through Debug Tools -- the actual
    /// "single webpage with built-in selection" fix, not just pages that
    /// happen to share a server. Rendered as a real segmented-control
    /// button group (`.segmented`, styled in `sharedCSS`) rather than
    /// plain text links -- raised directly ("more mac-like? similar
    /// buttons?"). `current` is `"log"`/`"path-discovery"`/`nil`
    /// (index), and marks that segment active.
    private static func navHTML(current: String?) -> String {
        func segment(_ href: String, _ label: String) -> String {
            "<a href=\"\(href)\" class=\"\(href == current ? "active" : "")\">\(label)</a>"
        }
        return """
        <div class="segmented">\(segment("network", "Network"))\(segment("saas", "SaaS"))\(segment("quickcheck", "Quick Check"))\(segment("log", "Diagnostic Log"))\(segment("path-discovery", "Path Discovery"))</div>
        """
    }

    private static func renderIndexPage(hasReverseTrace: Bool) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>NMS — Debug Tools</title>
        <style>\(sharedCSS)</style>
        </head>
        <body>
        <h1>NMS — Debug Tools</h1>
        \(navHTML(current: nil))
        <p class="subtitle">\(hasReverseTrace ? "Path Discovery has results from the last run." : "Path Discovery hasn\u{2019}t been run yet this session.")</p>
        </body>
        </html>
        """
    }

    private static func renderNotYetAvailablePage(title: String, message: String) -> String {
        let current: String
        switch title {
        case "Diagnostic Log": current = "log"
        case "Network": current = "network"
        case "SaaS Status": current = "saas"
        case "Quick Check": current = "quickcheck"
        default: current = "path-discovery"
        }
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>NMS — \(escape(title))</title>
        <style>\(sharedCSS)</style>
        </head>
        <body>
        <h1>NMS — \(escape(title))</h1>
        \(navHTML(current: current))
        <p class="empty">\(escape(message))</p>
        </body>
        </html>
        """
    }

    private static func rpmText(_ value: Int?) -> String { value.map(String.init) ?? "—" }
    private static func mbpsText(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "—" }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
