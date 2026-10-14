import SwiftUI

/// Formats seconds as `h:mm:ss` / `m:ss`.
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

/// Topic cover proportions (≈7:10 portrait, like a book standing on the shelf).
enum CoverAspect {
    static let ratio: CGFloat = 0.7   // width / height
    /// Portrait height for a given cover width.
    static func height(forWidth w: CGFloat) -> CGFloat { (w / ratio).rounded() }
}

extension Sequence where Element == URL {
    /// Fetches the first candidate that returns a 2xx body, in order; offline,
    /// whatever the URL cache kept from earlier.
    func firstAvailableData() async -> (url: URL, data: Data)? {
        for candidate in self {
            guard let (data, response) = try? await URLSession.shared.data(from: candidate)
            else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                continue
            }
            return (candidate, data)
        }
        for candidate in self {
            let request = URLRequest(url: candidate, cachePolicy: .returnCacheDataDontLoad)
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
               !data.isEmpty {
                return (candidate, data)
            }
        }
        return nil
    }
}

/// Topic cover. Covers are portrait by default to match the source site.
struct CoverImage: View {
    /// Contacts' empty photo, by theme.
    private static let photoTop = Palette.rgb(0xEDEDED, dark: 0x4A4A4A)
    private static let photoBottom = Palette.rgb(0xD5D5D5, dark: 0x383838)
    private static let bust = Palette.rgb(0xA9A9A9, dark: 0x6E6E6E)

    /// Ordered best → fallback. The first is the display/cache identity.
    private let urls: [URL]
    var width: CGFloat
    var height: CGFloat
    var corner: CGFloat = 8
    /// What stands in until the image loads, or when there is none.
    var placeholder: Placeholder = .topic

    enum Placeholder { case topic, person }

    /// Portrait cover sized from its width (≈7:10, like the site). Pass `hiRes` for
    /// large covers (the detail hero) to pull the full-resolution original with a
    /// graceful fallback; lists keep the lightweight embedded thumb.
    init(url: URL?, width: CGFloat, corner: CGFloat = 0, hiRes: Bool = false) {
        self.urls = url.map { [$0] } ?? []
        self.width = width
        self.height = CoverAspect.height(forWidth: width)
        self.corner = corner
        _image = State(initialValue: ImageCache.cached(urls.first))
    }

    /// Square cover (compact thumbnails such as the mini player). Pass `hiRes` for
    /// the large Now Playing artwork to pull the full-resolution original.
    init(url: URL?, size: CGFloat, corner: CGFloat = 8, hiRes: Bool = false,
         placeholder: Placeholder = .topic) {
        self.urls = url.map { [$0] } ?? []
        self.width = size
        self.height = size
        self.corner = corner
        self.placeholder = placeholder
        _image = State(initialValue: ImageCache.cached(urls.first))
    }

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if placeholder == .person {
                // Contacts' empty photo: a grey bust on a lighter grey.
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Self.photoTop, Self.photoBottom],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "person.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Self.bust)
                        .padding(.horizontal, width * 0.12)
                        .offset(y: width * 0.08)
                }
            } else {
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "headphones").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        // Fetch only when the URL changes. The cached image is read synchronously
        // in init (above), so a re-created view (e.g. the mini player rebuilding on a
        // lecture change) shows it immediately instead of flashing the placeholder.
        .task(id: urls.first) { await load() }
    }

    private func load() async {
        guard let primary = urls.first else { image = nil; return }
        if let cached = ImageCache.cached(primary) {
            if image !== cached { image = cached }
            return
        }
        if let loaded = await ImageCache.load(candidates: urls) { image = loaded }
    }
}

