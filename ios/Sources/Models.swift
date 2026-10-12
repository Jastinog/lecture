import Foundation

// MARK: - Catalog

/// A lecturer, as the catalog and the lecturer's page show them.
struct Lecturer: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    var photoURL: URL? = nil
    var level: LecturerLevel = .disciple
    var bio: String? = nil
    var topicsCount = 0
    var lecturesCount = 0

    var ref: LecturerRef { LecturerRef(id: id, name: name) }
}

/// Where a lecturer stands in the line of disciples (the backend's `level`).
enum LecturerLevel: Int, Codable, CaseIterable, Identifiable {
    case founder = 1, disciple = 2, grandDisciple = 3
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .founder: return "Founder-Acharya"
        case .disciple: return "Direct Disciple"
        case .grandDisciple: return "Grand Disciple"
        }
    }
    /// The directory's section heading for the level.
    var sectionTitle: String {
        switch self {
        case .founder: return "Founder-Acharya"
        case .disciple: return "Disciples"
        case .grandDisciple: return "Grand Disciples"
        }
    }
}

/// Just enough of a lecturer to name them on a topic and open their page.
struct LecturerRef: Hashable, Codable {
    let id: Int
    let name: String
}

/// What kind of recordings a topic holds (the backend's `TopicGroup`).
struct TopicGroup: Identifiable, Hashable, Codable {
    let code: String
    let name: String
    var id: String { code }
}

struct Language: Identifiable, Hashable, Codable {
    let code: String
    let name: String
    var id: String { code }
}

/// A topic as every list shows it — catalog, lecturer page, search, shelf,
/// history. The playable layer (its lectures) lives in `TopicDetail`, fetched
/// on demand.
struct Topic: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    var coverURL: URL? = nil
    var lecturer: LecturerRef
    var group: TopicGroup? = nil
    var languages: [String] = []
    var lecturesCount = 0
    /// All the lectures together, in seconds.
    var duration: Double = 0
    var about: String? = nil
}

/// A single recording in a topic.
struct Lecture: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    let url: URL
    let duration: Double     // seconds
    var year: Int? = nil
    var event: String? = nil
    var language: String = "ru"

    /// The title to show for the lecture at `index`; untitled ones read "Lecture N".
    func displayTitle(at index: Int) -> String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? "Lecture \(index + 1)" : title
    }
}

/// The playable topic — its lectures plus what the player shows.
struct TopicDetail: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    let lecturer: String
    var lecturerID: Int? = nil
    let coverURL: URL?
    let lectures: [Lecture]

    var totalDuration: Double { lectures.reduce(0) { $0 + $1.duration } }
}

/// The full topic page: the playable `detail` plus display-only extras.
struct TopicPage {
    var detail: TopicDetail
    var summary: Topic
    var lecturer: Lecturer?
    var description: String?
    var languages: [Language] = []
    /// The first and last year of its lectures.
    var years: ClosedRange<Int>? = nil
    var addedDate: Date? = nil
    var related: [Topic] = []
}

/// One page of a topic list.
struct CatalogPage {
    let items: [Topic]
    let page: Int
    let pages: Int
    let count: Int
}
