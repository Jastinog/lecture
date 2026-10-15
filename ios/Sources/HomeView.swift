import SwiftUI

/// Home's rows from the backend, held globally so they survive a rebuild and
/// show at once when the tab comes back.
@MainActor
final class HomeFeedModel: ObservableObject {
    static let shared = HomeFeedModel()

    @Published private(set) var feed: HomeFeed?
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    /// The catalog language the rows were loaded in.
    private(set) var language: String?

    private let api: LibraryProviding

    init(api: LibraryProviding = API.library) { self.api = api }

    func refresh() async {
        let language = CatalogLanguageStore.shared.language
        loading = true
        failed = false
        do {
            let feed = try await api.home(language: language)
            self.feed = feed
            self.language = language
        } catch {
            if !error.isCancellation { failed = true }
        }
        if !Task.isCancelled { loading = false }
    }
}

/// Route to every new topic, paged.
struct NewTopicsRoute: Hashable {}

/// The first tab: search, the lectures being listened to, the lecture of the
/// day, then five each of the lectures trending (a tap plays one), the newest
/// topics and the newest selections. The bar's left button opens the listening calendar.
struct HomeView: View {
    @ObservedObject private var model = HomeFeedModel.shared
    @ObservedObject private var languages = CatalogLanguageStore.shared
    @ObservedObject private var recents = RecentsStore.shared
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter
    @StateObject private var starter = LectureStarter()

    /// Cards in each row.
    private static let limit = 5

    var body: some View {
        List {
            // The search bar heads the table and scrolls away with it.
            // The languages ride under the field, as a UISearchBar scope bar.
            SearchBarLink(prompt: String(localized: "Topic, lecture or lecturer"), accessory: { EmptyView() },
                          scope: { CatalogLanguagePicker() })
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)

            if !unfinished.isEmpty {
                Section {
                    ForEach(unfinished.indexed, id: \.element.id) { i, item in
                        ContinueRow(item: item, starter: starter).zebraRow(i)
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: String(localized: "Continue"))
                }
            }

            if let hit = model.feed?.lectureOfTheDay {
                Section {
                    RowButton(action: { starter.play(hit, player: player, router: router) }) {
                        LectureLine(title: hit.lecture.displayTitle(at: hit.index), topic: hit.topic.title,
                                    lecturer: hit.topic.lecturer.name, caption: lectureFacts(hit.lecture),
                                    detail: formatTime(hit.lecture.duration), loading: starter.isLoading(hit),
                                    isCurrent: player.isCurrent(topicID: hit.topic.id, lectureID: hit.lecture.id))
                    }
                    .zebraRow(0)
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: String(localized: "Lecture of the Day"))
                }
            }