/// In-memory cache of decoded covers, shared across all `CoverImage` instances.
private enum ImageCache {
    /// Bounded by decoded bytes, not only by memory warnings: a long scroll
    /// through the catalog would otherwise keep every cover it passed.
    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 96 << 20
        return cache
    }()

    /// What a decoded bitmap weighs, for the cache's limit.
    private static func cost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }

    static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return shared.object(forKey: url as NSURL)
    }

    /// In-flight loads keyed by the primary URL, so concurrent requests for the same
    /// cover (e.g. the hero's stacked sharp + blurred copies) share one fetch+decode
    /// instead of each downloading the ~1 MB original. Main-actor isolated: every
    /// `CoverImage.load()` runs on the main actor, so plain dictionary access is safe.
    @MainActor private static var inFlight: [URL: Task<UIImage?, Never>] = [:]

    /// Loads the sharpest available cover from `candidates`, decoding and caching it
    /// under the primary key (and the candidate that actually served it).
    @MainActor static func load(candidates: [URL]) async -> UIImage? {
        guard let primary = candidates.first else { return nil }
        if let cached = cached(primary) { return cached }
        if let existing = inFlight[primary] { return await existing.value }

        let task = Task<UIImage?, Never> {
            guard let (hit, data) = await candidates.firstAvailableData(),
                  let loaded = await decode(data) else { return nil }
            shared.setObject(loaded, forKey: primary as NSURL, cost: cost(loaded))
            if hit != primary { shared.setObject(loaded, forKey: hit as NSURL, cost: cost(loaded)) }
            return loaded
        }
        inFlight[primary] = task
        let result = await task.value
        inFlight[primary] = nil
        return result
    }

    /// Decodes image data into a draw-ready bitmap off the main thread. `UIImage(data:)`
    /// alone defers JPEG decompression until the image is first drawn — which lands on
    /// the main thread exactly as a cell scrolls into view, hitching the scroll.
    /// `preparingForDisplay()` forces that decode now, on a background task, so the
    /// cached image is ready to composite with no main-thread work. Full-size
    /// originals (the player's and topic page's art) are decoded straight down to
    /// what the screen can show, not into a bitmap many times its size.
    nonisolated private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let image = UIImage(data: data) else { return nil }
            let longest = max(image.size.width, image.size.height) * image.scale
            if longest > maxPixels {
                let k = maxPixels / longest
                let size = CGSize(width: image.size.width * image.scale * k,
                                  height: image.size.height * image.scale * k)
                if let small = image.preparingThumbnail(of: size) { return small }
            }
            return image.preparingForDisplay() ?? image
        }.value
    }

    /// The largest cover drawn is the player's, about 320pt wide at 3×.
    nonisolated private static let maxPixels: CGFloat = 1200
}

/// Holds a tab's navigation path so a row with several independent tap targets
/// (e.g. `TopicRow`: cover/title → topic, author/reader/cycle → listings) can push
/// routes from plain `Button`s. Nested `NavigationLink`s can't coexist in one row
/// and each would draw its own `List` disclosure chevron.
@MainActor
final class NavRouter: ObservableObject {
    @Published var path = NavigationPath()
    func push<V: Hashable>(_ value: V) { path.append(value) }
    func pop() { if !path.isEmpty { path.removeLast() } }
    /// Slides the player in after a topic starts, as iOS 6 Music did when a song
    /// was picked.
    func openPlayer() {
        push(NowPlayingRoute())
    }
    func popToRoot() { path = NavigationPath() }
}

/// Per-tab navigation routers, held globally so a section's navigation path
/// outlives its stack being rebuilt (and the tab bar can pop a section to its
/// root). Hence singletons, not per-view state.
@MainActor
enum TabRouter {
    static let home = NavRouter()
    static let lecturers = NavRouter()
    static let downloads = NavRouter()
    static let history = NavRouter()
    static let settings = NavRouter()
}

/// A `NavigationStack` whose path is exposed to descendants through an injected
/// `NavRouter` (a per-tab singleton, see `TabRouter`) so navigation survives a
/// rebuild. Used for every tab so cards can drive navigation directly.
struct RoutedStack<Content: View>: View {
    @StateObject private var router: NavRouter
    private let content: () -> Content

    init(router: NavRouter, @ViewBuilder content: @escaping () -> Content) {
        _router = StateObject(wrappedValue: router)
        self.content = content
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            content().navigationBarTitleDisplayMode(.inline)
        }
        .environmentObject(router)
        .safeAreaInset(edge: .bottom, spacing: 0) { OfflineBanner() }
    }
}

extension View {
    /// Registers the shared topic/listing navigation destinations on a stack.
    func libraryDestinations() -> some View {
        LibraryDestinations { self }
    }
}

/// Route to the search screen.
struct SearchRoute: Hashable {}

/// Route to the Now Playing screen, pushed like any other page (iOS 6 Music).
struct NowPlayingRoute: Hashable {}

