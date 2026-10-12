import Foundation

/// The catalog served by the Django backend (`api/v1/`, see `api/v1/catalog`).
/// The wire format lives in private DTOs mapped onto the app's models, so the
/// models' on-disk shape (downloads, history) never depends on the API's.
struct RemoteLibrary: LibraryProviding {
    let baseURL: URL
    var session: URLSession = .shared

    func groups() async throws -> [TopicGroup] {
        try await get([GroupDTO].self, "groups/").map(\.model)
    }

    func topics(group: TopicGroup?, sort: SortMode, page: Int) async throws -> CatalogPage {
        var query = [URLQueryItem(name: "sort", value: sort.rawValue),
                     URLQueryItem(name: "page", value: String(page))]
        if let group { query.append(URLQueryItem(name: "group", value: group.code)) }
        let list = try await get(TopicListDTO.self, "topics/", query: query)
        return CatalogPage(items: list.results.map(\.model), page: list.page,
                           pages: list.pages, count: list.count)
    }

    func lecturers() async throws -> [Lecturer] {
        try await get([LecturerDTO].self, "lecturers/").map(\.model)
    }

    func lecturer(id: Int) async throws -> Lecturer {
        try await get(LecturerDTO.self, "lecturers/\(id)/").model
    }

    func topics(lecturerID: Int) async throws -> [Topic] {
        try await get([TopicDTO].self, "lecturers/\(lecturerID)/topics/").map(\.model)
    }

    func topicPage(id: Int) async throws -> TopicPage {
        try await get(TopicPageDTO.self, "topics/\(id)/").model
    }

    func search(_ query: String) async throws -> SearchResult {
        let found = try await get(SearchDTO.self, "search/", query: [URLQueryItem(name: "q", value: query)])
        return SearchResult(
            lecturers: found.lecturers.map(\.model),
            topics: found.topics.map(\.model),
            lectures: found.lectures.compactMap { hit in
                hit.lecture.model.map { LectureHit(lecture: $0, index: hit.index, topic: hit.topic.model) }
            }
        )
    }

    // MARK: Transport

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func get<T: Decodable>(_ type: T.Type, _ path: String,
                                   query: [URLQueryItem] = []) async throws -> T {
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        guard var components = URLComponents(string: base + "api/v1/" + path) else { throw APIError.badURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        switch http.statusCode {
        case 200..<300: break
        case 404: throw APIError.notFound
        default: throw APIError.http(status: http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.parse
        }
    }
}

// MARK: - Wire format

private struct GroupDTO: Decodable {
    let code: String
    let name: String
    var model: TopicGroup { TopicGroup(code: code, name: name) }
}

private struct LecturerRefDTO: Decodable {
    let id: Int
    let name: String
    var model: LecturerRef { LecturerRef(id: id, name: name) }
}

private struct LecturerDTO: Decodable {
    let id: Int
    let name: String
    let photoUrl: URL?
    let level: Int
    let bio: String?
    let topicsCount: Int
    let lecturesCount: Int

    var model: Lecturer {
        Lecturer(id: id, name: name, photoURL: photoUrl,
                 level: LecturerLevel(rawValue: level) ?? .disciple,
                 bio: bio, topicsCount: topicsCount, lecturesCount: lecturesCount)
    }
}

private struct TopicDTO: Decodable {
    let id: Int
    let title: String
    let coverUrl: URL?
    let lecturer: LecturerRefDTO
    let group: GroupDTO?
    let languages: [String]
    let lecturesCount: Int
    let duration: Double
    let plays: Int
    let about: String?

    var model: Topic {
        Topic(id: id, title: title, coverURL: coverUrl, lecturer: lecturer.model,
              group: group?.model, languages: languages, lecturesCount: lecturesCount,
              duration: duration, plays: plays, about: about)
    }
}

private struct TopicListDTO: Decodable {
    let count: Int
    let page: Int
    let pages: Int
    let results: [TopicDTO]
}

private struct LectureDTO: Decodable {
    let id: Int
    let title: String
    let url: URL?
    let duration: Double
    let year: Int?
    let event: String?
    let language: String

    /// Nil for a lecture without a file: there's nothing to play.
    var model: Lecture? {
        guard let url else { return nil }
        return Lecture(id: id, title: title, url: url, duration: duration, year: year,
                       event: event?.isEmpty == false ? event : nil, language: language)
    }
}

private struct LanguageDTO: Decodable {
    let code: String
    let name: String
}

private struct YearsDTO: Decodable {
    let first: Int
    let last: Int
}

/// `GET topics/<id>/`: the topic card's fields plus the page extras.
private struct TopicPageDTO: Decodable {
    let id: Int
    let title: String
    let coverUrl: URL?
    let lecturer: LecturerDTO
    let group: GroupDTO?
    let languages: [LanguageDTO]
    let lecturesCount: Int
    let duration: Double
    let plays: Int
    let about: String?
    let years: YearsDTO?
    let createdAt: String?
    let lectures: [LectureDTO]
    let related: [TopicDTO]

    var model: TopicPage {
        let lecturer = lecturer.model
        let summary = Topic(id: id, title: title, coverURL: coverUrl, lecturer: lecturer.ref,
                            group: group?.model, languages: languages.map(\.code),
                            lecturesCount: lecturesCount, duration: duration, plays: plays, about: about)
        return TopicPage(
            detail: TopicDetail(id: id, title: title, lecturer: lecturer.name, lecturerID: lecturer.id,
                                coverURL: coverUrl, lectures: lectures.compactMap(\.model)),
            summary: summary,
            lecturer: lecturer,
            description: about,
            languages: languages.map { Language(code: $0.code, name: $0.name) },
            years: years.map { min($0.first, $0.last)...max($0.first, $0.last) },
            addedDate: createdAt.flatMap(Self.parseDate),
            related: related.map(\.model)
        )
    }

    /// Django sends microseconds, which `ISO8601DateFormatter` won't take;
    /// the page shows only the day, so they're dropped.
    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

private struct SearchDTO: Decodable {
    struct Hit: Decodable {
        let lecture: LectureDTO
        let index: Int
        let topic: TopicDTO
    }
    let lecturers: [LecturerDTO]
    let topics: [TopicDTO]
    let lectures: [Hit]
}
