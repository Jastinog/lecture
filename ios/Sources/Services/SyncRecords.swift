import Foundation

/// The records the app syncs, as the server keeps them (`apps/listeners/sync.py`):
/// snake-case keys, epoch seconds, `deleted` for a removal. The newest
/// `updatedAt` wins.
protocol SyncRecord: Codable, Equatable {
    /// What the record is about, unique within its kind.
    var key: String { get }
    var updatedAt: Double { get }
}

/// A topic card inside a record: one this version can't read (a later
/// version's) comes back nil instead of failing the whole answer.
struct Card: Codable, Equatable {
    var topic: Topic?

    init(_ topic: Topic?) { self.topic = topic }

    init(from decoder: Decoder) throws { topic = try? Topic(from: decoder) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(topic)
    }
}

/// A listening position.
struct ProgressRecord: SyncRecord {
    var topicID: Int
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

    var key: String { String(topicID) }

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
struct HistoryRecord: SyncRecord {
    var topicID: Int
    var updatedAt: Double
    var deleted = false
    var topic = Card(nil)

    enum CodingKeys: String, CodingKey {
        case topicID = "topic_id", updatedAt = "updated_at", deleted, topic
    }

    var key: String { String(topicID) }

    init(_ item: RecentTopic) {
        topicID = item.id
        updatedAt = item.updatedAt
        topic = Card(item.summary)
    }

    init(removing topicID: Int, at date: Double) {
        self.topicID = topicID
        updatedAt = date
        deleted = true
    }
}

struct BookmarkRecord: SyncRecord {
    var id: UUID
    var updatedAt: Double
    var deleted = false
    var topicID = 0
    var lectureID: Int?
    var index = 0
    var time: Double = 0
    var chapterTitle = ""
    var note = ""
    var createdAt: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, updatedAt = "updated_at", deleted, topicID = "topic_id", lectureID = "lecture_id"
        case index, time, chapterTitle = "chapter_title", note, createdAt = "created_at"
    }

    var key: String { id.uuidString }

    init(_ mark: Bookmark, at date: Double) {
        id = mark.id
        updatedAt = date
        topicID = mark.topicID
        lectureID = mark.lectureID
        index = mark.index
        time = mark.time
        chapterTitle = mark.chapterTitle
        note = mark.note
        createdAt = mark.createdAt
    }

    init(removing id: UUID, at date: Double) {
        self.id = id
        updatedAt = date
        deleted = true
    }

    var bookmark: Bookmark {
        Bookmark(id: id, topicID: topicID, index: index, time: time, chapterTitle: chapterTitle,
                 note: note, createdAt: createdAt, lectureID: lectureID)
    }
}

struct ShelfRecord: SyncRecord {
    var topicID: Int
    var updatedAt: Double
    var deleted = false
    var status = ""
    var topic = Card(nil)
    var addedAt: Double = 0

    enum CodingKeys: String, CodingKey {
        case topicID = "topic_id", updatedAt = "updated_at", deleted, status, topic
        case addedAt = "added_at"
    }

    var key: String { String(topicID) }

    init(_ item: ShelfTopic, at date: Double) {
        topicID = item.id
        updatedAt = date
        status = item.status.rawValue
        topic = Card(item.summary)
        addedAt = item.addedAt
    }

    init(removing topicID: Int, at date: Double) {
        self.topicID = topicID
        updatedAt = date
        deleted = true
    }

    /// Nil for a card or a status this version can't read.
    var item: ShelfTopic? {
        guard let summary = topic.topic, let status = ShelfStatus(rawValue: status) else { return nil }
        return ShelfTopic(summary: summary, status: status, addedAt: addedAt)
    }
}

/// A topic's own speed; a removal goes back to the default.
struct RateRecord: SyncRecord {
    var topicID: Int
    var updatedAt: Double
    var deleted = false
    var rate: Double = 1

    enum CodingKeys: String, CodingKey {
        case topicID = "topic_id", updatedAt = "updated_at", deleted, rate
    }

    var key: String { String(topicID) }
}