/// Registers the shared topic/listing destinations (and, on iOS, Now Playing and
/// the screens it pushes) and re-injects the tab's
/// `NavRouter` into each of them.
///
/// The router is provided by `RoutedStack` as a modifier on the `NavigationStack`
/// itself. As of iOS 26, an `environmentObject` attached that way reaches the
/// stack's *root* content but is *not* inherited by `navigationDestination` views —
/// so a pushed screen (a topic page, a people list, a reader profile) that reads
/// `@EnvironmentObject var router` would trap with "No ObservableObject of type
/// NavRouter found" the moment it touched the router (e.g. tapping a performer).
/// We read the router here (this modifier is applied to the root content, which
/// *does* have it) and hand it back down into every destination explicitly.
private struct LibraryDestinations<Content: View>: View {
    @ViewBuilder var content: Content
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        content
            .navigationDestination(for: NowPlayingRoute.self) { _ in
                NowPlayingView(onClose: router.pop).environmentObject(router).environmentObject(player)
            }
            .navigationDestination(for: PlayerRoute.self) { route in
                PlayerRouteView(route: route, done: router.pop, push: router.push)
                    .environmentObject(router)
                    .environmentObject(player)
            }
            .navigationDestination(for: Topic.self) { TopicView(topic: $0).environmentObject(router).classicBackButton() }
            .navigationDestination(for: TopicDetail.self) { TopicView(detail: $0).environmentObject(router).classicBackButton() }
            .navigationDestination(for: Lecturer.self) { LecturerView(lecturer: $0).environmentObject(router).classicBackButton() }
            .navigationDestination(for: LecturerRef.self) { LecturerView(ref: $0).environmentObject(router).classicBackButton() }
            .navigationDestination(for: Selection.self) { SelectionFolderView(selection: $0).environmentObject(router).classicBackButton() }
            .navigationDestination(for: TopicGroup.self) { CatalogView(group: $0).environmentObject(router).classicBackButton() }
            .navigationDestination(for: LecturersRoute.self) { _ in LecturersView().environmentObject(router).classicBackButton() }
            .navigationDestination(for: SearchRoute.self) { _ in SearchView().environmentObject(router).classicBackButton() }
            .navigationDestination(for: NewTopicsRoute.self) { _ in CatalogView().environmentObject(router).classicBackButton() }
            .navigationDestination(for: ListeningCalendarRoute.self) { _ in
                ListeningCalendarView().environmentObject(router).classicBackButton()
            }
            .navigationDestination(for: OptionPickerRoute.self) { OptionPickerView(route: $0).classicBackButton() }
    }
}

/// Thin strip shown while screens display saved data because the network is down.
struct OfflineBanner: View {
    @ObservedObject private var status = NetworkStatus.shared

    var body: some View {
        if status.showingSaved {
            Text("Offline — showing a saved copy")
                .font(.app(.caption, weight: .bold))
                .engraved()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background { Image.classic("BlackBar").resizable() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Shared list-row geometry so covers and text columns line up across screens.
enum RowMetrics {
    /// Every topic row's cover (catalog, search, history, downloads) and the
    /// "Continue" card's.
    static let coverWidth: CGFloat = 72
    /// A topic row with nothing taller than its cover: the pitch of the empty
    /// rows drawn under a list of topics.
    static var bookRowHeight: CGFloat { CoverAspect.height(forWidth: coverWidth) + 16 }
    /// Side margins of a plain-list row, which runs the full width (`plainRow`).
    static let margin: CGFloat = 10
    /// A track list's number column at the default text size; it grows with
    /// Dynamic Type (`LectureNumber`, `ZebraRowBackground`).
    static let trackNumberWidth: CGFloat = 34
    /// A person's photo in the author and performer lists.
    static let avatarSize: CGFloat = 50
    /// How far a reply steps in under the review it answers.
    static let replyIndent: CGFloat = 20
}

/// A topic row on the same grid as `TopicRow`: the cover, then title, author and
/// a detail line of the caller's (downloads, history entries without a page).
struct MediaRow<Detail: View>: View {
    let coverURL: URL?
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: coverURL, width: RowMetrics.coverWidth)
                .coverShadow()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.rowTitle)
                    .rowForeground(Palette.text)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.rowSubtitle)
                        .rowForeground(Palette.detailText)
                        .lineLimit(1)
                }
                detail()
                    .padding(.top, 3)
            }
            .padding(.top, 1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

/// A person's photo as iOS 6 Contacts framed it: square with 4pt corners, a
/// hairline edge and a soft shadow, or a grey bust when there is none.
struct PersonPhoto: View {
    let url: URL?
    var size: CGFloat = RowMetrics.avatarSize

    var body: some View {
        CoverImage(url: url, size: size, corner: 4, placeholder: .person)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
            }
            // Cast by a shape behind the photo, not by its pixels, so a scrolling
            // list doesn't render each photo's shadow offscreen.
            .background {
                RoundedRectangle(cornerRadius: 4).fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: size / 40, x: 0, y: size / 50)
            }
            .accessibilityHidden(true)
    }
}

