import SwiftUI

/// A topic list paged by the server's own page count: the catalog home and a
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
                if reset { items = result.items } else { items += result.items }
                page = result.page; pages = result.pages; count = result.count
            case .failure:
                error = errorMessage
            }
        }
    }
}

@MainActor
final class CatalogViewModel: TopicPager {
    /// The home feed, held globally so its topics and scroll survive a rebuild.
    static let home = CatalogViewModel()

    let group: TopicGroup?
    @Published var sort: SortMode = .new { didSet { if oldValue != sort { reload() } } }

    private let api: LibraryProviding

    init(group: TopicGroup? = nil, api: LibraryProviding = API.library) {
        self.group = group
        self.api = api
        super.init(errorMessage: "Couldn’t load the catalog")
    }

    override func fetchPage(_ page: Int) async throws -> CatalogPage {
        try await api.topics(group: group, sort: sort, page: page)
    }
}

struct CatalogView: View {
    @StateObject private var vm: CatalogViewModel

    /// Scoped to a group (pushed from Browse) vs. the home feed.
    private let scoped: Bool

    init() { _vm = StateObject(wrappedValue: .home); scoped = false }
    init(group: TopicGroup) {
        _vm = StateObject(wrappedValue: CatalogViewModel(group: group)); scoped = true
    }

    var body: some View {
        List {
            if !scoped {
                // The search bar heads the table and scrolls away with it.
                SearchBarLink(prompt: "Topic, lecture or lecturer", accessory: { EmptyView() },
                              scope: { EmptyView() })
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                ContinueListeningCard()
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
            } header: {
                if !scoped { PlainSectionHeader(title: vm.sort == .new ? "New Topics" : vm.sort.title) }
            }
        }
        .listStyle(.plain)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .topicRowsOmit(scoped ? .group : [])
        .navigationTitle(scoped ? (vm.group?.name ?? "Topics") : "Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if scoped {
                    ClassicTitle(vm.group?.name ?? "Topics")
                } else {
                    // The charts in the bar, as the App Store's Featured screen
                    // carried New / What's Hot.
                    ClassicSegmentedControl(options: SortMode.allCases.map { ($0, $0.title) },
                                            selection: $vm.sort, skin: .blue)
                        .frame(width: 160)
                }
            }
            if scoped {
                ClassicToolbarItem(.trailing) {
                    FilterMenu(sort: $vm.sort)
                }
                NowPlayingToolbarItem()
            } else {
                // iOS 6 bars held one button a side: "Browse" opens the groups,
                // "Now Playing" the player.
                ClassicToolbarItem(.leading) {
                    NavigationLink("Groups", value: BrowseRoute())
                        .buttonStyle(.classicBar)
                }
                NowPlayingToolbarItem()
            }
        }
        .classicRefreshable { await vm.refresh() }
        .task { if vm.items.isEmpty { vm.reload() } }
    }
}

// MARK: - Browse

/// Route to the list of topic groups.
struct BrowseRoute: Hashable {}

struct BrowseView: View {
    var body: some View {
        List {
            Section {
                ForEach(API.library.groups) { group in
                    RowLink(value: group) { Text(group.name) }
                }
                .plainRow()
            } header: {
                PlainSectionHeader(title: "Groups")
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
    }
}
