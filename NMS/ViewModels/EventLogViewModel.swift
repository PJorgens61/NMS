import Foundation
import Combine

@MainActor
final class EventLogViewModel: ObservableObject {
    @Published private(set) var events: [AppEventRecord] = [] {
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
