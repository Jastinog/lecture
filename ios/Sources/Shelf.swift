import SwiftUI

/// A topic's status on the shelf.
enum ShelfStatus: String, Codable, CaseIterable, Identifiable {
    case want       // Хочу послушать
    case listening  // Слушаю
    case finished   // Прослушано
    case onHold     // Отложено

    var id: String { rawValue }

    var title: String {
        switch self {
        case .want: return String(localized: "Want to Listen")
        case .listening: return String(localized: "Listening")
        case .finished: return String(localized: "Finished")
        case .onHold: return String(localized: "On Hold")
        }
    }

    /// Fits a button or a segment: "Want to Listen" shortens to "Want".
    var shortTitle: String { self == .want ? String(localized: "Want", comment: "Short for Want to Listen") : title }
}

/// A topic on the shelf, persisted locally (UserDefaults). Newest first.
struct ShelfTopic: Codable, Identifiable, Hashable {
    /// The full topic card, so the shelf renders like the main list.
    var summary: Topic
    var status: ShelfStatus
    var addedAt: Double      // epoch seconds

    var id: Int { summary.id }

    fileprivate enum CodingKeys: String, CodingKey { case summary, status, addedAt }
}

extension ShelfTopic {
    /// Decodes old favorites (which had no `status`) into the shelf, defaulting
    /// them to "Want to Listen" so nothing is lost when the shelf replaces the old
    /// favorites list. In an extension so the memberwise initializer is still
    /// synthesized (used by `ShelfStore.setStatus`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(Topic.self, forKey: .summary)
        status = try c.decodeIfPresent(ShelfStatus.self, forKey: .status) ?? .want
        addedAt = try c.decodeIfPresent(Double.self, forKey: .addedAt) ?? 0
    }
}

/// Local shelf store, mirroring `RecentsStore`'s UserDefaults pattern. Reuses the
/// old favorites key so existing favorites migrate in transparently.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    private let legacyKey = "lecture.favorites"
    private let file = "shelf.json"
    private let version = 1

    @Published private(set) var items: [ShelfTopic] = [] {
        didSet { index = Dictionary(items.map { ($0.id, $0.status) },
                                    uniquingKeysWith: { first, _ in first }) }
    }
    // url → status index for O(1) lookups — every list row and shelf button
    // queries it on each render. (didSet keeps it in sync; init seeds it.)
    private var index: [Int: ShelfStatus] = [:]

    private init() {
        let loaded = load()
        items = loaded
        index = Dictionary(loaded.map { ($0.id, $0.status) },
                           uniquingKeysWith: { first, _ in first })
    }

    /// The topic's shelf status, or nil if it isn't on the shelf.
    func status(_ id: Int) -> ShelfStatus? { index[id] }

    /// Adds the topic (or updates its status) and moves it to the top.
    func setStatus(_ status: ShelfStatus, for topic: Topic) {
        let now = Date().timeIntervalSince1970
        let item = ShelfTopic(summary: topic, status: status, addedAt: now)
        items.removeAll { $0.id == topic.id }
        items.insert(item, at: 0)
        persist()
        SyncEngine.shared.record(ShelfRecord(item, at: now), in: \.shelf)
    }

    func remove(id: Int) {
        items.removeAll { $0.id == id }
        persist()
        SyncEngine.shared.remove([id], in: \.shelf, as: ShelfRecord.init(removing:at:))
    }

    /// Topics shelved, moved or removed on the listener's other devices; not
    /// synced back.
    func apply(saved: [ShelfTopic], removed: Set<Int>) {
        guard !saved.isEmpty || !removed.isEmpty else { return }
        let replaced = removed.union(saved.map(\.id))
        items = (items.filter { !replaced.contains($0.id) } + saved).sorted { $0.addedAt > $1.addedAt }
        persist()
    }

    /// Auto-advances the status from playback progress, but only for topics already
    /// on the shelf — the shelf stays curated (history records everything played).
    /// Want → Listening when playback starts; anything → Finished near the end.
    func applyProgress(id: Int, fraction: Double) {
        guard let current = index[id] else { return }
        let next: ShelfStatus?
        if PlaybackMath.isFinished(fraction) {
            next = current == .finished ? nil : .finished
        } else {
            next = current == .want ? .listening : nil
        }
        guard let next, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = next
        persist()
        SyncEngine.shared.record(ShelfRecord(items[i], at: Date().timeIntervalSince1970), in: \.shelf)
    }

    private func persist() { Store.save(items, version: version, to: file) }
    private func load() -> [ShelfTopic] {
        Store.loadOrMigrate([ShelfTopic].self, legacyKey: legacyKey,
                            version: version, file: file, default: [])
    }
}

