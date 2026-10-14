import Foundation
import os

/// The catalog served by the Django backend (`api/v1/`, see `api/v1/catalog`).
/// The wire format lives in private DTOs mapped onto the app's models, so the
/// models' on-disk shape (downloads, history) never depends on the API's.
struct RemoteLibrary: LibraryProviding {
    let baseURL: URL
    var session: URLSession = Self.session

    /// Gives up on a request after 15s rather than the system's minute, so a weak
    /// network shows "Couldn't load" and a retry instead of a long spinner.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private static let log = Logger(subsystem: "com.personal.lecture", category: "api")

    func groups() async throws -> [TopicGroup] {
        try await get([GroupDTO].self, "groups/").map(\.model)
    }

    func languages() async throws -> [Language] {
        try await get([LanguageDTO].self, "languages/").map(\.model)
    }

    func topics(group: TopicGroup?, page: Int, language: String?) async throws -> CatalogPage {
        var query = [URLQueryItem(name: "page", value: String(page))]
        if let group { query.append(URLQueryItem(name: "group", value: group.code)) }
        query += lang(language)
        let list = try await get(TopicListDTO.self, "topics/", query: query)
        return CatalogPage(items: list.results.map(\.model), page: list.page,
                           pages: list.pages, count: list.count)
    }

    func lecturers(language: String?) async throws -> [Lecturer] {
        try await get([LecturerDTO].self, "lecturers/", query: lang(language)).map(\.model)
    }

    func lecturer(id: Int) async throws -> LecturerPage {
        let dto = try await get(LecturerDTO.self, "lecturers/\(id)/")
        return LecturerPage(lecturer: dto.model, languages: (dto.languages ?? []).map(\.model))
    }

    func topics(lecturerID: Int, language: String?) async throws -> [Topic] {
        try await get([TopicDTO].self, "lecturers/\(lecturerID)/topics/", query: lang(language)).map(\.model)
    }

    func topicPage(id: Int) async throws -> TopicPage {
        if id < 0 {
            // A selection of lectures (`Selection.topicID`): its page has the
            // topic page's shape.
            let dto = try await get(TopicPageDTO.self, "selections/\(-id)/")
            return dto.model(id: id, title: Selection.trail((dto.path ?? []).map(\.title) + [dto.title]))
        }
        return try await get(TopicPageDTO.self, "topics/\(id)/").model()
    }

    func selections(lecturer: LecturerRef, language: String?) async throws -> [Selection] {
        // The cards don't name the lecturer: they're all theirs.
        try await get([SelectionDTO].self, "lecturers/\(lecturer.id)/selections/", query: lang(language))
            .map { $0.model(lecturer: lecturer, within: nil) }
    }

    func selections(in folder: Selection, language: String?) async throws -> [Selection] {
        let page = try await get(SelectionChildrenDTO.self, "selections/\(folder.id)/", query: lang(language))
        let within = Selection.trail([folder.within, folder.title])
        return page.children.map { $0.model(lecturer: folder.lecturer, within: within) }
    }

    /// `?lang=` for `language`, nothing for every language.
    private func lang(_ language: String?) -> [URLQueryItem] {
        language.map { [URLQueryItem(name: "lang", value: $0)] } ?? []
    }

    func search(_ query: String, language: String?) async throws -> SearchResult {
        var items = [URLQueryItem(name: "q", value: query)]
        items += lang(language)
        let found = try await get(SearchDTO.self, "search/", query: items)
        return SearchResult(
            lecturers: found.lecturers.map(\.model),
            topics: found.topics.map(\.model),
            lectures: found.lectures.compactMap(\.model)
        )
    }

    func home(language: String?) async throws -> HomeFeed {
        let dto = try await get(HomeDTO.self, "home/", query: lang(language))
        return HomeFeed(trending: dto.trending.map(\.model), newTopics: dto.new.map(\.model),
                        selections: dto.selections.compactMap { card in
                            card.lecturer.map { card.model(lecturer: $0.model, within: nil) }
                        },
                        lectureOfTheDay: dto.lectureOfTheDay?.model)
    }

    func reportPlay(lectureID: Int) async throws {
        _ = try await post("plays/", ["lecture": lectureID])
    }

    func register(listener id: UUID, platform: String, appVersion: String) async throws -> String {
        let data = try await post("listeners/", ["id": id.uuidString, "platform": platform,
                                                 "app_version": appVersion])
        guard let token = try? Self.decoder.decode(TokenDTO.self, from: data).token else {
            throw APIError.parse
        }
        return token
    }