            if let feed = model.feed {
                if !feed.trending.isEmpty {
                    Section {
                        ForEach(feed.trending.indexed, id: \.element.id) { i, hit in
                            RowButton(action: { starter.play(hit, player: player, router: router) }) {
                                LectureLine(hit, loading: starter.isLoading(hit),
                                            isCurrent: player.isCurrent(topicID: hit.topic.id, lectureID: hit.lecture.id))
                            }
                            .zebraRow(i)
                        }
                        .plainRow()
                    } header: {
                        PlainSectionHeader(title: String(localized: "Trending"))
                    }
                }
                if !feed.newTopics.isEmpty {
                    Section {
                        Group {
                            ForEach(feed.newTopics.indexed, id: \.element.id) { i, topic in
                                TopicRow(topic: topic).zebraRow(i)
                            }
                            RowLink(value: NewTopicsRoute()) {
                                Text("All New Topics")
                                    .font(.groupedLabel)
                                    .rowForeground(Palette.text)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .zebraRow(feed.newTopics.count)
                        }
                        .plainRow()
                    } header: {
                        PlainSectionHeader(title: String(localized: "New Topics"))
                    }
                }
                if !feed.selections.isEmpty {
                    Section {
                        ForEach(feed.selections.indexed, id: \.element.id) { i, selection in
                            SelectionRow(selection: selection, showsLecturer: true).zebraRow(i)
                        }
                        .plainRow()
                    } header: {
                        PlainSectionHeader(title: String(localized: "Selections"))
                    }
                }
            } else if model.loading {
                HStack { Spacer(); ClassicSpinner(); Spacer() }
                    .padding(.vertical, 16)
                    .listRowSeparator(.hidden)
                    .plainRow()
            } else if model.failed {
                ErrorRetryRow(message: String(localized: "Couldn’t load the catalog")) {
                    Task { await model.refresh() }
                }
                .listRowSeparator(.hidden)
                .plainRow()
            }
        }
        .listStyle(.plain)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ClassicTitle(String(localized: "Home"))
            }
            // iOS 6 bars held one button a side: "Calendar" opens the
            // listening calendar, "Now Playing" the player.
            ClassicToolbarItem(.leading) {
                NavigationLink(String(localized: "Calendar"), value: ListeningCalendarRoute())
                    .buttonStyle(.classicBar)
            }
            NowPlayingToolbarItem()
        }
        .classicRefreshable { await model.refresh() }
        .onDisappear { starter.cancel() }
        // Loads at first, and again whenever the catalog language changes.
        .task(id: languages.language) {
            if model.feed == nil || model.language != languages.language { await model.refresh() }
        }
    }

    /// "1972 · Bombay", or nil when neither is known.
    private func lectureFacts(_ lecture: Lecture) -> String? {
        let facts = [lecture.year.map(String.init), lecture.event].compactMap { $0 }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }

    /// The topics listened to lately and not finished, newest first: each
    /// row is the lecture it was left on.
    private var unfinished: [RecentTopic] {
        Array(recents.items.filter { !PlaybackMath.isFinished($0.fraction) }.prefix(Self.limit))
    }
}

/// The lecture a topic was left on, under "Continue", with what's left of
/// it; a tap resumes it where it was left.
private struct ContinueRow: View {
    let item: RecentTopic
    @ObservedObject var starter: LectureStarter

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter
    /// The topic's lectures, fetched when neither the cache nor a download has them.
    @State private var fetched: [Lecture]?

    var body: some View {
        let spot = self.spot
        let lectureID = entry?.lectureID
        RowButton(action: resume) {
            LectureLine(title: spot.map { $0.lecture.displayTitle(at: $0.index) } ?? fallbackTitle,
                        topic: item.title, lecturer: item.summary.lecturer.name,
                        caption: spot.map { String(localized: "\(formatDuration($0.left)) left in the lecture") },
                        progress: spot?.fraction, loading: starter.loading == rowID,
                        isCurrent: lectureID.map { player.isCurrent(topicID: item.id, lectureID: $0) } ?? false)
        }
        .task(id: item.id) {
            guard lectures == nil else { return }
            fetched = try? await TopicCache.shared.resolve(item.id).detail.lectures
        }
    }

    private var rowID: String { "continue-\(item.id)" }

    private func resume() {
        starter.play(rowID, topicID: item.id, lectureID: entry?.lectureID, summary: item.summary,
                     player: player, router: router)
    }

    private var entry: ProgressStore.Entry? { ProgressStore.entry(topicID: item.id) }

    private var lectures: [Lecture]? {
        TopicCache.shared.get(item.id)?.detail.lectures
            ?? DownloadManager.shared.savedTopics[item.id]?.lectures ?? fetched
    }

    private struct Spot {
        let lecture: Lecture
        let index: Int
        let fraction: Double
        /// Seconds left in the lecture.
        let left: Double
    }

    /// The lecture the topic was left on, and how far into it.
    private var spot: Spot? {
        guard let entry, let lectures, let index = entry.index(in: lectures) else { return nil }
        let lecture = lectures[index]
        let time = min(max(entry.time, 0), lecture.duration)
        return Spot(lecture: lecture, index: index, fraction: lecture.duration > 0 ? time / lecture.duration : 0,
                    left: lecture.duration - time)
    }

    /// Until the topic's lectures are at hand: the lecture's title as it was
    /// last heard, or the topic's.
    private var fallbackTitle: String {
        let lectureID = entry?.lectureID
        return ListeningLog.shared.lectures.first { $0.topic.id == item.id && $0.lectureID == lectureID }?
            .lectureTitle ?? item.title
    }
}