/// The shelf's statuses for a topic in an action sheet: the others to move it
/// to, and "Remove from Shelf" when it's on the shelf. The topic row's long press
/// and the topic page's shelf button both offer it.
enum ShelfActions {
    @MainActor static func show(for topic: Topic) {
        let shelf = ShelfStore.shared
        let current = shelf.status(topic.id)
        let moves = ShelfStatus.allCases.filter { $0 != current }.map { status in
            SheetAction(title: status.title) { shelf.setStatus(status, for: topic) }
        }
        let remove: [SheetAction] = current == nil ? [] : [.destructive(String(localized: "Remove from Shelf")) { shelf.remove(id: topic.id) }]
        ActionSheets.shared.show(topic.title, moves + remove)
    }
}

/// Filter for the shelf tab: all topics, or one status.
enum ShelfFilter: String, CaseIterable, Identifiable {
    case all, want, listening, finished, onHold
    var id: String { rawValue }
    /// The status this filter selects, or nil for "all". The non-`all` cases share
    /// their raw values with `ShelfStatus`, so the mapping is a plain lookup.
    var status: ShelfStatus? { ShelfStatus(rawValue: rawValue) }
    var title: String { status?.title ?? String(localized: "All") }
    /// Fits a segment of the shelf's filter bar.
    var shortTitle: String { status?.shortTitle ?? title }
}

/// Shelf tab — the saved topics standing on wooden shelves, newest first,
/// filterable by status. A long press on a topic changes its status.
struct ShelfView: View {
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var filter: ShelfFilter = .all
    /// The shelves' visible size, for how many topics fit per row and how many
    /// empty shelves fill the screen.
    @State private var viewport = CGSize.zero
    @State private var scroll = ScrollPosition(edge: .top)
    /// iBooks' second view: the topics as a list instead of on the shelves.
    @AppStorage("shelf.asList") private var asList = false

    private var visible: [ShelfTopic] {
        guard let status = filter.status else { return shelf.items }
        return shelf.items.filter { $0.status == status }
    }