/// The foot of a paged plain list, as the iOS 6 stores ended theirs: a spinner
/// while the next page loads, otherwise "Show More" bold in the middle of a
/// row of its own.
struct PagingFooter: View {
    let loading: Bool
    let canLoadMore: Bool
    let loadMore: () -> Void

    var body: some View {
        if loading {
            ClassicSpinner()
                .frame(maxWidth: .infinity, minHeight: 44)
        } else if canLoadMore {
            RowButton(action: loadMore) {
                Text("Show More")
                    .font(.groupedLabel)
                    .rowForeground(Palette.text)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }
}

/// Inline error state with a "Try Again" button, for list/section failures where
/// pull-to-refresh isn't discoverable (or isn't available at all).
struct ErrorRetryRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.classicWhite)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

/// A topic in a list (catalog, lecturer, search, shelf, history), as iTunes
/// listed an album: one target — the whole row turns blue and opens the topic,
/// a long press offers the shelf.
struct TopicRow: View {
    let topic: Topic

    @Environment(\.topicRowOmits) private var omits

    var body: some View {
        RowLink(value: topic) {
            HStack(alignment: .top, spacing: 12) {
                CoverImage(url: topic.coverURL, width: RowMetrics.coverWidth)
                    .coverShadow()
                    // The title is read out next to it.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(topic.title)
                        .font(.rowTitle)
                        .rowForeground(Palette.text)
                        .lineLimit(2)
                    if !omits.contains(.lecturer) {
                        Text(topic.lecturer.name)
                            .font(.rowSubtitle)
                            .rowForeground(Palette.detailText)
                            .lineLimit(1)
                    }
                    if let about = topic.about, about != topic.title {
                        Text(about)
                            .font(.rowDetail)
                            .rowForeground(Palette.secondaryText)
                            .lineLimit(1)
                    }
                    if factsLine != nil || !topic.languages.isEmpty {
                        HStack(spacing: 4) {
                            if let facts = factsLine {
                                Text(facts)
                                    .font(.rowCaption)
                                    .rowForeground(Palette.secondaryText)
                                    .lineLimit(1)
                            }
                            ForEach(topic.languages, id: \.self) { LanguageTag(code: $0) }
                        }
                        .padding(.top, 3)
                    }
                }
                .padding(.top, 1)
            }
            .padding(.vertical, 8)
        }
        .onLongPress { ShelfActions.show(for: topic) }
        .accessibilityAction(named: "Shelf") { ShelfActions.show(for: topic) }
    }

    /// Group, size and length on one grey line, as the store listed them.
    private var factsLine: String? {
        let parts = [omits.contains(.group) ? nil : topic.group?.name,
                     topic.lecturesCount > 0 ? String(localized: "\(topic.lecturesCount) lectures") : nil,
                     topic.duration > 0 ? formatDuration(topic.duration) : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A language as lists mark a lecture or topic with it: "EN" small and grey in
/// a thin frame, like the store's tags.
struct LanguageTag: View {
    let code: String

    var body: some View {
        Text(Language.tag(code))
            .font(.helvetica(9, weight: .bold))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 1) }
            .rowForeground(Palette.secondaryText)
            .fixedSize()
            .accessibilityLabel(Locale.current.localizedString(forLanguageCode: code) ?? code)
    }
}

/// "All | English | Русский": the segmented control every language choice
/// uses, nil standing for all of them.
struct LanguagePicker: View {
    let languages: [Language]
    @Binding var selection: String?

    var body: some View {
        ClassicSegmentedControl(
            options: [(nil, String(localized: "All"))] + languages.map { (Optional($0.code), $0.name) },
            selection: $selection, skin: .blue)
    }
}

/// The language picker for a lecturer's page or a mixed topic, as a list
/// section. The choice is remembered for the lecturer, so their page and
/// their topics follow it.
struct LanguageSwitcher: View {
    let languages: [Language]
    let lecturerID: Int
    let selection: String?

