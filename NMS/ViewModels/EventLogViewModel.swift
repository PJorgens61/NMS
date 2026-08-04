import Foundation

@MainActor
@Observable
final class EventLogViewModel {
    private(set) var events: [AppEventRecord] = [] {
        didSet { UIStateLogger.log("EventLogViewModel.events", events) }
    }

    private let snapshotStore: SnapshotStore

    init(snapshotStore: SnapshotStore) {
        self.snapshotStore = snapshotStore
        refresh()
    }

    func refresh() {
        events = snapshotStore.fetchRecentEvents()
    }
}
