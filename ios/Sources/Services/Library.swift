import Foundation

/// The catalog the app reads: lecturers, their topics and the lectures in them.
/// Views talk to `API.library`, the Django backend (`RemoteLibrary`).
protocol LibraryProviding {
    func groups() async throws -> [TopicGroup]
    /// The languages the catalog has lectures in, with how many.
    func languages() async throws -> [Language]
    /// Newest first. With `language`, only topics with lectures in it.
    func topics(group: TopicGroup?, page: Int, language: String?) async throws -> CatalogPage
    func lecturers() async throws -> [Lecturer]
    func lecturer(id: Int) async throws -> LecturerPage
    /// With `language`, only topics with lectures in it, counted over those.
    func topics(lecturerID: Int, language: String?) async throws -> [Topic]
    func topicPage(id: Int) async throws -> TopicPage
    /// With `language`, only what has lectures in it.
    func search(_ query: String, language: String?) async throws -> SearchResult
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
    static let library: LibraryProviding = RemoteLibrary(baseURL: baseURL)

    /// The backend's root: `APIBaseURL` in Info.plist, set per configuration by
    /// the `API_BASE_URL` build setting (project.yml).
    static let baseURL: URL = {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
              let url = URL(string: string), url.host != nil
        else { return URL(string: "http://127.0.0.1:8765")! }
        return url
    }()
}

/// The topic groups, kept on the phone so Browse and the lecturer page have
/// them at once (and offline); refreshed from the backend on launch.
@MainActor
final class GroupStore: ObservableObject {
    static let shared = GroupStore()
    private let file = "groups.json"
    private let version = 1

    @Published private(set) var items: [TopicGroup] = []

    private init() { items = Store.load([TopicGroup].self, from: file) ?? [] }

    func refresh() async {
        guard let fresh = try? await API.library.groups(), fresh != items else { return }
        items = fresh
        Store.save(items, version: version, to: file)
    }
}

/// The languages the catalog has lectures in, kept on the phone like the
/// groups, and the one Home, the groups and search are narrowed to (nil for
/// all). Refreshed from the backend on launch.
@MainActor
final class CatalogLanguageStore: ObservableObject {
    static let shared = CatalogLanguageStore()
    private let file = "languages.json"
    private let version = 1
    private let choiceKey = "lecture.catalogLanguage"

    @Published private(set) var items: [Language] = []
    @Published private var chosen: String?

    private init() {
        items = Store.load([Language].self, from: file) ?? []
        chosen = UserDefaults.standard.string(forKey: choiceKey)
    }

    /// The chosen language, unless the catalog turns out not to have it.
    var language: String? {
        chosen.flatMap { code in items.isEmpty || items.contains { $0.code == code } ? code : nil }
    }

    func choose(_ language: String?) {
        chosen = language
        UserDefaults.standard.set(language, forKey: choiceKey)
    }

    func refresh() async {
        guard let fresh = try? await API.library.languages(), fresh != items else { return }
        items = fresh
        Store.save(items, version: version, to: file)
    }
}

/// The language the listener narrowed each lecturer to, remembered so their
/// page and their topics open in it next time. No entry means every language.
@MainActor
final class LanguageChoiceStore: ObservableObject {
    static let shared = LanguageChoiceStore()
    private let file = "language-choices.json"
    private let version = 1

    /// Language code by lecturer id (as a string, for the JSON).
    @Published private(set) var choices: [String: String] = [:]

    private init() { choices = Store.load([String: String].self, from: file) ?? [:] }

    func language(lecturerID: Int) -> String? { choices[String(lecturerID)] }

    /// The remembered language, if `available` has it (or isn't known yet);
    /// else every language.
    func language(lecturerID: Int, among available: [String]) -> String? {
        language(lecturerID: lecturerID).flatMap { available.isEmpty || available.contains($0) ? $0 : nil }
    }

    func set(_ language: String?, lecturerID: Int) {
        guard choices[String(lecturerID)] != language else { return }
        choices[String(lecturerID)] = language
        Store.save(choices, version: version, to: file)
    }
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
            NetworkStatus.shared.showingSaved = false
            return page
        } catch {
            if let saved = DownloadManager.shared.savedTopics[id], !error.isCancellation {
                NetworkStatus.shared.showingSaved = true
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
/// offline banner: set when a topic falls back to its downloaded copy, cleared
/// by the next page that loads.
@MainActor
final class NetworkStatus: ObservableObject {
    static let shared = NetworkStatus()
    @Published var showingSaved = false
    private init() {}
}