    var body: some View {
        Section {
            LanguagePicker(languages: languages, selection: Binding(
                get: { selection },
                set: { LanguageChoiceStore.shared.set($0, lecturerID: lecturerID) }))
                .padding(.bottom, 10)
                .listRowSeparator(.hidden)
                .plainRow()
        }
    }
}

/// The catalog's language picker, as Home, a group's list and search show it:
/// nothing while the catalog has a single language.
struct CatalogLanguagePicker: View {
    @ObservedObject private var store = CatalogLanguageStore.shared

    var body: some View {
        if store.items.count > 1 {
            LanguagePicker(languages: store.items,
                           selection: Binding(get: { store.language }, set: { store.choose($0) }))
        }
    }
}

/// What a list's topic rows leave unsaid because the list itself says it: the
/// lecturer on their own page, the group in a group's list.
struct TopicRowOmits: OptionSet {
    let rawValue: Int
    static let lecturer = Self(rawValue: 1 << 0)
    static let group = Self(rawValue: 1 << 1)
}

extension EnvironmentValues {
    @Entry var topicRowOmits: TopicRowOmits = []
}

extension View {
    /// Topic rows below leave out what the list already says.
    func topicRowsOmit(_ omits: TopicRowOmits) -> some View {
        environment(\.topicRowOmits, omits)
    }
}

/// Route to the choice screen behind `PickerRow`. Value-based
/// like every other push, so it lives in the tab's navigation path and never
/// knocks the stack out of sync. Identity is the title + current choices.
struct OptionPickerRoute: Hashable {
    /// One setting: its options, the current one, and how to apply a choice.
    struct Section {
        let title: String?
        let options: [String]
        let selected: Int
        let pick: (Int) -> Void

        init(title: String?, options: [String], selected: Int, pick: @escaping (Int) -> Void) {
            self.title = title
            self.options = options
            self.selected = selected
            self.pick = pick
        }
    }

    let title: String
    let sections: [Section]

    init(title: String, sections: [Section]) {
        self.title = title
        self.sections = sections
    }

    init(title: String, options: [String], selected: Int, pick: @escaping (Int) -> Void) {
        self.init(title: title, sections: [Section(title: nil, options: options, selected: selected, pick: pick)])
    }

    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.sections.map(\.options) == b.sections.map(\.options)
            && a.sections.map(\.selected) == b.sections.map(\.selected)
    }

    func hash(into h: inout Hasher) {
        h.combine(title)
        for section in sections { h.combine(section.options); h.combine(section.selected) }
    }
}

/// A settings-style row (title + current value + chevron) that opens a
/// single-choice screen — the screen-based replacement for a menu `Picker`.
struct PickerRow<Value: Equatable>: View {
    let title: String
    let options: [Value]
    let label: (Value) -> String
    let selection: Value
    let pick: (Value) -> Void

    var body: some View {
        RowLink(value: OptionPickerRoute(
            title: title,
            options: options.map(label),
            selected: options.firstIndex(of: selection) ?? 0,
            pick: { pick(options[$0]) })) {
            ValueRow(title: title, value: label(selection))
        }
    }
}

/// One row of a single-choice screen: the title and a checkmark on the current
/// choice; the whole row is the tap target.
struct CheckmarkRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        RowButton(action: action) {
            Content(title: title, isSelected: isSelected)
        }
    }

    /// Reads the row's highlight, which only exists inside the row's style.
    private struct Content: View {
        let title: String
        let isSelected: Bool
        @Environment(\.rowHighlighted) private var highlighted

        var body: some View {
            HStack {
                Text(title)
                    .font(.groupedLabel)
                    .rowForeground(isSelected ? Palette.accent : Palette.text)
                Spacer()
                if isSelected {
                    Image.classic(highlighted ? "CheckmarkSelected" : "Checkmark")
                }
            }
        }
    }
}

/// The choice screen behind `PickerRow`. With one setting, picking applies and
/// goes back; with several, each section keeps its own checkmark.
struct OptionPickerView: View {
    let route: OptionPickerRoute
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [Int]

    init(route: OptionPickerRoute) {
        self.route = route
        _selected = State(initialValue: route.sections.map(\.selected))
    }

    var body: some View {
        GroupedList {
            ForEach(route.sections.indices, id: \.self) { s in
                let section = route.sections[s]
                GroupedSection(section.title) {
                    ForEach(section.options.indices, id: \.self) { i in
                        CheckmarkRow(title: section.options[i], isSelected: i == selected[s]) {
                            section.pick(i)
                            selected[s] = i
                            if route.sections.count == 1 { dismiss() }
                        }
                    }
                }
            }
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
