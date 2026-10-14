import Foundation
import UIKit
import os

/// Unsent changes, by kind and key: the latest of each, except the calendar's,
/// which add up.
struct SyncOutbox: Codable {
    var progress: [String: ProgressRecord] = [:]
    var history: [String: HistoryRecord] = [:]
    var bookmarks: [String: BookmarkRecord] = [:]
    var shelf: [String: ShelfRecord] = [:]
    var rates: [String: RateRecord] = [:]
    var pins: [String: PinRecord] = [:]
    var languages: [String: LanguageRecord] = [:]
    var settings: [String: SettingRecord] = [:]
    var listening: [String: ListeningRecord] = [:]
}

/// Keeps what the listener does in the app the same on all their devices:
/// positions, history, the calendar, bookmarks, the shelf, speeds, pinned
/// lecturers and their languages. The phone stays the source of truth and
/// works offline: its stores report each change here (`record`), which waits
/// in an outbox (`sync-state.json`) until it's sent. Sent at launch, on coming
/// back to the app and leaving it, after a pause, and a minute after a change
/// while playing. What comes back is merged into the stores, the newest
/// change winning, and the calendar's time added up.
@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    private struct State: Codable {
        /// The listener the outbox and cursor are for. Another one (a new
        /// registration) sends everything on the phone again.
        var listenerID: UUID?
        var cursor = 0
        var outbox = SyncOutbox()
    }

    private static let log = Logger(subsystem: "com.personal.lecture", category: "sync")
    private let file = "sync-state.json"
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

    /// A change to send: replaces any unsent one of the same key.
    func record<R: SyncRecord>(_ record: R, in kind: WritableKeyPath<SyncOutbox, [String: R]>) {
        state.outbox[keyPath: kind][record.key] = record
        changed()
    }

    /// Removals of `keys` now, each made by `removal`.
    func remove<R: SyncRecord, Key>(_ keys: some Sequence<Key>, in kind: WritableKeyPath<SyncOutbox, [String: R]>,
                                    as removal: (Key, Double) -> R) {
        let now = Date().timeIntervalSince1970
        for key in keys {
            let record = removal(key, now)
            state.outbox[keyPath: kind][record.key] = record
        }
        changed()
    }

    /// Time heard since the last commit, by day: added to what's unsent.
    func heard(_ entries: [(day: String, entry: ListeningEntry)]) {
        guard !entries.isEmpty else { return }
        for (day, entry) in entries {
            let new = ListeningRecord(day: day, entry)
            if var held = state.outbox.listening[new.key] {
                held.seconds += new.seconds
                held.lastHeard = new.lastHeard
                held.topic = new.topic
                held.lectureTitle = new.lectureTitle
                state.outbox.listening[new.key] = held
            } else {
                state.outbox.listening[new.key] = new
            }
        }
        changed()
    }

    /// The calendar cleared: each day starts over on every device.
    func listeningCleared(_ entries: [(day: String, entry: ListeningEntry)]) {
        for (day, entry) in entries {
            var reset = ListeningRecord(day: day, entry)
            reset.seconds = 0
            reset.reset = true
            state.outbox.listening[reset.key] = reset
        }
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
            let sent = outgoing()
            let response: SyncResponse
            do {
                response = try await API.library.sync(SyncRequest(since: state.cursor, changes: sent))
            } catch {
                Self.log.error("Couldn't sync: \(String(describing: error), privacy: .public)")
                return
            }
            // Registered again meanwhile: the answer is for a listener gone.
            guard state.listenerID == Account.shared.listenerID else { return }
            markSent(sent)
            merge(response.changes)
            state.cursor = response.cursor
            persist()
            if !hasMore(after: sent) { return }
        }
    }

    /// Up to `batch` of each kind's unsent changes.
    private func outgoing() -> SyncChanges {
        let box = state.outbox
        func take<R>(_ records: [String: R]) -> [R] { Array(records.values.prefix(batch)) }
        return SyncChanges(progress: take(box.progress), history: take(box.history),
                           bookmarks: take(box.bookmarks), shelf: take(box.shelf),
                           rates: take(box.rates), pins: take(box.pins),
                           languages: take(box.languages), settings: take(box.settings),
                           listening: take(box.listening))
    }

    private func hasMore(after sent: SyncChanges) -> Bool {
        [sent.progress.count, sent.history.count, sent.bookmarks.count, sent.shelf.count,
         sent.rates.count, sent.pins.count, sent.languages.count, sent.settings.count,
         sent.listening.count].contains(batch)
    }

    /// Drops what was sent from the outbox, unless it changed again while on
    /// the way; the calendar keeps only the time heard since.
    private func markSent(_ sent: SyncChanges) {
        func drop<R: SyncRecord>(_ records: [R], from kind: WritableKeyPath<SyncOutbox, [String: R]>) {
            for record in records where state.outbox[keyPath: kind][record.key] == record {
                state.outbox[keyPath: kind][record.key] = nil
            }
        }
        drop(sent.progress, from: \.progress)
        drop(sent.history, from: \.history)
        drop(sent.bookmarks, from: \.bookmarks)
        drop(sent.shelf, from: \.shelf)
        drop(sent.rates, from: \.rates)
        drop(sent.pins, from: \.pins)
        drop(sent.languages, from: \.languages)
        drop(sent.settings, from: \.settings)
        for record in sent.listening {
            guard var held = state.outbox.listening[record.key] else { continue }
            held.seconds -= record.seconds
            // The server has started the day over already.
            held.reset = nil
            state.outbox.listening[record.key] = held.seconds > 0.01 ? held : nil
        }
    }

    /// Everything on the phone, for a listener the server hasn't heard from
    /// here: the first sync, or a new registration.
    private func enqueueEverything() {
        func add<R: SyncRecord>(_ records: [R], to kind: WritableKeyPath<SyncOutbox, [String: R]>) {
            for record in records where state.outbox[keyPath: kind][record.key] == nil {
                state.outbox[keyPath: kind][record.key] = record
            }
        }
        add(ProgressStore.all().map { ProgressRecord(topicID: $0.key, entry: $0.value) }, to: \.progress)
        add(RecentsStore.shared.items.map(HistoryRecord.init), to: \.history)
        add(BookmarkStore.shared.items.map { BookmarkRecord($0, at: $0.createdAt) }, to: \.bookmarks)
        add(ShelfStore.shared.items.map { ShelfRecord($0, at: $0.addedAt) }, to: \.shelf)
        add(AudioPlayer.shared.topicRates.map { RateRecord(topicID: $0.key, updatedAt: 0, rate: $0.value) },
            to: \.rates)
        add(PinStore.shared.items.map(PinRecord.init), to: \.pins)
        add(LanguageChoiceStore.shared.all.map { LanguageRecord(lecturerID: $0.key, language: $0.value, at: 0) },
            to: \.languages)
        if let rate = AudioPlayer.shared.storedDefaultRate {
            add([SettingRecord(name: SettingRecord.defaultRate, updatedAt: 0, value: rate)], to: \.settings)
        }
        // All the time heard, as yet unsent; the outbox's own adds to it.
        for (day, entries) in ListeningLog.shared.days {
            for entry in entries {
                let record = ListeningRecord(day: day, entry)
                if state.outbox.listening[record.key]?.reset == true { continue }
                state.outbox.listening[record.key] = record
            }
        }
    }

    /// Whether a change from another device beats this phone's: newer than
    /// its unsent one, and than `local` (when the store keeps a time).
    private func wins<R: SyncRecord>(_ record: R, over kind: KeyPath<SyncOutbox, [String: R]>,
                                     local: Double? = nil) -> Bool {
        guard let mine = state.outbox[keyPath: kind][record.key]?.updatedAt ?? local else { return true }
        return record.updatedAt > mine
    }

    /// Applies the changes from other devices that beat this phone's.
    private func merge(_ changes: SyncChanges) {
        var positions: [Int: ProgressStore.Entry?] = [:]
        for record in changes.progress
        where wins(record, over: \.progress, local: ProgressStore.entry(topicID: record.topicID).map { $0.savedAt ?? 0 }) {
            positions[record.topicID] = record.deleted ? .some(nil) : record.entry
        }
        ProgressStore.apply(positions)

        var recorded: [RecentTopic] = [], forgotten: Set<Int> = []
        for record in changes.history
        where wins(record, over: \.history, local: RecentsStore.shared.items.first { $0.id == record.topicID }?.updatedAt) {
            if record.deleted {
                forgotten.insert(record.topicID)
            } else if let topic = record.topic.topic {
                recorded.append(RecentTopic(summary: topic, fraction: 0, updatedAt: record.updatedAt))
            }
        }
        RecentsStore.shared.apply(recorded: recorded, removed: forgotten)

        let marks = changes.bookmarks.filter { wins($0, over: \.bookmarks) }
        BookmarkStore.shared.apply(saved: marks.filter { !$0.deleted }.map(\.bookmark),
                                   removed: Set(marks.filter(\.deleted).map(\.id)))

        let shelved = changes.shelf.filter { wins($0, over: \.shelf) }
        ShelfStore.shared.apply(saved: shelved.filter { !$0.deleted }.compactMap(\.item),
                                removed: Set(shelved.filter(\.deleted).map(\.topicID)))

        var rates: [Int: Double?] = [:]
        for record in changes.rates where wins(record, over: \.rates) {
            rates[record.topicID] = record.deleted ? .some(nil) : record.rate
        }
        let defaultRate = changes.settings.last {
            $0.name == SettingRecord.defaultRate && !$0.deleted && wins($0, over: \.settings)
        }?.value
        AudioPlayer.shared.applySynced(rates: rates, defaultRate: defaultRate)

        let pins = changes.pins.filter { wins($0, over: \.pins) }
        PinStore.shared.apply(saved: pins.filter { !$0.deleted }.map(\.pin),
                              removed: Set(pins.filter(\.deleted).map(\.lecturerID)))

        var languages: [Int: String?] = [:]
        for record in changes.languages where wins(record, over: \.languages) {
            languages[record.lecturerID] = record.deleted ? .some(nil) : record.language
        }
        LanguageChoiceStore.shared.apply(languages)

        // The day's total, plus what's heard here and not yet sent.
        var days: [ListeningLog.Change] = []
        for record in changes.listening {
            let unsent = state.outbox.listening[record.key]
            var total = record
            if unsent?.reset == true {
                total.seconds = 0
            } else if record.deleted == true, unsent == nil {
                days.append(.init(day: record.day, topicID: record.topicID, lectureID: record.lectureID, entry: nil))
                continue
            }
            total.seconds += unsent?.seconds ?? 0
            if let unsent, unsent.lastHeard > total.lastHeard { total.lastHeard = unsent.lastHeard }
            guard let entry = total.entry else { continue }
            days.append(.init(day: record.day, topicID: record.topicID, lectureID: record.lectureID,
                              entry: total.seconds > 0 ? entry : nil))
        }
        ListeningLog.shared.apply(days)
    }

    private func persist() { Store.save(state, version: version, to: file) }
}
