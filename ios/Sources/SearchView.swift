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
            self.error = "Couldn’t search"
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
    /// The lecture hit whose topic is loading, to play it.
    @State private var starting: Int?
    /// The topic being fetched to play a hit; cancelled on leaving the screen, so
    /// the player doesn't open over wherever the listener went meanwhile.
    @State private var playing: Task<Void, Never>?

    var body: some View {
        // A failed search shows why, not the previous query's results.
        let result = vm.hasQuery && vm.error == nil ? vm.result : SearchResult()
        List {
            if !vm.hasQuery && !history.list.items.isEmpty {
                recentSection
            }

            if !result.lecturers.isEmpty {
                Section {
                    ForEach(result.lecturers) { lecturer in
                        RowLink(value: lecturer) { LecturerRow(lecturer: lecturer) }
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: "Lecturers")
                }
            }

            if !result.topics.isEmpty {
                Section {
                    ForEach(result.topics) { TopicRow(topic: $0) }
                        .plainRow()
                } header: {
                    PlainSectionHeader(title: "Topics")
                }
            }

            if !result.lectures.isEmpty {
                Section {
                    ForEach(result.lectures) { hit in
                        RowButton(action: { play(hit) }) { LectureHitRow(hit: hit, loading: starting == hit.id) }
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: "Lectures")
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
            ClassicSearchBar(text: $vm.query, prompt: "Topics, lectures, lecturers",
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
            playing?.cancel()
        }
    }

    /// Plays a found lecture in its topic and opens the player.
    private func play(_ hit: LectureHit) {
        guard starting == nil else { return }
        history.record(vm.query)
        starting = hit.id
        playing = Task {
            defer { starting = nil }
            do {
                let page = try await TopicCache.shared.resolve(hit.topic.id)
                guard !Task.isCancelled else { return }
                // Found by id: the hit's index counts only its language's lectures.
                let index = page.detail.lectures.firstIndex { $0.id == hit.lecture.id } ?? hit.index
                player.load(topic: page.detail, summary: page.summary, index: index)
                router.openPlayer()
            } catch {
                guard !error.isCancellation else { return }
                Alerts.shared.show("Couldn’t Play", message: "Check your connection and try again.",
                                   [AlertButton(title: "OK", isDefault: true)])
            }
        }
    }

    private var recentSection: some View {
        Section {
            ForEach(history.list.items, id: \.self) { q in
                RowButton(action: { vm.query = q }) {
                    Text(q)
                        .font(.rowLabel)
                        .rowForeground(Palette.text)
                        .lineLimit(1)
                }
                .classicSwipeButton(id: q) { history.remove(q) }
            }
            .plainRow()
        } header: {
            PlainSectionHeader(title: "Recent")
                .overlay(alignment: .trailing) {
                    SectionHeaderButton(title: "Clear") { history.clear() }
                }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if vm.isLoading {
            ClassicSpinner()
        } else if let error = vm.error {
            ClassicEmptyState("Search Failed", message: error) {
                Button("Try Again") { vm.search() }
                    .buttonStyle(.classicWhite)
            }
        } else if !vm.hasQuery {
            if history.list.items.isEmpty {
                ClassicEmptyState("Search Lectures", message: "Type at least \(SearchQuery.minLength) characters")
            }
        } else {
            ClassicEmptyState.noResults
        }
    }
}

/// A lecture found by title: the title, then "Topic · Lecturer" and its length.
private struct LectureHitRow: View {
    let hit: LectureHit
    let loading: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.lecture.title)
                    .font(.rowTitle)
                    .rowForeground(Palette.text)
                    .lineLimit(1)
                Text("\(hit.topic.title) · \(hit.topic.lecturer.name)")
                    .font(.rowDetail)
                    .rowForeground(Palette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if loading {
                ClassicSpinner()
            } else {
                Text(formatTime(hit.lecture.duration))
                    .font(.rowDetail)
                    .rowForeground(Palette.secondaryText)
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
    }
}
