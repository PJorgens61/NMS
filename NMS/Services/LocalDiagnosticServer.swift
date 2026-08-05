import Foundation
import Network

#if DEBUG
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
/// Debug-only, same category as `FailureInjector`/`UIStateLogger` — dev/
/// testing tooling, not a shipped end-user feature, per that punchlist
/// item's own "worth scoping as debug-only" reasoning.
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
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var snapshotStore: SnapshotStore?
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
    /// run with no confirmed hop yet.
    func showReverseTrace(
        target: String,
        results: [GlobalpingReverseTraceService.ProbeTraceResult],
        confirmedAddress: String? = nil,
        siblingAddresses: [String: [String: String]] = [:]
    ) async -> URL? {
        reverseTraceContent = ReverseTraceContent(target: target, results: results, confirmedAddress: confirmedAddress, siblingAddresses: siblingAddresses)
        Self.exportReverseTraceHTML(target: target, results: results, confirmedAddress: confirmedAddress, siblingAddresses: siblingAddresses)
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
        siblingAddresses: [String: [String: String]]
    ) {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NMS/Services
            .deletingLastPathComponent() // NMS
            .deletingLastPathComponent() // project root
        let dir = projectRoot.appendingPathComponent("script/diagnostic-exports")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = dir.appendingPathComponent("path-discovery-\(formatter.string(from: Date())).html")

        let html = renderReverseTracePage(target: target, results: results, confirmedAddress: confirmedAddress, siblingAddresses: siblingAddresses)
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
    private func ensureRunning() async -> URL? {
        if let listener, listener.state == .ready, let port = listener.port {
            return URL(string: "http://127.0.0.1:\(port.rawValue)/\(pathToken)")
        }
        stop()
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

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
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
        case "/path-discovery":
            if let content = reverseTraceContent {
                // Not regenerated per-request the same way -- see
                // `showReverseTrace`'s own doc comment for why a live
                // Globalping round trip per page reload would be the
                // wrong tradeoff here.
                response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderReverseTracePage(target: content.target, results: content.results, confirmedAddress: content.confirmedAddress, siblingAddresses: content.siblingAddresses))
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
    /// hardcoding its own hex values.
    private static let sharedCSS = """
    :root {
      --bg: #F5F5F7; --card: #FFFFFF; --label: #1D1D1F; --secondary: #6E6E73;
      --separator: rgba(0,0,0,0.08); --accent: #007AFF; --positive: #34C759;
      --negative: #FF3B30; --warning: #C77800; --nav-bg: rgba(120,120,128,0.16);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1C1C1E; --card: #2C2C2E; --label: #F5F5F7; --secondary: #98989D;
        --separator: rgba(255,255,255,0.12); --accent: #0A84FF; --positive: #30D158;
        --negative: #FF453A; --warning: #FF9F0A; --nav-bg: rgba(120,120,128,0.28);
      }
    }
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      background: var(--bg); color: var(--label); margin: 0; padding: 2.5rem;
      -webkit-font-smoothing: antialiased;
    }
    a { color: var(--accent); text-decoration: none; }
    h1 { font-size: 1.2rem; font-weight: 600; margin: 0 0 4px; }
    h2 { font-size: 0.95rem; font-weight: 600; margin: 1.75rem 0 0.5rem; }
    h3 { font-size: 0.8rem; font-weight: 600; margin: 1.1rem 0 0.3rem; color: var(--secondary); }
    .subtitle { color: var(--secondary); font-size: 0.85rem; margin: 0 0 1.5rem; }
    .empty { color: var(--secondary); font-size: 0.85rem; }

    .segmented { display: inline-flex; gap: 2px; background: var(--nav-bg); border-radius: 8px; padding: 2px; margin: 0 0 1.5rem; }
    .segmented a { padding: 5px 14px; border-radius: 6px; font-size: 12px; font-weight: 500; color: var(--label); }
    .segmented a.active { background: var(--card); color: var(--accent); box-shadow: 0 1px 1px rgba(0,0,0,0.15); }

    .card { background: var(--card); border-radius: 12px; padding: 0.25rem 1.25rem; box-shadow: 0 1px 2px rgba(0,0,0,0.06); margin-bottom: 1rem; }

    table { border-collapse: collapse; width: 100%; font-size: 0.85rem; }
    th { text-align: left; padding: 0.5rem 0.75rem 0.5rem 0; color: var(--secondary); font-weight: 600; border-bottom: 1px solid var(--separator); }
    td { padding: 0.5rem 0.75rem 0.5rem 0; border-bottom: 1px solid var(--separator); vertical-align: top; }
    tr:last-child td { border-bottom: none; }
    .ts { color: var(--secondary); white-space: nowrap; }
    .secondary { color: var(--secondary); }

    summary { cursor: pointer; font-size: 0.85rem; margin-top: 1.25rem; color: var(--secondary); font-weight: 500; }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--nav-bg); padding: 1px 5px; border-radius: 4px; font-size: 0.85em; }
    """

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
            """
            <tr>
              <td>\(escape(device.displayName))</td>
              <td class="secondary">\(escape(device.ipAddress))</td>
              <td class="secondary">\(escape(device.uptimeDescription))</td>
              <td class="ts">\(escape(device.lastSeenAt.formatted(date: .abbreviated, time: .standard)))</td>
            </tr>
            """
        }.joined(separator: "\n")
        let deviceBody = devices.isEmpty
            ? "<p class=\"empty\">No SNMP devices recorded.</p>"
            : "<div class=\"card\"><table>\n\(deviceRowsHTML)\n</table></div>"

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
        siblingAddresses: [String: [String: String]]
    ) -> String {
        let neutral = "var(--label)", positive = "var(--positive)", warning = "var(--warning)"

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
            let matches = confirmedAddress != nil && row.hop?.address == confirmedAddress
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
            } else if matches {
                matchCell = "✓"
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

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>NMS — Path Discovery</title>
        <style>\(sharedCSS)</style>
        </head>
        <body>
        <h1>NMS — Path Discovery</h1>
        \(navHTML(current: "path-discovery"))
        <p class="subtitle">Reverse traceroute toward \(escape(target)), from \(results.count) external vantage point\(results.count == 1 ? "" : "s") via Globalping. Generated \(escape(Date().formatted(date: .abbreviated, time: .standard))) — this page is a snapshot of that one run, not live.</p>
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
        <div class="segmented">\(segment("log", "Diagnostic Log"))\(segment("path-discovery", "Path Discovery"))</div>
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
        let current = title == "Diagnostic Log" ? "log" : "path-discovery"
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
#endif