    var body: some View {
        Group {
            if asList { list } else { shelves }
        }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    woodHeader
                    filterBar
                }
                .background {
                    // Newsstand's top plank, scaled up (never stretched) to reach
                    // under the status bar, and its soft shadow over the shelves.
                    AspectFillImage(image: .classic("ShelfNavBar"), alignment: .bottom)
                        .ignoresSafeArea(edges: .top)
                }
                .overlay(alignment: .bottom) {
                    Image.classic("ShelfNavBarShadow")
                        .resizable()
                        .frame(height: 30)
                        .offset(y: 30)
                        .allowsHitTesting(false)
                }
                .zIndex(1)
            }
            .navigationTitle("Shelf")
            .toolbar(.hidden, for: .navigationBar)
            .libraryDestinations()
    }

    /// Rows of topics in Newsstand cubbies, topped up with empty ones to fill the
    /// screen. Sized with `onGeometryChange` rather than a `GeometryReader`: a
    /// reader under the header still reports the header as a safe-area inset,
    /// and the scroll view inside it then insets its content a second time.
    private var shelves: some View {
        let layout = ShelfLayout(width: max(viewport.width, 1))
        let rows = stride(from: 0, to: visible.count, by: layout.perRow).map {
            Array(visible[$0..<min($0 + layout.perRow, visible.count)])
        }
        let shelfCount = max(rows.count, Int((viewport.height / layout.rowHeight).rounded(.up)))
        return ScrollView {
            if viewport.width > 0 {
                LazyVStack(spacing: 0) {
                    // One sequence, so the empty shelves topping up the screen
                    // never share an identity with a shelf of topics.
                    ForEach(0..<shelfCount, id: \.self) { i in
                        ShelfRow(topics: i < rows.count ? rows[i] : [], layout: layout,
                                 ribbons: filter == .all)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        // Empty until measured, so it must claim the space itself.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollPosition($scroll)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // The first layout runs before the header's inset arrives, and the
            // scroll view keeps that offset: it opened ~100pt down the wall.
            if viewport == .zero { scroll.scrollTo(edge: .top) }
            viewport = size
        }
        .background(WoodBackground().ignoresSafeArea())
        .overlay(alignment: .top) {
            // Centred in the top cubby, clear of the planks.
            if visible.isEmpty {
                emptyState(color: Palette.rgb(0x6B4420)).frame(height: layout.rowHeight - ShelfLayout.plank)
                    // The maple stays light in both themes.
                    .environment(\.colorScheme, .light)
            }
        }
    }

    /// The shelf as iBooks listed it: topic rows on white, one section per
    /// status while every status is shown.
    private var list: some View {
        let byStatus = Dictionary(grouping: visible, by: \.status)
        let sections = ShelfStatus.allCases.compactMap { status in byStatus[status].map { (status: status, topics: $0) } }
        return List {
            ForEach(sections, id: \.status) { section in
                Section {
                    ForEach(section.topics) { item in TopicRow(topic: item.summary) }
                        .plainRow()
                } header: {
                    if filter == .all { PlainSectionHeader(title: section.status.title) }
                }
            }
        }
        .listStyle(.plain)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .overlay {
            if sections.isEmpty { emptyState() }
        }
    }

    /// The wooden navigation bar (Newsstand's top plank).
    private var woodHeader: some View {
        ZStack {
            Text("Shelf")
                .font(.helvetica(20, weight: .bold))
                .engraved()
            HStack {
                NavigationLink(value: SearchRoute()) {
                    Image.classic("BarSearch")
                }
                .buttonStyle(.classicWoodBar)
                .accessibilityLabel("Search")
                Spacer()
                HStack(spacing: 6) {
                    Button { asList.toggle() } label: {
                        Image(systemName: asList ? "square.grid.3x3.fill" : "list.bullet")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 22)
                    }
                    .buttonStyle(.classicWoodBar)
                    .accessibilityLabel(asList ? "Shelves" : "List")
                    NowPlayingBarButton(onWood: true)
                }
            }
            .padding(.horizontal, BarMetrics.edgeInset)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
    }

    /// The status filter as a segmented control on the plank.
    private var filterBar: some View {
        ClassicSegmentedControl(options: ShelfFilter.allCases.map { ($0, $0.shortTitle) },
                                selection: $filter)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }

    /// The empty shelf or filter, pressed into the list's white or, in a brown
    /// that shows on wood, into the maple.
    private func emptyState(color: Color? = nil) -> some View {
        ClassicEmptyState(filter == .all ? String(localized: "Your Shelf Is Empty") : String(localized: "Nothing Here"),
                          message: filter == .all
                              ? String(localized: "Topics you add to your shelf will appear here")
                              : String(localized: "No topics marked “\(filter.title)”"),
                          color: color)
    }
}

/// Shelf geometry for a given width: how many topics fit per plank and how big.
private struct ShelfLayout {
    let perRow: Int
    let coverWidth: CGFloat
    let rowHeight: CGFloat
    /// The board at the foot of Newsstand's cubby: a 3pt top surface over an
    /// 11pt front edge.
    static let plank: CGFloat = 14
    /// How far up the plank the topics stand: the middle of its top surface.
    static let footing: CGFloat = 12.5
    static let topGap: CGFloat = 20
    /// The cubby's slanted side walls.
    static let side: CGFloat = 34

    init(width: CGFloat) {
        let target: CGFloat = 96
        let spacing: CGFloat = 24
        perRow = max(3, Int((width - 40 + spacing) / (target + spacing)))
        coverWidth = min(target, (width - 40 - spacing * CGFloat(perRow - 1)) / CGFloat(perRow))
        rowHeight = Self.topGap + CoverAspect.height(forWidth: coverWidth) + Self.footing
    }
}

/// One Newsstand cubby with its topics standing on the plank.
private struct ShelfRow: View {
    let topics: [ShelfTopic]
    let layout: ShelfLayout
    /// Off while the shelf shows one status: every topic would wear the same sash.
    let ribbons: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<layout.perRow, id: \.self) { i in
                    Group {
                        if i < topics.count {
                            ShelfTopicView(item: topics[i], width: layout.coverWidth, ribbon: ribbons)
                        } else {
                            Color.clear.frame(width: layout.coverWidth, height: 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: CoverAspect.height(forWidth: layout.coverWidth), alignment: .bottom)
            .padding(.horizontal, 8)
            // Books stand on the plank's top surface, not in front of its edge.
            .padding(.bottom, ShelfLayout.footing)
        }
        .frame(height: layout.rowHeight)
        .background {
            // The cubby stretches between its fixed side walls, top shading and
            // plank; the shadow of the plank above falls across its back.
            Image.classic("ShelfRow", top: 10, leading: ShelfLayout.side, bottom: ShelfLayout.plank,
                          trailing: ShelfLayout.side)
                .overlay(alignment: .top) {
                    Image.classic("ShelfRowShadow", leading: ShelfLayout.side, trailing: ShelfLayout.side)
                        .frame(height: 46)
                }
        }
    }
}

/// A topic standing on the shelf: its cover, a corner ribbon for its status, a tap
/// to open it and a long press to move or remove it.
private struct ShelfTopicView: View {
    let item: ShelfTopic
    let width: CGFloat
    var ribbon = true

    @EnvironmentObject private var router: NavRouter
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        CoverImage(url: item.summary.coverURL, width: width, corner: 0)
            .overlay { if ribbon { sash } }
            .bookCover()
            .contentShape(Rectangle())
            .onTapGesture { router.push(item.summary) }
            .onLongPressGesture(minimumDuration: 0.5) { showActions() }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text("\(item.summary.title), \(item.status.title)"))
            .accessibilityAction { router.push(item.summary) }
            .accessibilityAction(named: "Status and Removal") { showActions() }
    }

    /// The iOS 6 way to offer choices on a long press: an action sheet with the
    /// other statuses and a red "Remove from Shelf".
    private func showActions() { ShelfActions.show(for: item.summary) }

    /// A diagonal corner sash for the statuses worth flagging at a glance.
    @ViewBuilder private var sash: some View {
        if let gloss = ribbonGloss {
            ZStack(alignment: .topTrailing) {
                Color.clear
                Text(item.status.title)
                    .font(.helvetica(8, weight: .bold))
                    .engraved()
                    .frame(width: 86)
                    .padding(.vertical, 2)
                    .background(gloss)
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                    .rotationEffect(.degrees(45))
                    .offset(x: 24, y: 14)
            }
            .clipped()
        }
    }

    private var ribbonGloss: LinearGradient? {
        func g(_ a: UInt32, _ b: UInt32) -> LinearGradient {
            LinearGradient(colors: [Palette.rgb(a), Palette.rgb(b)], startPoint: .top, endPoint: .bottom)
        }
        switch item.status {
        case .listening: return g(0x4F9BF3, 0x1D64CF)
        case .finished: return g(0x7CC35B, 0x3F8F25)
        case .onHold: return g(0x9A9A9A, 0x5E5E5E)
        case .want: return nil
        }
    }
}
