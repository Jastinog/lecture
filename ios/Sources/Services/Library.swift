import Foundation

/// The catalog the app reads: lecturers, their topics and the lectures in them.
/// Views talk to `API.library`; today that's `MockLibrary`, later the Django
/// backend behind the same protocol.
protocol LibraryProviding {
    var groups: [TopicGroup] { get }
    func topics(group: TopicGroup?, sort: SortMode, page: Int) async throws -> CatalogPage
    func lecturers() async throws -> [Lecturer]
    func lecturer(id: Int) async throws -> Lecturer
    func topics(lecturerID: Int) async throws -> [Topic]
    func topicPage(id: Int) async throws -> TopicPage
    func search(_ query: String) async throws -> SearchResult
}

/// What a search finds: lecturers by name, topics by title or lecturer, and
/// single lectures by title.
struct SearchResult {
    var lecturers: [Lecturer] = []
    var topics: [Topic] = []
    var lectures: [LectureHit] = []
    var isEmpty: Bool { lecturers.isEmpty && topics.isEmpty && lectures.isEmpty }
}

/// A lecture found by search, with the topic it belongs to.
struct LectureHit: Identifiable, Hashable {
    let lecture: Lecture
    let index: Int
    let topic: Topic
    var id: Int { lecture.id }
}

enum APIError: Error { case badURL, noData, parse, notFound, http(status: Int) }

extension Error {
    /// A request given up on, as opposed to one that failed.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

/// Single entry point to the data layer.
enum API {
    static let library: LibraryProviding = MockLibrary()
}

/// In-memory cache of topic pages (main-thread use only), so a reopened topic —
/// and the view rebuild when playback starts — renders instantly.
@MainActor
final class TopicCache {
    static let shared = TopicCache()
    private var pages: [Int: TopicPage] = [:]

    func get(_ id: Int) -> TopicPage? { pages[id] }

    /// The page for `id`: from memory, else fetched and cached; if that fails, a
    /// downloaded copy of the topic (lectures and cover, no page extras).
    func resolve(_ id: Int) async throws -> TopicPage {
        if let cached = pages[id] { return cached }
        do {
            let page = try await API.library.topicPage(id: id)
            pages[id] = page
            return page
        } catch {
            if let saved = DownloadManager.shared.savedTopics[id] {
                return TopicPage(detail: saved, summary: Topic(saved), lecturer: nil, description: nil)
            }
            throw error
        }
    }
}

extension Topic {
    /// A list card for a topic known only by its playable detail (a download).
    init(_ detail: TopicDetail) {
        self.init(id: detail.id, title: detail.title, coverURL: detail.coverURL,
                  lecturer: LecturerRef(id: detail.lecturerID ?? 0, name: detail.lecturer),
                  lecturesCount: detail.lectures.count, duration: detail.totalDuration)
    }
}

/// Whether screens show saved data because the network is down. Drives the
/// offline banner; the mock library is never offline.
@MainActor
final class NetworkStatus: ObservableObject {
    static let shared = NetworkStatus()
    @Published private(set) var showingSaved = false
    private init() {}
}
