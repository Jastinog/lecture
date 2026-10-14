import SwiftUI

/// Full listening history (every recently-played topic, newest first).
struct HistoryView: View {
    @ObservedObject private var recents = RecentsStore.shared
    @State private var query = ""

    var body: some View {
        List {
            if !recents.items.isEmpty {
                TableSearchBar(text: $query, prompt: String(localized: "Search History"))
            }
            ForEach(days, id: \.title) { day in
                Section {
                    ForEach(day.items.indexed, id: \.element.id) { i, item in
                        TopicRow(topic: item.summary)
                            .classicSwipeButton(id: item.id) { recents.remove(id: item.id) }
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
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .overlay {
            if recents.items.isEmpty {
                ClassicEmptyState(String(localized: "No History"), message: String(localized: "Topics you listen to will appear here"))
            } else if days.isEmpty {
                ClassicEmptyState.noResults
            }
        }
        .navigationTitle("History")
        .toolbar {
            ClassicToolbarItem(.trailing) {
                ConfirmingButton(confirm: String(localized: "Clear History")) { recents.clear() } label: {
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
        let today = String(localized: "Today"), yesterday = String(localized: "Yesterday")
        let earlier = String(localized: "Earlier")
        let day = { (item: RecentTopic) in
            let date = Date(timeIntervalSince1970: item.updatedAt)
            return calendar.isDateInToday(date) ? today : calendar.isDateInYesterday(date) ? yesterday : earlier
        }
        // Newest first already, so each heading's topics stay in order.
        return [today, yesterday, earlier].compactMap { title in
            let items = matching.filter { day($0) == title }
            return items.isEmpty ? nil : (title, items)
        }
    }
}