struct PinRecord: SyncRecord {
    var lecturerID: Int
    var updatedAt: Double
    var deleted = false
    var name = ""
    var photoURL = ""

    enum CodingKeys: String, CodingKey {
        case lecturerID = "lecturer_id", updatedAt = "updated_at", deleted, name
        case photoURL = "photo_url"
    }

    var key: String { String(lecturerID) }

    init(_ pin: PinnedLecturer) {
        lecturerID = pin.id
        updatedAt = pin.pinnedAt
        name = pin.name
        photoURL = pin.photoURL?.absoluteString ?? ""
    }

    init(removing lecturerID: Int, at date: Double) {
        self.lecturerID = lecturerID
        updatedAt = date
        deleted = true
    }

    var pin: PinnedLecturer {
        PinnedLecturer(id: lecturerID, name: name, photoURL: URL(string: photoURL), pinnedAt: updatedAt)
    }
}

/// The language a lecturer is narrowed to; a removal is every language.
struct LanguageRecord: SyncRecord {
    var lecturerID: Int
    var updatedAt: Double
    var deleted = false
    var language = ""

    enum CodingKeys: String, CodingKey {
        case lecturerID = "lecturer_id", updatedAt = "updated_at", deleted, language
    }

    var key: String { String(lecturerID) }

    init(lecturerID: Int, language: String?, at date: Double) {
        self.lecturerID = lecturerID
        updatedAt = date
        self.language = language ?? ""
        deleted = language == nil
    }
}

/// A setting, by name. Only the default speed so far.
struct SettingRecord: SyncRecord {
    static let defaultRate = "default_rate"

    var name: String
    var updatedAt: Double
    var deleted = false
    var value: Double?

    enum CodingKeys: String, CodingKey {
        case name, updatedAt = "updated_at", deleted, value
    }

    var key: String { name }
}

/// Time heard on a lecture on a day. Sent, it's the time since the last sync
/// (`reset` starting the day over from it); received, the day's total.
struct ListeningRecord: SyncRecord {
    var day: String
    var topicID: Int
    var lectureID: Int
    var seconds: Double
    var lastHeard: Double
    /// Sent, the stretches heard since the last sync; received, all of them.
    var sessions: [ListeningSession] = []
    var topic = Card(nil)
    var lectureTitle = ""
    /// Sent only.
    var reset: Bool?
    /// Received only: cleared, and nothing heard since.
    var deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case day, topicID = "topic_id", lectureID = "lecture_id", seconds
        case lastHeard = "last_heard", sessions, topic, lectureTitle = "lecture_title", reset, deleted
    }

    var key: String { Self.key(day: day, topicID: topicID, lectureID: lectureID) }
    var updatedAt: Double { lastHeard }

    static func key(day: String, topicID: Int, lectureID: Int) -> String { "\(day)/\(topicID)/\(lectureID)" }

    init(day: String, _ entry: ListeningEntry) {
        self.day = day
        topicID = entry.topic.id
        lectureID = entry.lectureID
        seconds = entry.seconds
        lastHeard = entry.lastHeard
        sessions = entry.sessions ?? []
        topic = Card(entry.topic)
        lectureTitle = entry.lectureTitle
    }

    /// Nil for a card this version can't read.
    var entry: ListeningEntry? {
        topic.topic.map {
            ListeningEntry(topic: $0, lectureID: lectureID, lectureTitle: lectureTitle,
                           seconds: seconds, lastHeard: lastHeard, sessions: sessions)
        }
    }
}

/// Each kind's records, as a request and an answer carry them.
struct SyncChanges: Codable {
    var progress: [ProgressRecord] = []
    var history: [HistoryRecord] = []
    var bookmarks: [BookmarkRecord] = []
    var shelf: [ShelfRecord] = []
    var rates: [RateRecord] = []
    var pins: [PinRecord] = []
    var languages: [LanguageRecord] = []
    var settings: [SettingRecord] = []
    var listening: [ListeningRecord] = []

    var count: Int {
        progress.count + history.count + bookmarks.count + shelf.count + rates.count
            + pins.count + languages.count + settings.count + listening.count
    }
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
