import Foundation
import UIKit
import os

/// A listening position as the server keeps it (`apps/listeners/sync.py`).
struct ProgressRecord: Codable, Equatable {
    var topicID: Int
    /// When it was saved or removed on a phone (epoch seconds): the newest wins.
    var updatedAt: Double
    var deleted = false
    var index = 0
    var lectureID: Int?
    var time: Double = 0
    var fraction: Double = 0

    enum CodingKeys: String, CodingKey {
        case topicID = "topic_id", updatedAt = "updated_at", deleted, index
        case lectureID = "lecture_id", time, fraction
    }

    init(topicID: Int, entry: ProgressStore.Entry) {
        self.topicID = topicID
        updatedAt = entry.savedAt ?? 0
        index = entry.index
        lectureID = entry.lectureID
        time = entry.time
        fraction = entry.fraction
    }

    init(removing topicID: Int, at date: Double) {
        self.topicID = topicID
        updatedAt = date
        deleted = true
    }

    var entry: ProgressStore.Entry {
        ProgressStore.Entry(index: index, time: time, fraction: fraction, savedAt: updatedAt,
                            lectureID: lectureID)
    }
}

/// A topic in the history, with the card it shows.
struct HistoryRecord: Codable, Equatable {
    var topicID: Int
    var updatedAt: Double
    var deleted = false
    /// Nil for a removal, or a card this version can't read.
    var topic: Topic?

    enum CodingKeys: String, CodingKey {
        case topicID = "topic_id", updatedAt = "updated_at", deleted, topic
    }

    init(_ item: RecentTopic) {
        topicID = item.id
        updatedAt = item.updatedAt
        topic = item.summary
    }

    init(removing topicID: Int, at date: Double) {
        self.topicID = topicID
        updatedAt = date
        deleted = true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topicID = try c.decode(Int.self, forKey: .topicID)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        // A card from a later version mustn't fail the whole answer.
        topic = try? c.decodeIfPresent(Topic.self, forKey: .topic)
    }
}

struct SyncChanges: Codable {
    var progress: [ProgressRecord] = []
    var history: [HistoryRecord] = []
}

/// `POST sync/`: the changes made here, and the cursor of the last answer.
struct SyncRequest: Encodable {
    var since: Int
    var changes: SyncChanges
}

/// The changes made on other devices since, and the cursor to send next time.
struct SyncResponse: Decodable {
    var cursor: Int
    var changes: SyncChanges
}

