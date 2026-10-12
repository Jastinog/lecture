import Foundation

/// Stand-in catalog until the API is wired up: the lecturers and topics from
/// the backend's seed (`lecturers.json`), with generated lectures that play
/// public sample audio. Answers after a short delay, like a network would.
struct MockLibrary: LibraryProviding {
    private static let pageSize = 10

    func groups() async throws -> [TopicGroup] { MockData.groups }

    func topics(group: TopicGroup?, sort: SortMode, page: Int) async throws -> CatalogPage {
        try await latency()
        var all = MockData.topics.filter { group == nil || $0.group == group }
        switch sort {
        case .new: all.sort { $0.id > $1.id }
        case .popular: all.sort { ($0.plays ?? 0) > ($1.plays ?? 0) }
        }
        let pages = max(1, (all.count + Self.pageSize - 1) / Self.pageSize)
        let slice = all.dropFirst((page - 1) * Self.pageSize).prefix(Self.pageSize)
        return CatalogPage(items: Array(slice), page: page, pages: pages, count: all.count)
    }

    func lecturers() async throws -> [Lecturer] {
        try await latency()
        return MockData.lecturers
    }

    func lecturer(id: Int) async throws -> Lecturer {
        try await latency()
        guard let lecturer = MockData.lecturers.first(where: { $0.id == id }) else { throw APIError.notFound }
        return lecturer
    }

    func topics(lecturerID: Int) async throws -> [Topic] {
        try await latency()
        return MockData.topics.filter { $0.lecturer.id == lecturerID }
    }

    func topicPage(id: Int) async throws -> TopicPage {
        try await latency()
        guard let topic = MockData.topics.first(where: { $0.id == id }) else { throw APIError.notFound }
        let lectures = MockData.lectures(for: topic)
        let years = lectures.compactMap(\.year)
        return TopicPage(
            detail: TopicDetail(id: topic.id, title: topic.title, lecturer: topic.lecturer.name,
                                lecturerID: topic.lecturer.id, coverURL: topic.coverURL, lectures: lectures),
            summary: topic,
            lecturer: MockData.lecturers.first { $0.id == topic.lecturer.id },
            description: topic.about,
            languages: MockData.languages.filter { topic.languages.contains($0.code) },
            years: years.min().flatMap { lo in years.max().map { lo...$0 } },
            addedDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(topic.id) * 86_400 * 9),
            related: MockData.topics.filter { $0.lecturer.id == topic.lecturer.id && $0.id != topic.id }
        )
    }

    func search(_ query: String) async throws -> SearchResult {
        try await latency()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return SearchResult() }
        func hit(_ s: String) -> Bool { s.localizedCaseInsensitiveContains(q) }
        let topics = MockData.topics
        var lectures: [LectureHit] = []
        for topic in topics {
            for (index, lecture) in MockData.lectures(for: topic).enumerated() where hit(lecture.title) {
                lectures.append(LectureHit(lecture: lecture, index: index, topic: topic))
                if lectures.count >= 30 { break }
            }
        }
        return SearchResult(lecturers: MockData.lecturers.filter { hit($0.name) },
                            topics: topics.filter { hit($0.title) || hit($0.lecturer.name) },
                            lectures: lectures)
    }

    private func latency() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }
}

/// The seed data itself.
enum MockData {
    static let groups: [TopicGroup] = [
        TopicGroup(code: "lectures", name: "Лекции"),
        TopicGroup(code: "conversations", name: "Беседы"),
        TopicGroup(code: "interviews", name: "Интервью"),
        TopicGroup(code: "walks", name: "Прогулки"),
        TopicGroup(code: "books", name: "Книги"),
        TopicGroup(code: "kirtans", name: "Киртаны"),
    ]

    static let languages: [Language] = [
        Language(code: "ru", name: "Русский"),
        Language(code: "en", name: "English"),
        Language(code: "uk", name: "Українська"),
    ]

    private static func group(_ code: String) -> TopicGroup? { groups.first { $0.code == code } }

    static let lecturers: [Lecturer] = [
        Lecturer(id: 1, name: "A. C. Bhaktivedanta Swami Prabhupada", level: .founder,
                 bio: "Founder-Acharya of ISKCON, author of numerous translations of sacred scriptures. Spread Krishna consciousness worldwide.",
                 topicsCount: prabhupada.count, lecturesCount: lectureCount(prabhupada)),
        Lecturer(id: 2, name: "HH Radhanath Swami", level: .disciple,
                 bio: "Disciple of Srila Prabhupada, spiritual teacher and author of “The Journey Home”.",
                 topicsCount: radhanath.count, lecturesCount: lectureCount(radhanath)),
    ]