    // MARK: Transport

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// A request for `api/v1/<path>`, asking for JSON.
    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        guard var components = URLComponents(string: base + "api/v1/" + path) else { throw APIError.badURL }
        if !query.isEmpty {
            components.queryItems = query
            // A literal "+" would reach the server as a space ("C++" as "C  ").
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = Account.shared.token {
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// POSTs `body` as JSON; the response's body. A token the server turned
    /// down sends the account to register again.
    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var request = try request(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        if http.statusCode == 401,
           let token = request.value(forHTTPHeaderField: "Authorization")?.split(separator: " ").last {
            await Account.shared.tokenRejected(String(token))
        }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(status: http.statusCode) }
        return data
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String,
                                   query: [URLQueryItem] = []) async throws -> T {
        let (data, http) = try await fetch(request(path, query: query))
        switch http.statusCode {
        case 200..<300: break
        case 404: throw APIError.notFound
        default: throw APIError.http(status: http.statusCode)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Self.log.error("Couldn't decode \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw APIError.parse
        }
    }

    /// The response, trying once more after a moment when the server is briefly
    /// down (a deploy restarting it); offline, the last copy the phone has of
    /// it, so pages seen before still open.
    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            var (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (502...504).contains(http.statusCode) {
                try await Task.sleep(for: .seconds(1))
                (data, response) = try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw APIError.noData }
            return (data, http)
        } catch let error as URLError where Self.offline.contains(error.code) {
            var cached = request
            cached.cachePolicy = .returnCacheDataDontLoad
            guard let (data, response) = try? await session.data(for: cached),
                  let http = response as? HTTPURLResponse else { throw error }
            return (data, http)
        }
    }

    private static let offline: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut,
        .cannotFindHost, .cannotConnectToHost, .dataNotAllowed,
    ]
}

// MARK: - Wire format

/// `POST listeners/`.
private struct TokenDTO: Decodable {
    let token: String
}

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
    /// Only on the lecturer's own page.
    let languages: [LanguageDTO]?

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
    let about: String?

    var model: Topic {
        Topic(id: id, title: title, coverURL: coverUrl, lecturer: lecturer.model,
              group: group?.model, languages: languages, lecturesCount: lecturesCount,
              duration: duration, about: about)
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
    let lecturesCount: Int?
    var model: Language { Language(code: code, name: name, lecturesCount: lecturesCount) }
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
    let about: String?
    let years: YearsDTO?
    let createdAt: String?
    let lectures: [LectureDTO]
    let related: [TopicDTO]
    /// Only on a selection's page: the selections it sits in, outermost first.
    let path: [PathDTO]?

    /// The page, under `id` and `title` when it stands for something else (a
    /// selection, under its topic id and with the book it's from).
    func model(id: Int? = nil, title: String? = nil) -> TopicPage {
        let id = id ?? self.id, title = title ?? self.title
        let lecturer = lecturer.model
        let summary = Topic(id: id, title: title, coverURL: coverUrl, lecturer: lecturer.ref,
                            group: group?.model, languages: languages.map(\.code),
                            lecturesCount: lecturesCount, duration: duration, about: about)
        return TopicPage(
            detail: TopicDetail(id: id, title: title, lecturer: lecturer.name, lecturerID: lecturer.id,
                                coverURL: coverUrl, lectures: lectures.compactMap(\.model)),
            summary: summary,
            lecturer: lecturer,
            description: about,
            languages: languages.map(\.model),
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

private struct PathDTO: Decodable {
    let id: Int
    let title: String
}

/// A selection's card (`lecturers/<id>/selections/`, a page's `children`).
private struct SelectionDTO: Decodable {
    let id: Int
    /// Only on home's cards, which come from every lecturer.
    let lecturer: LecturerRefDTO?
    let title: String
    let coverUrl: URL?
    let about: String?
    let holds: String
    let childrenCount: Int
    let lecturesCount: Int
    let duration: Double
    let languages: [String]

    func model(lecturer: LecturerRef, within: String?) -> Selection {
        Selection(id: id, title: title, coverURL: coverUrl, lecturer: lecturer,
                  about: about?.isEmpty == false ? about : nil,
                  holdsSelections: holds == "selections", childrenCount: childrenCount,
                  lecturesCount: lecturesCount, duration: duration, languages: languages,
                  within: within)
    }
}

/// `GET selections/<id>/` read as a folder: just the selections in it (the
/// folder's own card is the one it was opened from).
private struct SelectionChildrenDTO: Decodable {
    let children: [SelectionDTO]
}

/// `GET home/`.
private struct HomeDTO: Decodable {
    let trending: [TopicDTO]
    let new: [TopicDTO]
    let selections: [SelectionDTO]
    let lectureOfTheDay: LectureHitDTO?
}

/// A lecture with its place in its topic (search, the lecture of the day).
private struct LectureHitDTO: Decodable {
    let lecture: LectureDTO
    let index: Int
    let topic: TopicDTO

    /// Nil for a lecture without a file.
    var model: LectureHit? {
        lecture.model.map { LectureHit(lecture: $0, index: index, topic: topic.model) }
    }
}

private struct SearchDTO: Decodable {
    let lecturers: [LecturerDTO]
    let topics: [TopicDTO]
    let lectures: [LectureHitDTO]
}