/// Keeps the listening positions and the history the same on all of a
/// listener's devices. The phone stays the source of truth and works offline:
/// its stores report each change here (`progressSaved`, `historyRemoved`…),
/// which waits in an outbox (`sync-outbox.json`) until it's sent. Sent at
/// launch, on coming back to the app and leaving it, after a pause, and a
/// minute after a change while playing. What comes back is merged into the
/// stores, the newest change winning.
@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    private struct State: Codable {
        /// The listener the outbox and cursor are for. Another one (a new
        /// registration) sends everything on the phone again.
        var listenerID: UUID?
        var cursor = 0
        /// Unsent changes by topic id, the latest of each.
        var progress: [String: ProgressRecord] = [:]
        var history: [String: HistoryRecord] = [:]
    }

    private static let log = Logger(subsystem: "com.personal.lecture", category: "sync")
    private let file = "sync-outbox.json"
    private let version = 1
    /// How long a change waits for others to go with it.
    private let delay: Duration = .seconds(60)
    /// Records of a kind per request; the server takes up to 1000.
    private let batch = 500

    private var state: State
    private var running = false
    private var again = false
    private var scheduled: Task<Void, Never>?

    private init() { state = Store.load(State.self, from: file) ?? State() }

    // MARK: Changes on this phone

    func progressSaved(topicID: Int, entry: ProgressStore.Entry) {
        state.progress[String(topicID)] = ProgressRecord(topicID: topicID, entry: entry)
        changed()
    }

    func progressRemoved(topicIDs: [Int]) {
        let now = Date().timeIntervalSince1970
        for id in topicIDs { state.progress[String(id)] = ProgressRecord(removing: id, at: now) }
        changed()
    }

    func historyRecorded(_ item: RecentTopic) {
        state.history[String(item.id)] = HistoryRecord(item)
        changed()
    }

    func historyRemoved(topicIDs: [Int]) {
        let now = Date().timeIntervalSince1970
        for id in topicIDs { state.history[String(id)] = HistoryRecord(removing: id, at: now) }
        changed()
    }

    private func changed() {
        persist()
        guard scheduled == nil else { return }
        scheduled = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            sync()
        }
    }

    // MARK: Sending

    /// Sends the outbox and merges what comes back, now.
    func sync() {
        scheduled?.cancel()
        scheduled = nil
        Task { await run() }
    }

    /// `sync` on leaving the app, given the time to finish in the background.
    func syncInBackground() {
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask(withName: "Sync") { app.endBackgroundTask(task) }
        scheduled?.cancel()
        scheduled = nil
        Task {
            await run()
            app.endBackgroundTask(task)
        }
    }

    private func run() async {
        guard !running else {
            again = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            again = false
            await pass()
        } while again
    }

    private func pass() async {
        guard let listener = Account.shared.listenerID else { return }
        if state.listenerID != listener {
            state.listenerID = listener
            state.cursor = 0
            enqueueEverything()
        }
        while true {
            let progress = Array(state.progress.values.prefix(batch))
            let history = Array(state.history.values.prefix(batch))
            let request = SyncRequest(since: state.cursor,
                                      changes: SyncChanges(progress: progress, history: history))
            let response: SyncResponse
            do {
                response = try await API.library.sync(request)
            } catch {
                Self.log.error("Couldn't sync: \(String(describing: error), privacy: .public)")
                return
            }
            // Registered again meanwhile: the answer is for a listener gone.
            guard state.listenerID == Account.shared.listenerID else { return }
            // Sent, unless changed again while on the way.
            for record in progress where state.progress[String(record.topicID)] == record {
                state.progress[String(record.topicID)] = nil
            }
            for record in history where state.history[String(record.topicID)] == record {
                state.history[String(record.topicID)] = nil
            }
            merge(response.changes)
            state.cursor = response.cursor
            persist()
            if progress.count < batch, history.count < batch { return }
        }
    }

    /// Everything on the phone, for a listener the server hasn't heard from
    /// here: the first sync, or a new registration.
    private func enqueueEverything() {
        for (id, entry) in ProgressStore.all() where state.progress[String(id)] == nil {
            state.progress[String(id)] = ProgressRecord(topicID: id, entry: entry)
        }
        for item in RecentsStore.shared.items where state.history[String(item.id)] == nil {
            state.history[String(item.id)] = HistoryRecord(item)
        }
    }

    /// Applies the changes from other devices that are newer than this
    /// phone's, its unsent ones included.
    private func merge(_ changes: SyncChanges) {
        var positions: [Int: ProgressStore.Entry?] = [:]
        for record in changes.progress {
            let local = state.progress[String(record.topicID)]?.updatedAt
                ?? ProgressStore.entry(topicID: record.topicID).map { $0.savedAt ?? 0 }
            if let local, local >= record.updatedAt { continue }
            positions[record.topicID] = record.deleted ? .some(nil) : record.entry
        }
        ProgressStore.apply(positions)

        var recorded: [RecentTopic] = [], removed: Set<Int> = []
        for record in changes.history {
            let local = state.history[String(record.topicID)]?.updatedAt
                ?? RecentsStore.shared.items.first { $0.id == record.topicID }?.updatedAt
            if let local, local >= record.updatedAt { continue }
            if record.deleted {
                removed.insert(record.topicID)
            } else if let topic = record.topic {
                recorded.append(RecentTopic(summary: topic, fraction: 0, updatedAt: record.updatedAt))
            }
        }
        RecentsStore.shared.apply(recorded: recorded, removed: removed)
    }

    private func persist() { Store.save(state, version: version, to: file) }
}
