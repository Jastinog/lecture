import Foundation

/// A stretch of listening, in epoch seconds: `[start, end]` in JSON.
struct ListeningSession: Codable, Hashable {
    var start: Double
    var end: Double

    /// Stretches closer than this are one: a pause, a seek.
    static let gap: Double = 120
    /// Kept per lecture and day, the latest.
    static let limit = 100

    init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        start = try c.decode(Double.self)
        end = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(start)
        try c.encode(end)
    }

    /// `sessions` sorted, those that meet or nearly do joined, the latest
    /// `limit` kept. The server joins them the same way.
    static func merged(_ sessions: [ListeningSession]) -> [ListeningSession] {
        var merged: [ListeningSession] = []
        for session in sessions.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, session.start - last.end <= gap {
                merged[merged.count - 1].end = max(last.end, session.end)
            } else {
                merged.append(session)
            }
        }
        return Array(merged.suffix(limit))
    }
}

/// A lecture listened to on a day, for the calendar.
struct ListeningEntry: Codable, Identifiable, Hashable {
    /// The topic's list card, so the calendar opens it (a selection's, when
    /// the lecture was played from one).
    var topic: Topic
    let lectureID: Int
    var lectureTitle: String
    /// Time spent listening that day: real time while playing, whatever the speed.
    var seconds: Double
    /// When it was last heard that day (epoch seconds).
    var lastHeard: Double
    /// When it was heard, for the day view. Nil in entries kept before.
    var sessions: [ListeningSession]? = nil

    var id: String { "\(topic.id)-\(lectureID)" }

    var lastHeardDate: Date { Date(timeIntervalSince1970: lastHeard) }
    /// "21:05".
    var lastHeardTime: String { lastHeardDate.formatted(date: .omitted, time: .shortened) }
}

/// What was listened to on each day, synced across the listener's devices
/// (`SyncEngine`): each commit sends the time heard since. The player adds
/// the time as it plays (`add`) and commits it with its progress saves, so
/// the views showing it redraw every few seconds rather than every tick.
@MainActor
final class ListeningLog: ObservableObject {
    static let shared = ListeningLog()
    private let file = "listening.json"
    private let version = 1
    /// Days kept: two years.
    private let maxDays = 731
    /// Listening to a lecture this long on a day counts as playing it, once,
    /// for "Trending".
    static let playThreshold: Double = 30

    /// Entries by day ("2026-10-15"), each day's most recent first.
    @Published private(set) var days: [String: [ListeningEntry]] = [:] {
        didSet { lectures = Self.latest(in: days) }
    }
    /// Every lecture heard, once — the day it was heard last — the latest first.
    private(set) var lectures: [ListeningEntry] = []
    /// Time heard since the last commit, by day and entry.
    private var pending: [String: [String: ListeningEntry]] = [:]

    private init() {
        days = Store.load([String: [ListeningEntry]].self, from: file) ?? [:]
        lectures = Self.latest(in: days)
    }

    /// Adds `seconds` heard of the lecture at `date`.
    func add(_ seconds: Double, topic: Topic, lecture: Lecture, index: Int, at date: Date) {
        let day = Self.key(date)
        let now = date.timeIntervalSince1970
        let entry = ListeningEntry(topic: topic, lectureID: lecture.id,
                                   lectureTitle: lecture.displayTitle(at: index),
                                   seconds: seconds, lastHeard: now,
                                   sessions: [ListeningSession(start: now - seconds, end: now)])
        if var held = pending[day]?[entry.id] {
            held.seconds += seconds
            held.lastHeard = entry.lastHeard
            held.sessions = ListeningSession.merged((held.sessions ?? []) + (entry.sessions ?? []))
            pending[day]?[entry.id] = held
        } else {
            pending[day, default: [:]][entry.id] = entry
        }
        let before = (days[day]?.first { $0.id == entry.id }?.seconds ?? 0)
            + (pending[day]?[entry.id]?.seconds ?? 0) - seconds
        if before < Self.playThreshold, before + seconds >= Self.playThreshold {
            Task.detached { try? await API.library.reportPlay(lectureID: lecture.id) }
        }
    }

    /// Moves what was heard since the last commit into `days` and saves.
    func commit() {
        guard !pending.isEmpty else { return }
        SyncEngine.shared.heard(pending.flatMap { day, heard in heard.values.map { (day, $0) } })
        for (day, heard) in pending {
            var entries = days[day] ?? []
            for entry in heard.values {
                if let i = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[i].seconds += entry.seconds
                    entries[i].lastHeard = entry.lastHeard
                    entries[i].sessions = ListeningSession.merged((entries[i].sessions ?? []) + (entry.sessions ?? []))
                    entries[i].topic = entry.topic
                } else {
                    entries.append(entry)
                }
            }
            days[day] = entries.sorted { $0.lastHeard > $1.lastHeard }
        }
        pending = [:]
        if days.count > maxDays {
            for day in days.keys.sorted().prefix(days.count - maxDays) { days[day] = nil }
        }
        Store.save(days, version: version, to: file)
    }

    func clear() {
        SyncEngine.shared.listeningCleared(days.flatMap { day, entries in entries.map { (day, $0) } })
        pending = [:]
        days = [:]
        Store.save(days, version: version, to: file)
    }

    /// A lecture's total on a day from the listener's other devices; nil
    /// removes it.
    struct Change {
        let day: String
        let topicID: Int
        let lectureID: Int
        let entry: ListeningEntry?
    }

    /// Totals from the listener's other devices; not synced back.
    func apply(_ changes: [Change]) {
        guard !changes.isEmpty else { return }
        for change in changes {
            let id = "\(change.topicID)-\(change.lectureID)"
            var entries = (days[change.day] ?? []).filter { $0.id != id }
            if let entry = change.entry { entries.append(entry) }
            days[change.day] = entries.isEmpty ? nil : entries.sorted { $0.lastHeard > $1.lastHeard }
        }
        Store.save(days, version: version, to: file)
    }

    /// Forgets a lecture heard, every day it was, here and on the listener's
    /// other devices.
    func remove(id: String) {
        let removed = days.flatMap { day, entries in entries.filter { $0.id == id }.map { (day: day, entry: $0) } }
        guard !removed.isEmpty else { return }
        SyncEngine.shared.listeningCleared(removed)
        for (day, _) in removed {
            pending[day]?[id] = nil
            let rest = days[day]?.filter { $0.id != id } ?? []
            days[day] = rest.isEmpty ? nil : rest
        }
        Store.save(days, version: version, to: file)
    }

    private static func latest(in days: [String: [ListeningEntry]]) -> [ListeningEntry] {
        var latest: [String: ListeningEntry] = [:]
        for entries in days.values {
            for entry in entries where entry.seconds > 0 && entry.lastHeard > latest[entry.id]?.lastHeard ?? -1 {
                latest[entry.id] = entry
            }
        }
        return latest.values.sorted { $0.lastHeard > $1.lastHeard }
    }

    func entries(on date: Date) -> [ListeningEntry] { days[Self.key(date)] ?? [] }

    func seconds(on date: Date) -> Double { entries(on: date).reduce(0) { $0 + $1.seconds } }

    /// Whether anything was heard that day (a minute at least, so a lecture
    /// only opened doesn't mark it).
    func listened(on date: Date) -> Bool { seconds(on: date) >= 60 }

    /// Days in a row with listening, up to today. Today without any yet
    /// doesn't break it: the day isn't over.
    func streak(until today: Date = Date()) -> Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: today)
        if !listened(on: day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while listened(on: day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// "2026-10-15" in the phone's calendar and time zone.
    static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
