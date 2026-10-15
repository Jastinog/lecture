import SwiftUI

/// Every lecture listened to, newest first, under Safari's day headings; a
/// tap plays it again.
struct HistoryView: View {
    @ObservedObject private var log = ListeningLog.shared
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter
    @StateObject private var starter = LectureStarter()
    @State private var query = ""

    var body: some View {
        let lectures = log.lectures
        let days = self.days(lectures)
        List {
            if !lectures.isEmpty {
                TableSearchBar(text: $query, prompt: String(localized: "Search History"))
            }
            ForEach(days, id: \.title) { day in
                Section {
                    ForEach(day.entries.indexed, id: \.element.id) { i, entry in
                        RowButton(action: { play(entry) }) {
                            LectureLine(entry, detail: when(entry, on: day.title), loading: starter.loading == entry.id,
                                        isCurrent: player.isCurrent(topicID: entry.topic.id, lectureID: entry.lectureID))
                        }
                        .classicSwipeButton(id: entry.id) { log.remove(id: entry.id) }
                        .zebraRow(i)
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: day.title)
                }
            }
        }
        .classicSwipeList()
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .plainBackground()
        .overlay {
            if lectures.isEmpty {
                ClassicEmptyState(String(localized: "No History"), message: String(localized: "Lectures you listen to will appear here"))
            } else if days.isEmpty {
                ClassicEmptyState.noResults
            }
        }
        .navigationTitle("History")
        .toolbar {
            ClassicToolbarItem(.trailing) {
                ConfirmingButton(confirm: String(localized: "Clear History")) { RecentsStore.shared.clear() } label: {
                    Text("Clear")
                }
                .buttonStyle(.classicBar)
                .disabled(lectures.isEmpty)
            }
            NowPlayingToolbarItem()
        }
        .onDisappear { starter.cancel() }
        .libraryDestinations()
    }

    private func play(_ entry: ListeningEntry) { starter.play(entry, player: player, router: router) }

    /// When it was heard last: the time today and yesterday, the date before.
    private func when(_ entry: ListeningEntry, on day: String) -> String {
        day == Self.earlier ? entry.lastHeardDate.formatted(.dateTime.day().month(.abbreviated)) : entry.lastHeardTime
    }

    private static var earlier: String { String(localized: "Earlier") }

    /// The lectures matching the search, under Safari's day headings: Today,
    /// Yesterday, then everything older.
    private func days(_ lectures: [ListeningEntry]) -> [(title: String, entries: [ListeningEntry])] {
        let calendar = Calendar.current
        let matching = lectures.filter {
            searchMatches(query, $0.lectureTitle, $0.topic.title, $0.topic.lecturer.name)
        }
        let today = String(localized: "Today"), yesterday = String(localized: "Yesterday")
        let earlier = Self.earlier
        let day = { (entry: ListeningEntry) in
            let date = entry.lastHeardDate
            return calendar.isDateInToday(date) ? today : calendar.isDateInYesterday(date) ? yesterday : earlier
        }
        // Newest first already, so each heading's lectures stay in order.
        return [today, yesterday, earlier].compactMap { title in
            let entries = matching.filter { day($0) == title }
            return entries.isEmpty ? nil : (title, entries)
        }
    }
}