    /// (title, description, group, lecture count, plays)
    private typealias Seed = (title: String, about: String, group: String, count: Int, plays: Int)

    private static let prabhupada: [Seed] = [
        ("Бхагавад Гита", "Лекции по Бхагавад Гите", "lectures", 42, 18_400),
        ("Шримад Бхагаватам", "Лекции по Шримад Бхагаватам на русском", "lectures", 64, 22_150),
        ("Чайтанья Чаритамрита", "Лекции по Чайтанье Чаритамрите", "lectures", 28, 9_870),
        ("Нектар Преданности", "Лекции по Нектару Преданности", "lectures", 18, 6_320),
        ("Шри Ишопанишад", "Лекции по Шри Ишопанишаду", "lectures", 12, 5_410),
        ("Брахма Самхита", "Лекции по Брахма Самхите", "lectures", 9, 3_980),
        ("Праздники", "Лекции на праздники", "lectures", 15, 4_120),
        ("Лекции", "Лекции Шрилы Прабхупады", "lectures", 24, 7_600),
        ("Разное", "Разные лекции", "lectures", 11, 2_310),
        ("Беседы", "Беседы Шрилы Прабхупады", "conversations", 33, 8_840),
        ("Интервью", "Интервью Шрилы Прабхупады", "interviews", 8, 3_020),
        ("Утренние Прогулки", "Утренние прогулки с Шрилой Прабхупадой", "walks", 26, 6_900),
    ]

    private static let radhanath: [Seed] = [
        ("Госвами Вриндавана", "Лекции о шести Госвами Вриндавана", "lectures", 14, 4_870),
        ("Милость Шрилы Прабхупады", "Лекции о милости Шрилы Прабхупады", "lectures", 10, 3_640),
        ("Брихад Бхагаватамрита (1999)", "Лекции по Брихад Бхагаватамрите 1999 года", "lectures", 21, 2_980),
        ("Важнейшие качества Вайшнавов (Pune 2002)", "Лекции о важнейших качествах вайшнавов, Пуна 2002", "lectures", 7, 2_150),
        ("Путешествие домой", "Лекции по книге «Путешествие домой»", "books", 16, 5_730),
        ("Фестивали", "Фестивальные лекции Радханатха Свами", "lectures", 12, 3_310),
        ("Чайтанья Чаритамрита", "Лекции по Чайтанье Чаритамрите", "lectures", 19, 2_760),
    ]

    private static func lectureCount(_ seeds: [Seed]) -> Int { seeds.reduce(0) { $0 + $1.count } }

    static let topics: [Topic] = {
        var id = 0
        func make(_ seeds: [Seed], _ lecturer: Lecturer) -> [Topic] {
            seeds.map { seed in
                id += 1
                let lectures = Self.lectures(topicID: id, title: seed.title, count: seed.count)
                return Topic(id: id, title: seed.title,
                             coverURL: URL(string: "https://picsum.photos/seed/lecture-topic-\(id)/308/440"),
                             lecturer: lecturer.ref, group: group(seed.group), languages: ["ru"],
                             lecturesCount: seed.count,
                             duration: lectures.reduce(0) { $0 + $1.duration },
                             plays: seed.plays, about: seed.about)
            }
        }
        return make(prabhupada, lecturers[0]) + make(radhanath, lecturers[1])
    }()

    static func lectures(for topic: Topic) -> [Lecture] {
        lectures(topicID: topic.id, title: topic.title, count: topic.lecturesCount)
    }

    private static let places = ["Лос-Анджелес", "Вриндаван", "Бомбей", "Лондон", "Майапур", "Нью-Йорк", "Москва"]

    /// Deterministic lectures for a topic: the same ids, titles and lengths on
    /// every launch, so progress and downloads stick to them.
    private static func lectures(topicID: Int, title: String, count: Int) -> [Lecture] {
        (0..<count).map { i in
            let seed = topicID * 1000 + i
            let year = 1966 + (seed * 7) % 12
            let place = places[seed % places.count]
            return Lecture(
                id: seed,
                title: "Часть \(i + 1)",
                // SoundHelix hosts 16 public sample tracks.
                url: URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-\(seed % 16 + 1).mp3")!,
                duration: Double(1800 + (seed * 37) % 2700),
                year: year,
                event: "\(place), \(year)"
            )
        }
    }
}
