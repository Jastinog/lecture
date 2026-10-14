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

/// The first tab: search, what's being listened to, the lecture of the day,
/// then five each of what's trending, the newest topics and the newest
/// selections. The bar's left button opens the listening calendar.
struct HomeView: View {
    @ObservedObject private var model = HomeFeedModel.shared
    @ObservedObject private var languages = CatalogLanguageStore.shared
    @ObservedObject private var recents = RecentsStore.shared

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
                        ContinueRow(item: item).zebraBackground(i)
                    }
                } header: {
                    PlainSectionHeader(title: String(localized: "Continue"))
                }
            }

            if let hit = model.feed?.lectureOfTheDay {
                Section {
                    LectureOfTheDayRow(hit: hit)
                        .zebraBackground(0)
                } header: {
                    PlainSectionHeader(title: String(localized: "Lecture of the Day"))
                }
            }

            if let feed = model.feed {
                if !feed.trending.isEmpty {
                    Section {
                        ForEach(feed.trending.indexed, id: \.element.id) { i, topic in
                            TopicRow(topic: topic).zebraRow(i)
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
        // Loads at first, and again whenever the catalog language changes.
        .task(id: languages.language) {
            if model.feed == nil || model.language != languages.language { await model.refresh() }
        }
    }

    /// The topics listened to lately and not finished, newest first.
    private var unfinished: [RecentTopic] {
        Array(recents.items.filter { !PlaybackMath.isFinished($0.fraction) }.prefix(Self.limit))
    }
}

/// A topic being listened to, under "Continue": a tap on the card opens its
/// page, the play button resumes it where it was left.
private struct ContinueRow: View {
    let item: RecentTopic

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter

    @State private var starting = false
    @State private var error: String?
    /// The topic being fetched to resume; cancelled if the row goes away, so
    /// the player doesn't open over wherever the listener went meanwhile.
    @State private var resuming: Task<Void, Never>?

    var body: some View {
        let summary = item.summary
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Button { router.push(summary) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        CoverImage(url: summary.coverURL,
                                   width: RowMetrics.coverWidth, corner: 0)
                            .bookCover()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.rowTitle)
                                .foregroundStyle(Palette.text)
                                .lineLimit(2)
                            Text(summary.lecturer.name)
                                .font(.rowSubtitle)
                                .foregroundStyle(Palette.detailText)
                                .lineLimit(1)
                            Text(detail)
                                .font(.rowDetail)
                                .foregroundStyle(Palette.secondaryText)
                            ClassicProgressBar(value: item.fraction)
                                .padding(.top, 5)
                        }
                        .padding(.top, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                RoundPlayButton(starting: starting, playing: isPlaying, action: resume)
                    .accessibilityLabel(isPlaying ? "Now Playing" : "Resume “\(item.title)”")
            }
            if let error {
                Text(error).font(.app(.caption)).foregroundStyle(.red)
            }
        }
        // The same grid as the topic rows below.
        .padding(.vertical, 8)
        .plainRow()
        .onDisappear { resuming?.cancel() }
    }

    /// Playing in the player now: the button opens it.
    private var isPlaying: Bool { player.topic?.id == item.id && player.isPlaying }

    /// "Lecture 7 · 34%": the lecture's number in the whole topic, when its
    /// lectures are at hand (the saved index counts a language-narrowed list).
    private var detail: String {
        let percent = formatPercent(item.fraction)
        guard let entry = ProgressStore.entry(topicID: item.id) else { return percent }
        let lectures = TopicCache.shared.get(item.id)?.detail.lectures
            ?? DownloadManager.shared.savedTopics[item.id]?.lectures
        let index = lectures.flatMap { entry.index(in: $0) } ?? entry.index
        return String(localized: "Lecture \(index + 1) · \(percent)")
    }

    /// Resumes the topic without opening its page. A downloaded copy starts
    /// instantly; otherwise the same lookup the topic page uses.
    private func resume() {
        error = nil
        if isPlaying {
            router.openPlayer()
            return
        }
        let summary = item.summary
        if let saved = DownloadManager.shared.savedTopics[item.id] {
            player.load(topic: saved, summary: summary)
            router.openPlayer()
            return
        }
        starting = true
        resuming = Task {
            defer { starting = false }
            do {
                let detail = try await TopicCache.shared.resolve(summary.id).detail
                guard !Task.isCancelled else { return }
                player.load(topic: detail, summary: summary)
                router.openPlayer()
            } catch {
                if !error.isCancellation { self.error = String(localized: "Couldn’t load the topic. Check your connection.") }
            }
        }
    }
}

/// The lecture of the day: a tap on the card opens its topic, the play
/// button plays it there.
private struct LectureOfTheDayRow: View {
    let hit: LectureHit

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter

    @State private var starting = false
    @State private var error: String?
    @State private var playing: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Button { router.push(hit.topic) } label: {
                    MediaRow(coverURL: hit.topic.coverURL, title: hit.lecture.displayTitle(at: hit.index),
                             subtitle: hit.topic.lecturer.name) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.topic.title)
                                .font(.rowDetail)
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(facts)
                                    .font(.rowCaption)
                                    .foregroundStyle(Palette.secondaryText)
                                    .lineLimit(1)
                                LanguageTag(code: hit.lecture.language)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                RoundPlayButton(starting: starting, playing: isPlaying, action: play)
                    .accessibilityLabel(isPlaying ? "Now Playing" : "Play “\(hit.lecture.title)”")
            }
            if let error {
                Text(error).font(.app(.caption)).foregroundStyle(.red)
            }
        }
        .plainRow()
        .onDisappear { playing?.cancel() }
    }

    /// Playing in the player now: the button opens it.
    private var isPlaying: Bool { player.currentLecture?.id == hit.lecture.id && player.isPlaying }

    /// "45 min · 1972 · Bombay".
    private var facts: String {
        [formatDuration(hit.lecture.duration), hit.lecture.year.map(String.init), hit.lecture.event]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Plays the lecture in its topic and opens the player.
    private func play() {
        error = nil
        if isPlaying {
            router.openPlayer()
            return
        }
        starting = true
        playing = Task {
            defer { starting = false }
            do {
                let page = try await TopicCache.shared.resolve(hit.topic.id)
                guard !Task.isCancelled else { return }
                // Found by id: the hit's index counts only its language's lectures.
                let index = page.detail.lectures.firstIndex { $0.id == hit.lecture.id } ?? hit.index
                player.load(topic: page.detail, summary: page.summary, index: index)
                router.openPlayer()
            } catch {
                if !error.isCancellation { self.error = String(localized: "Couldn’t load the topic. Check your connection.") }
            }
        }
    }
}

/// The round blue play button of Home's rows; a spinner while the topic
/// loads, a waveform while it's the one playing.
private struct RoundPlayButton: View {
    let starting: Bool
    let playing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Palette.blueButton.gradient)
                    .overlay { Circle().strokeBorder(Palette.rgb(0x1349A0), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                if starting {
                    ClassicSpinner(style: .white)
                } else {
                    Image(systemName: playing ? "waveform" : "play.fill")
                        .font(.title3)
                        .engraved()
                        .offset(x: playing ? 0 : 1)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(starting)
    }
}
