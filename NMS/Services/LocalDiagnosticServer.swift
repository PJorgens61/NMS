import Foundation
import Network

#if DEBUG
/// A local-only, on-demand HTTP server serving a simple chronological log
/// of recent diagnostic history as a plain web page — the first, simplest
/// use case of the local-HTTP-server idea in `PUNCHLIST.md` ("A
/// local-only HTTP server"), built first specifically to prove the server
/// plumbing before the two heavier, shipped-feature use cases (Apple
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
/// The page is rendered once, at `start()`, from whatever's in the store
/// at that moment — not live-updating. A field-test session is reviewed
/// after the fact, not watched in real time; keeping this one-shot
/// avoids any need to hop back to the main actor from the listener's own
/// background queue on every request.
@MainActor
final class LocalDiagnosticServer {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pageHTML = ""
    private var pathToken = ""
    private var idleTimer: Timer?

    private static let idleTimeout: TimeInterval = 600 // 10 minutes, matches no other magic number in this app -- picked as "long enough to actually read the page, short enough not to linger."

    var isRunning: Bool { listener != nil }

    /// Starts the server (replacing any already running) and returns the
    /// URL to open, once the listener is actually bound and its ephemeral
    /// port is known. `nil` on failure -- logged, not thrown, since this
    /// is a debug convenience, not a code path anything else depends on.
    /// Takes events directly rather than a `SnapshotStore` reference --
    /// `EventLogViewModel.events` is already loaded in memory wherever
    /// this is triggered from, so no new store dependency is needed.
    func start(events: [AppEventRecord]) async -> URL? {
        stop()

        pathToken = Self.randomToken()
        pageHTML = Self.renderPage(events: events)

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
        if path == "/\(pathToken)" || path == "/\(pathToken)/" {
            response = Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: pageHTML)
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

    /// Plain, self-contained HTML -- inline `<style>`, no external
    /// stylesheet or script, matching the "no dependencies" posture at
    /// the page level too. Newest first, same convention `EventsTile`/
    /// `NetworkReviewView` already use for the same underlying data.
    private static func renderPage(events: [AppEventRecord]) -> String {
        let rows = events.map { event -> String in
            let kind = AppEventKind(rawValue: event.kind)
            let color: String
            switch kind?.polarity {
            case .positive: color = "#1FAA59"
            case .negative: color = "#E0453A"
            case .neutral, .none: color = "#0F1729"
            }
            let timestamp = event.occurredAt.formatted(date: .abbreviated, time: .standard)
            return """
            <tr>
              <td class="ts">\(escape(timestamp))</td>
              <td style="color: \(color)">\(escape(event.message))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let body = events.isEmpty
            ? "<p class=\"empty\">No events recorded yet.</p>"
            : "<table>\n\(rows)\n</table>"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>NMS — Diagnostic Log</title>
        <style>
          body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: #F5F7FB; color: #0F1729; padding: 2rem; }
          h1 { font-size: 1.1rem; }
          .subtitle { color: #5B6B85; font-size: 0.85rem; margin-bottom: 1.5rem; }
          table { border-collapse: collapse; width: 100%; font-size: 0.85rem; }
          td { padding: 0.35rem 0.75rem 0.35rem 0; border-bottom: 1px solid rgba(15,23,41,0.08); vertical-align: top; }
          .ts { color: #5B6B85; white-space: nowrap; }
          .empty { color: #5B6B85; }
        </style>
        </head>
        <body>
        <h1>NMS — Diagnostic Log</h1>
        <p class="subtitle">Generated \(escape(Date().formatted(date: .abbreviated, time: .standard))) — a one-time snapshot, not live. Reload starts a new server instance.</p>
        \(body)
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
#endif
