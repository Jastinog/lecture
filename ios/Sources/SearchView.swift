import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var result = SearchResult()
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var task: Task<Void, Never>?

    /// A query long enough to actually search.
    var hasQuery: Bool { SearchQuery.isSearchable(query) }

    func search() {
        task?.cancel()
        let q = query
        task = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // debounce
            guard !Task.isCancelled else { return }
            await run(q)
        }
    }

    private func run(_ q: String) async {
        guard SearchQuery.isSearchable(q) else {
            result = SearchResult(); error = nil; isLoading = false
            return
        }
        isLoading = true; error = nil
        do {
            let found = try await API.library.search(SearchQuery.trimmed(q),
                                                     language: CatalogLanguageStore.shared.language)
            guard !Task.isCancelled else { return }
            result = found
        } catch {
            // Typing on cancels the old request; the newer one owns the spinner.
            if Task.isCancelled || error.isCancellation { return }
            self.error = String(localized: "Couldn’t search")
        }
        isLoading = false
    }
}

/// Persisted recent queries (see `SearchHistoryList` for the rules).
@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()
    private let key = "lecture.searchHistory"
    @Published private(set) var list: SearchHistoryList

    private init() {
        list = SearchHistoryList(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func record(_ query: String) { list.record(query); save() }
    func remove(_ query: String) { list.remove(query); save() }
    func clear() { list = SearchHistoryList(); save() }
    private func save() { UserDefaults.standard.set(list.items, forKey: key) }
}

/// Search over the whole catalog: lecturers, topics and single lectures, under
/// one band each, with the recent queries while the field is empty.
struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @ObservedObject private var history = SearchHistoryStore.shared
    @ObservedObject private var languages = CatalogLanguageStore.shared
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var starter = LectureStarter()

    var body: some View {
        // A failed search shows why, not the previous query's results.
        let result = vm.hasQuery && vm.error == nil ? vm.result : SearchResult()
        List {
            if !vm.hasQuery && !history.list.items.isEmpty {
                recentSection
            }

            if !result.lecturers.isEmpty {
                Section {
                    ForEach(result.lecturers.indexed, id: \.element.id) { i, lecturer in
                        RowLink(value: lecturer) { LecturerRow(lecturer: lecturer) }
                            .zebraRow(i)
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: String(localized: "Lecturers"))
                }
            }

            if !result.topics.isEmpty {
                Section {
                    ForEach(result.topics.indexed, id: \.element.id) { i, topic in
                        TopicRow(topic: topic).zebraRow(i)
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: String(localized: "Topics"))
                }
            }

            if !result.lectures.isEmpty {
                Section {
                    ForEach(result.lectures.indexed, id: \.element.id) { i, hit in
                        RowButton(action: { play(hit) }) {
                            LectureLine(hit, loading: starter.isLoading(hit),
                                        isCurrent: player.isCurrent(topicID: hit.topic.id, lectureID: hit.lecture.id))
                        }
                        .zebraRow(i)
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: String(localized: "Lectures"))
                }
            }
        }
        .classicSwipeList()
        .listStyle(.plain)
        // The previous query's results, dimmed while the new one runs.
        .opacity(vm.isLoading && !result.isEmpty ? 0.5 : 1)
        .plainBackground()
        .overlay {
            if result.isEmpty { emptyState }
        }
        // The search bar is the screen's bar, as when iOS 6 searched a table:
        // the navigation bar steps aside and "Cancel" goes back.
        .navigationTitle("Search")
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            ClassicSearchBar(text: $vm.query, prompt: String(localized: "Topics, lectures, lecturers"),
                             onSubmit: { history.record(vm.query) }, autofocus: vm.query.isEmpty,
                             onCancel: { dismiss() }) {
                CatalogLanguagePicker()
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: vm.query) { _, _ in vm.search() }
        .onChange(of: languages.language) { _, _ in vm.search() }
        // Leaving for a result counts as a successful search.
        .onDisappear {
            if !vm.result.isEmpty { history.record(vm.query) }
            starter.cancel()
        }
    }

    /// Plays a found lecture in its topic and opens the player.
    private func play(_ hit: LectureHit) {
        history.record(vm.query)
        starter.play(hit, player: player, router: router)
    }

    private var recentSection: some View {
        Section {
            ForEach(history.list.items.indexed, id: \.element) { i, q in
                RowButton(action: { vm.query = q }) {
                    Text(q)
                        .font(.rowLabel)
                        .rowForeground(Palette.text)
                        .lineLimit(1)
                }
                .classicSwipeButton(id: q) { history.remove(q) }
                .zebraRow(i)
            }
            .plainRow()
        } header: {
            PlainSectionHeader(title: String(localized: "Recent"))
                .overlay(alignment: .trailing) {
                    SectionHeaderButton(title: String(localized: "Clear")) { history.clear() }
                }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if vm.isLoading {
            ClassicSpinner()
        } else if let error = vm.error {
            ClassicEmptyState(String(localized: "Search Failed"), message: error) {
                Button("Try Again") { vm.search() }
                    .buttonStyle(.classicWhite)
            }
        } else if !vm.hasQuery {
            if history.list.items.isEmpty {
                ClassicEmptyState(String(localized: "Search Lectures"),
                                  message: String(localized: "Type at least \(SearchQuery.minLength) characters"))
            }
        } else {
            ClassicEmptyState.noResults
        }
    }
}
