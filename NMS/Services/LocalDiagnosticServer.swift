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
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var snapshotStore: SnapshotStore?
    private var pathToken = ""
    private var idleTimer: Timer?

    private static let idleTimeout: TimeInterval = 600 // 10 minutes, matches no other magic number in this app -- picked as "long enough to actually read the page, short enough not to linger."

    var isRunning: Bool { listener != nil }

    /// Starts the server (replacing any already running) and returns the
    /// URL to open, once the listener is actually bound and its ephemeral
    /// port is known. `nil` on failure -- logged, not thrown, since this
    /// is a debug convenience, not a code path anything else depends on.
    func start(snapshotStore: SnapshotStore) async -> URL? {
        stop()

        pathToken = Self.randomToken()
        self.snapshotStore = snapshotStore

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

        let response: Data
        if (path == "/\(pathToken)" || path == "/\(pathToken)/"), let snapshotStore {
            // Fresh query on every request, not a cached string -- see
            // this type's own doc comment for why.
            response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.renderPage(snapshotStore: snapshotStore))
        } else {
            response = Self.httpResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: "Not found.")
        }

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func httpResponse(status: String, contentType: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bodyData
    }

    private static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
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
        let neutral = "#0F1729", positive = "#1FAA59", negative = "#E0453A", secondary = "#5B6B85"

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
            : "<table>\n\(logRowsHTML)\n</table>"

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
            : "<table>\n\(deviceRowsHTML)\n</table>"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>NMS — Diagnostic Log</title>
        <style>
          body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: #F5F7FB; color: \(neutral); padding: 2rem; }
          h1 { font-size: 1.1rem; }
          h2 { font-size: 0.95rem; margin-top: 2rem; }
          .subtitle { color: \(secondary); font-size: 0.85rem; margin-bottom: 1.5rem; }
          table { border-collapse: collapse; width: 100%; font-size: 0.85rem; }
          td { padding: 0.35rem 0.75rem 0.35rem 0; border-bottom: 1px solid rgba(15,23,41,0.08); vertical-align: top; }
          .ts { color: \(secondary); white-space: nowrap; }
          .secondary { color: \(secondary); }
          .empty { color: \(secondary); }
        </style>
        </head>
        <body>
        <h1>NMS — Diagnostic Log</h1>
        <p class="subtitle">Generated \(escape(Date().formatted(date: .abbreviated, time: .standard))) — reload this page to see anything that's happened since.</p>
        \(logBody)
        <h2>SNMP Devices</h2>
        \(deviceBody)
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
