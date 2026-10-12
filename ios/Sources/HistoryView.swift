import SwiftUI

/// Full listening history (every recently-played topic, newest first).
struct HistoryView: View {
    @ObservedObject private var recents = RecentsStore.shared
    @State private var query = ""

    var body: some View {
        List {
            if !recents.items.isEmpty {
                TableSearchBar(text: $query, prompt: "Search History")
            }
            ForEach(days, id: \.title) { day in
                Section {
                    ForEach(day.items) { item in
                        TopicRow(topic: item.summary)
                            .classicSwipeButton(id: item.id) { recents.remove(id: item.id) }
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: day.title)
                }
            }
        }
        .classicSwipeList()
        .listStyle(.plain)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .overlay {
            if recents.items.isEmpty {
                ClassicEmptyState("No History", message: "Topics you listen to will appear here")
            } else if days.isEmpty {
                ClassicEmptyState.noResults
            }
        }
        .navigationTitle("History")
        .toolbar {
            ClassicToolbarItem(.trailing) {
                ConfirmingButton(confirm: "Clear History") { recents.clear() } label: {
                    Text("Clear")
                }
                .buttonStyle(.classicBar)
                .disabled(recents.items.isEmpty)
            }
            NowPlayingToolbarItem()
        }
        .libraryDestinations()
    }

    /// The entries matching the search, under Safari's day headings: Today,
    /// Yesterday, then everything older.
    private var days: [(title: String, items: [RecentTopic])] {
        let calendar = Calendar.current
        let matching = recents.items.filter { searchMatches(query, $0.title, $0.summary.lecturer.name) }
        let day = { (item: RecentTopic) in
            let date = Date(timeIntervalSince1970: item.updatedAt)
            return calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday" : "Earlier"
        }
        // Newest first already, so each heading's topics stay in order.
        return ["Today", "Yesterday", "Earlier"].compactMap { title in
            let items = matching.filter { day($0) == title }
            return items.isEmpty ? nil : (title, items)
        }
    }
}

/// "Continue listening" card atop the home feed: the most recent unfinished topic,
/// one tap to resume it, a tap on the card to open its page. Shown only while
/// nothing is loaded in the player — once playing, the mini player covers it.
struct ContinueListeningCard: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter
    @ObservedObject private var recents = RecentsStore.shared

    @State private var starting = false
    @State private var error: String?

    private var item: RecentTopic? {
        guard player.topic == nil else { return nil }
        return recents.items.first { !PlaybackMath.isFinished($0.fraction) }
    }

    var body: some View {
        if let item {
            let summary = item.summary
            Section {
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
                                    Text(detail(item))
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

                        Button { resume(item, summary: summary) } label: {
                            ZStack {
                                Circle().fill(Palette.blueButton.gradient)
                                    .overlay { Circle().strokeBorder(Palette.rgb(0x1349A0), lineWidth: 1) }
                                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                                if starting {
                                    ClassicSpinner(style: .white)
                                } else {
                                    Image(systemName: "play.fill")
                                        .font(.title3)
                                        .engraved()
                                        .offset(x: 1)
                                }
                            }
                            .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(starting)
                        .accessibilityLabel("Resume “\(item.title)”")
                    }
                    if let error {
                        Text(error).font(.app(.caption)).foregroundStyle(.red)
                    }
                }
                // The same grid as the topic rows below.
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .plainRow()
            } header: {
                PlainSectionHeader(title: "Continue")
            }
        }
    }

    /// "Lecture 7 · 34%".
    private func detail(_ item: RecentTopic) -> String {
        let percent = formatPercent(item.fraction)
        guard let entry = ProgressStore.entry(topicID: item.id) else { return percent }
        return "Lecture \(entry.index + 1) · \(percent)"
    }

    /// Resumes the topic without opening its page. A downloaded copy starts
    /// instantly; otherwise the same lookup the topic page uses.
    private func resume(_ item: RecentTopic, summary: Topic) {
        error = nil
        if let saved = DownloadManager.shared.savedTopics[item.id] {
            player.load(topic: saved, summary: summary)
            router.openPlayer()
            return
        }
        starting = true
        Task {
            defer { starting = false }
            do {
                player.load(topic: try await TopicCache.shared.resolve(summary.id).detail,
                            summary: summary)
                router.openPlayer()
            } catch {
                self.error = "Couldn’t load the topic. Check your connection."
            }
        }
    }
}
