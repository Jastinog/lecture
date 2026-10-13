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
    /// How many lectures are in it, where a page counts them.
    var lecturesCount: Int? = nil
    var id: String { code }

    /// The short tag lists mark a lecture or topic with: "EN", "RU", "UK".
    static func tag(_ code: String) -> String { code.uppercased() }
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

/// A lecturer's own grouping of their lectures across topics (the backend's
/// selection): either a folder of further selections (the Bhagavad-gita's
/// chapters) or a list of lectures, which the app opens and plays as a topic.
struct Selection: Identifiable, Hashable {
    /// The backend's id.
    let id: Int
    let title: String
    var coverURL: URL? = nil
    var lecturer: LecturerRef
    var about: String? = nil
    /// True for a folder of selections, false for a list of lectures.
    var holdsSelections = false
    var childrenCount = 0
    /// Every lecture in it, nested ones included.
    var lecturesCount = 0
    var duration: Double = 0
    var languages: [String] = []
    /// The selections it sits in, as a title prefix ("Bhagavad-gita"), so a
    /// chapter opened as a topic says which book it's from.
    var within: String? = nil

    /// The id it goes by as a topic. Negative, so progress, history, the shelf
    /// and downloads, all kept by topic id, never mix one up with a topic (the
    /// backend's are positive). `RemoteLibrary.topicPage` turns it back; the
    /// rest of the app needn't know, as long as it reaches the backend for a
    /// topic only through `TopicCache`.
    var topicID: Int { -id }

    /// "Bhagavad-gita · Chapter 2": a selection's title after the ones it sits in.
    static func trail(_ titles: [String?]) -> String {
        titles.compactMap { $0 }.joined(separator: " · ")
    }

    /// A list of lectures as the topic it opens as.
    var asTopic: Topic {
        Topic(id: topicID, title: Self.trail([within, title]),
              coverURL: coverURL, lecturer: lecturer, languages: languages,
              lecturesCount: lecturesCount, duration: duration, about: about)
    }
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

extension Array where Element == Lecture {
    /// Where a saved spot is in these lectures: found by its lecture id, so a
    /// list narrowed to one language still lands on it (nil when it's left
    /// out); spots saved before ids were kept fall back to their `index`.
    func index(of lectureID: Int?, saved index: Int) -> Int? {
        guard let lectureID else { return indices.contains(index) ? index : nil }
        return firstIndex { $0.id == lectureID }
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

    /// The languages its lectures are in, in the order they first come up.
    var languages: [String] {
        var seen: [String] = []
        for lecture in lectures where !seen.contains(lecture.language) { seen.append(lecture.language) }
        return seen
    }

    /// The same topic with only its lectures in `language` (all of them for nil),
    /// as the player gets it when the page is narrowed to one language.
    func only(language: String?) -> TopicDetail {
        guard let language else { return self }
        return TopicDetail(id: id, title: title, lecturer: lecturer, lecturerID: lecturerID,
                           coverURL: coverURL, lectures: lectures.filter { $0.language == language })
    }
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

/// A lecturer's page: the lecturer and every language they have lectures in,
/// with how many.
struct LecturerPage {
    var lecturer: Lecturer
    var languages: [Language] = []
}

/// One page of a topic list.
struct CatalogPage {
    let items: [Topic]
    let page: Int
    let pages: Int
    let count: Int
}
