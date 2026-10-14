import SwiftUI

/// A topic list paged by the server's own page count: every new topic and a
/// group's list. Subclasses override `fetchPage`.
@MainActor
class TopicPager: PagedLoader {
    @Published private(set) var items: [Topic] = []
    @Published private(set) var page = 0
    @Published private(set) var pages = 1
    @Published private(set) var count = 0

    private let errorMessage: String

    init(errorMessage: String) { self.errorMessage = errorMessage }

    var canLoadMore: Bool { page < pages }

    /// Fetches one 1-based page. Override in subclasses.
    func fetchPage(_ page: Int) async throws -> CatalogPage { throw APIError.noData }

    func reload() { Task { await fetch(reset: true) } }

    /// Awaitable reload for pull-to-refresh.
    func refresh() async { await fetch(reset: true) }

    func loadMore() {
        guard !loading, !loadingMore, canLoadMore else { return }
        Task { await fetch(reset: false) }
    }

    private func fetch(reset: Bool) async {
        await load(reset: reset, { try await fetchPage(reset ? 1 : page + 1) }) { result in
            switch result {
            case .success(let result):
                if reset {
                    items = result.items
                } else {
                    // Topics added meanwhile shift the pages: skip the ones already
                    // shown rather than list them twice.
                    let shown = Set(items.map(\.id))
                    items += result.items.filter { !shown.contains($0.id) }
                }
                page = result.page; pages = result.pages; count = result.count
            case .failure:
                error = errorMessage
            }
        }
    }
}

@MainActor
final class CatalogViewModel: TopicPager {
    /// Every new topic, held globally so its topics survive a rebuild.
    static let newTopics = CatalogViewModel()

    let group: TopicGroup?
    /// The catalog language the list was loaded in; "Show More" keeps it.
    private(set) var language: String?

    private let api: LibraryProviding

    init(group: TopicGroup? = nil, api: LibraryProviding = API.library) {
        self.group = group
        self.api = api
        super.init(errorMessage: String(localized: "Couldn’t load the catalog"))
    }

    override func fetchPage(_ page: Int) async throws -> CatalogPage {
        if page == 1 { language = CatalogLanguageStore.shared.language }
        return try await api.topics(group: group, page: page, language: language)
    }
}

/// Every new topic, newest first (from Home), or a group's topics (from Groups).
struct CatalogView: View {
    @StateObject private var vm: CatalogViewModel
    @ObservedObject private var languages = CatalogLanguageStore.shared

    init() { _vm = StateObject(wrappedValue: .newTopics) }
    init(group: TopicGroup) { _vm = StateObject(wrappedValue: CatalogViewModel(group: group)) }

    private var title: String { vm.group?.name ?? String(localized: "New Topics") }

    var body: some View {
        List {
            if languages.items.count > 1 {
                Section {
                    CatalogLanguagePicker()
                        .padding(.vertical, 10)
                        .listRowSeparator(.hidden)
                        .plainRow()
                }
            }
            Section {
                // On the rows, not the section: the header band stays full width.
                Group {
                    if vm.loading && vm.items.isEmpty {
                        HStack { Spacer(); ClassicSpinner(); Spacer() }
                    } else if let error = vm.error, vm.items.isEmpty {
                        ErrorRetryRow(message: error) { vm.reload() }
                    }

                    ForEach(vm.items) { topic in
                        TopicRow(topic: topic)
                            .onAppear { if topic.id == vm.items.last?.id { vm.loadMore() } }
                    }

                    PagingFooter(loading: vm.loadingMore, canLoadMore: vm.canLoadMore && !vm.items.isEmpty,
                                 loadMore: vm.loadMore)
                }
                .plainRow()
            }
        }
        .listStyle(.plain)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .topicRowsOmit(vm.group == nil ? [] : .group)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ClassicTitle(title)
            }
            NowPlayingToolbarItem()
        }
        .classicRefreshable { await vm.refresh() }
        // Loads at first, and again whenever the catalog language changes.
        .task(id: languages.language) {
            if vm.items.isEmpty || vm.language != languages.language { await vm.refresh() }
        }
    }
}

// MARK: - Browse

/// Route to the list of topic groups.
struct BrowseRoute: Hashable {}

struct BrowseView: View {
    @ObservedObject private var groups = GroupStore.shared

    var body: some View {
        List {
            Section {
                ForEach(groups.items) { group in
                    RowLink(value: group) { Text(group.name) }
                }
                .plainRow()
            } header: {
                PlainSectionHeader(title: String(localized: "Groups"))
            }
        }
        // Plain text on every row, as iOS 6 listed categories.
        .font(.rowLabel)
        .lineLimit(1)
        .listStyle(.plain)
        .plainBackground()
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NowPlayingToolbarItem() }
        .overlay {
            if groups.items.isEmpty {
                if groups.failed { LoadFailedState { await groups.refresh() } } else { ClassicSpinner() }
            }
        }
        .task { await groups.refresh() }
    }
}
