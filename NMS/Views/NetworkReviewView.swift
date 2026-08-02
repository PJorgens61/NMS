import SwiftUI
import AppKit

/// A read-only look at a past network's recorded Events/SNMP Devices/DHCP
/// History/Wi-Fi telemetry — opened from `KnownNetworksView`'s "Review"
/// button, for a field technician revisiting a site who wants to see what
/// this Mac last saw there without being on that network right now. No
/// Scan or Refresh here, deliberately: those verbs only mean something
/// while actually connected to the network in question. See
/// `NetworkReviewViewModel` for why this reads via explicit-fingerprint
/// `SnapshotStore` overloads rather than the live `currentNetworkFingerprint`
/// path every other view in this app uses.
struct NetworkReviewView: View {
    @StateObject private var viewModel: NetworkReviewViewModel
    @Environment(\.dismiss) private var dismiss

    /// True only on the throwaway copy handed to `ImageRenderer` (see
    /// `generateReport`), never on the live sheet. Same shape and
    /// reasoning as `ContentView.isCapturingScreenshot`: a plain stored
    /// property, not `@Environment`/`@State` (confirmed not to propagate
    /// through `ImageRenderer`'s render pass there), and needed because
    /// `ImageRenderer` doesn't render `ScrollView` content at all
    /// off-screen — not clipped, absent — so the four sections would
    /// render as a blank report without this swapping them to a plain
    /// unclipped `VStack` for the capture only.
    var isCapturingScreenshot = false

    /// A copy with `isCapturingScreenshot` set — `self` is a struct, so
    /// this is a plain value copy that leaves the live sheet untouched.
    private var capturingScreenshotCopy: NetworkReviewView {
        var capturing = self
        capturing.isCapturingScreenshot = true
        return capturing
    }

    init(network: KnownNetwork, snapshotStore: SnapshotStore) {
        _viewModel = StateObject(wrappedValue: NetworkReviewViewModel(network: network, snapshotStore: snapshotStore))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            reportSections

            HStack {
                Button("Generate Report") { generateReport() }
                    .accessibilityIdentifier("networkReview.generateReport")
                    .accessibilityHint("Saves an image of this network's recorded history to the Desktop area used for screenshots")
                Spacer()
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("networkReview.close")
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 420)
        .onAppear { viewModel.load() }
    }

    /// Split out from `body` so `generateReport` can render the same four
    /// sections through `ImageRenderer` without also capturing `header`
    /// twice or fighting `ScrollView`'s own off-screen-rendering quirk —
    /// see `isCapturingScreenshot`'s doc comment.
    @ViewBuilder
    private var reportSections: some View {
        if isCapturingScreenshot {
            sections
        } else {
            ScrollView {
                sections
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Events", isEmpty: viewModel.events.isEmpty, emptyText: "No events recorded on this network") {
                eventRows
            }
            section("SNMP Devices", isEmpty: viewModel.snmpDevices.isEmpty, emptyText: "No SNMP devices recorded on this network") {
                snmpRows
            }
            section("DHCP History", isEmpty: viewModel.dhcpHistory.isEmpty, emptyText: "No DHCP leases recorded on this network") {
                dhcpRows
            }
            section("Wi-Fi", isEmpty: viewModel.wifiSamples.isEmpty, emptyText: "No Wi-Fi samples recorded on this network") {
                wifiRows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Renders the whole sheet (header, sections, and this very button
    /// row — same as `ContentView`'s own screenshot capturing its footer
    /// too) through `ImageRenderer` and reveals the saved PNG in Finder.
    /// `.buttonStyle(.plain)`/a real background are `ScreenshotService`'s
    /// quirks 2/3 (native bordered buttons render as broken-image
    /// placeholders; there's no implicit background off-screen) — same
    /// treatment `ScreenshotViewModel.capture` already gives the popover.
    /// Silently does nothing on failure, matching every other capture
    /// path in this app: a friend/technician losing this convenience is
    /// far less costly than a crash or a blocking alert.
    private func generateReport() {
        let renderable = capturingScreenshotCopy
            .buttonStyle(.plain)
            .background(Color(nsColor: .windowBackgroundColor))
        guard let filename = ScreenshotService.capture(renderable, filenamePrefix: "NMS-Review-\(sanitizedDisplayName)") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ScreenshotService.directory.appendingPathComponent(filename)])
    }

    /// `displayName` (e.g. "MyWifi (Wi-Fi)") isn't filesystem-safe as-is —
    /// collapses anything that isn't alphanumeric to a single `-`.
    private var sanitizedDisplayName: String {
        displayName.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .font(.title3.weight(.semibold))
            Text("\(viewModel.network.routerMAC) on \(viewModel.network.subnet)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("seen \(viewModel.network.timesSeen)× · last \(viewModel.network.lastSeenAt, format: .dateTime.month().day().year().hour().minute())")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Same label → Wi-Fi SSID → "Ethernet" fallback as
    /// `KnownNetworksView.displayName(for:)`, reading `viewModel.wifiSamples`
    /// (already fetched, newest-first) instead of a second store query.
    private var displayName: String {
        if let label = viewModel.network.label, !label.isEmpty {
            return label
        }
        if let ssid = viewModel.wifiSamples.first?.ssid, !ssid.isEmpty {
            return "\(ssid) (Wi-Fi)"
        }
        return "Ethernet"
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        isEmpty: Bool,
        emptyText: String,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                rows()
            }
        }
    }

    private var eventRows: some View {
        ForEach(viewModel.events) { event in
            HStack {
                Text(event.message)
                    .font(.system(size: 12))
                    .foregroundStyle(eventColor(for: event))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func eventColor(for event: AppEventRecord) -> Color {
        guard let kind = AppEventKind(rawValue: event.kind) else { return .primary }
        switch kind.polarity {
        case .positive: return .green
        case .negative: return .red
        case .neutral: return .primary
        }
    }

    private var snmpRows: some View {
        ForEach(viewModel.snmpDevices) { device in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(device.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(device.uptimeDescription)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                Text(device.sysDescr)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dhcpRows: some View {
        ForEach(viewModel.dhcpHistory) { record in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(record.primaryDetail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(record.observedAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                Text(record.secondaryDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // `AppKitToolTip` is an `NSViewRepresentable` —
                    // `ImageRenderer` substitutes a yellow "prohibited"
                    // glyph for it (see `ScreenshotService`'s quirk 4), so
                    // this disables during `generateReport`'s capture the
                    // same way every other `appKitToolTip` call in this
                    // app already does.
                    .appKitToolTip(DHCPLeaseRecord.transactionHelpText, enabled: !isCapturingScreenshot)
            }
        }
    }

    private var wifiRows: some View {
        ForEach(viewModel.wifiSamples) { sample in
            HStack {
                Text(sample.ssid ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(wifiDetail(sample))
                    .foregroundStyle(.secondary)
                Text(sample.sampledAt, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
    }

    private func wifiDetail(_ sample: WiFiSampleRecord) -> String {
        var parts: [String] = []
        if let rssi = sample.rssi { parts.append("\(rssi) dBm") }
        if let band = sample.channelBand, let channel = sample.channelNumber {
            parts.append("\(band) ch \(channel)")
        }
        if let phyRateMbps = sample.phyRateMbps { parts.append("\(Int(phyRateMbps)) Mbps") }
        return parts.joined(separator: " · ")
    }
}
