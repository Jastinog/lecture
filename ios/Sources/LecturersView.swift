import SwiftUI

/// Loading state shared by the lists, and the one place stale results are
/// dropped: a reset supersedes whatever is in flight, and its results are
/// ignored when they land.
@MainActor
class PagedLoader: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published var error: String?

    /// Bumped by every reset; a fetch whose generation is stale is ignored.
    private var generation = 0

    /// Runs `fetch` and hands its outcome to `apply`, unless a reset has
    /// superseded it meanwhile.
    func load<Page>(reset: Bool, _ fetch: () async throws -> Page,
                    apply: (Result<Page, Error>) -> Void) async {
        if reset { generation += 1 }
        let gen = generation
        error = nil
        if reset { loading = true; loadingMore = false } else { loadingMore = true }
        let result: Result<Page, Error>
        do { result = .success(try await fetch()) } catch { result = .failure(error) }
        guard gen == generation else { return }
        // Left before it came back (the view went away): not an error to show.
        if case .failure(let error) = result, error.isCancellation {
            loading = false; loadingMore = false
            return
        }
        apply(result)
        loading = false; loadingMore = false
    }
}

/// Route to the lecturers directory.
struct LecturersRoute: Hashable {}

@MainActor
final class LecturersViewModel: PagedLoader {
    @Published private(set) var items: [Lecturer] = []
    /// The catalog language the list was loaded in.
    private(set) var language: String?

    func reload() { Task { await refresh() } }

    /// Awaitable reload for pull-to-refresh.
    func refresh() async {
        let language = CatalogLanguageStore.shared.language
        self.language = language
        await load(reset: true, { try await API.library.lecturers(language: language) }) { result in
            switch result {
            case .success(let lecturers): items = lecturers
            case .failure: error = String(localized: "Couldn’t load the lecturers")
            }
        }
    }
}

/// Every lecturer, one section per level of the line, pinned ones on top;
/// narrowed to the catalog language when one is chosen (pins stay).
struct LecturersView: View {
    @StateObject private var vm = LecturersViewModel()
    @ObservedObject private var pins = PinStore.shared
    @ObservedObject private var languages = CatalogLanguageStore.shared

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

            if !pins.items.isEmpty {
                Section {
                    ForEach(pins.items) { pin in
                        RowLink(value: pin.ref) { PersonRow(name: pin.name, photo: pin.photoURL) }
                            .classicSwipeButton(String(localized: "Unpin"), id: "pin\(pin.id)", tint: .blue) {
                                pins.unpin(id: pin.id)
                            }
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: String(localized: "Pinned"))
                }
            }

            if vm.loading && vm.items.isEmpty {
                HStack { Spacer(); ClassicSpinner(); Spacer() }.plainRow()
            } else if let error = vm.error, vm.items.isEmpty {
                ErrorRetryRow(message: error) { vm.reload() }.plainRow()
            }

            ForEach(LecturerLevel.allCases) { level in
                let lecturers = vm.items.filter { $0.level == level }
                if !lecturers.isEmpty {
                    Section {
                        ForEach(lecturers) { lecturer in
                            RowLink(value: lecturer) { LecturerRow(lecturer: lecturer) }
                                .classicSwipeButton(pins.isPinned(lecturer.id) ? String(localized: "Unpin") : String(localized: "Pin"),
                                                    id: lecturer.id, tint: .blue) {
                                    pins.toggle(lecturer)
                                }
                        }
                        .plainRow()
                    } header: {
                        PlainSectionHeader(title: level.sectionTitle)
                    }
                }
            }
        }
        // Pinning must not animate the list reflow.
        .animation(nil, value: pins.items)
        .classicSwipeList()
        .listStyle(.plain)
        .plainBackground()
        .navigationTitle("Lecturers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NowPlayingToolbarItem() }
        .classicRefreshable { await vm.refresh() }
        // Loads at first, and again whenever the catalog language changes.
        .task(id: languages.language) {
            if vm.items.isEmpty || vm.language != languages.language { await vm.refresh() }
        }
    }
}

/// A person in a list: the photo, then the name in bold and an optional grey
/// line of facts.
struct PersonRow: View {
    let name: String
    let photo: URL?
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            PersonPhoto(url: photo)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.rowTitle)
                    .rowForeground(Palette.text)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.rowDetail)
                        .rowForeground(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A lecturer with "12 topics · 290 lectures" under the name.
struct LecturerRow: View {
    let lecturer: Lecturer

    var body: some View {
        PersonRow(name: lecturer.name, photo: lecturer.photoURL, detail: lecturer.facts)
    }
}

extension Lecturer {
    /// "12 topics · 290 lectures", grey text with no badges, as iOS 6 put facts.
    var facts: String? {
        let parts = [topicsCount > 0 ? String(localized: "\(topicsCount) topics") : nil,
                     lecturesCount > 0 ? String(localized: "\(lecturesCount) lectures") : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Lecturer page

/// A lecturer's page: a Contacts card on the pinstripe (photo, name, level,
/// counts, pin), the biography, the languages to choose from when there are
/// several, then their topics under one band per group.
struct LecturerView: View {
    private let id: Int
    @State private var lecturer: Lecturer?
    /// Every language the lecturer has lectures in, with how many.
    @State private var languages: [Language] = []
    /// The topics as fetched per language ("" for all), so switching back is instant.
    @State private var topicsByLanguage: [String: [Topic]] = [:]
    /// The lecturer's top-level selections, per language like the topics.
    @State private var selectionsByLanguage: [String: [Selection]] = [:]
    @State private var loading = true
    @State private var failed = false
    @ObservedObject private var choices = LanguageChoiceStore.shared
    private let fallbackName: String

    init(lecturer: Lecturer) {
        id = lecturer.id
        fallbackName = lecturer.name
        _lecturer = State(initialValue: lecturer)
    }

    init(ref: LecturerRef) {
        id = ref.id
        fallbackName = ref.name
    }

    /// The language the page is narrowed to: the one last chosen here, unless
    /// the lecturer turns out not to have it.
    private var language: String? { choices.language(lecturerID: id, among: languages.map(\.code)) }

    /// The topics in the chosen language. Until they come, the topics already
    /// here that have it, so a switch shows at once.
    private var topics: [Topic] {
        if let fetched = topicsByLanguage[language ?? ""] { return fetched }
        guard let language else { return [] }
        return (topicsByLanguage[""] ?? []).filter { $0.languages.contains(language) }
    }

    /// The lecturer with the counts of the chosen language.
    private var shownLecturer: Lecturer? {
        guard var shown = lecturer, let language else { return lecturer }
        shown.lecturesCount = languages.first { $0.code == language }?.lecturesCount ?? shown.lecturesCount
        if topicsByLanguage[language] != nil { shown.topicsCount = topics.count }
        return shown
    }

    /// The lecturer's topics by group, in the catalog's group order.
    private var sections: [(group: String, topics: [Topic])] {
        let other = String(localized: "Other", comment: "Topics outside any group")
        let byGroup = Dictionary(grouping: topics) { $0.group?.name ?? other }
        let known = GroupStore.shared.items.map(\.name)
        // Groups not (yet) known locally keep the order the topics came in.
        var unknown: [String] = []
        for topic in topics {
            let name = topic.group?.name ?? other
            if !known.contains(name), !unknown.contains(name) { unknown.append(name) }
        }
        let order = known + unknown.filter { $0 != other } + [other]
        return order.compactMap { name in byGroup[name].map { (name, $0) } }
    }

    var body: some View {
        List {
            Section {
                LecturerHeader(lecturer: shownLecturer, fallbackName: fallbackName)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(PinstripeBackground())
            }

            if let bio = lecturer?.bio, !bio.isEmpty {
                Section {
                    TopicDescription(text: bio)
                        .padding(.vertical, 10)
                        .listRowSeparator(.hidden)
                        .plainRow()
                } header: {
                    PlainSectionHeader(title: String(localized: "Biography"))
                }
            }

            if languages.count > 1 {
                LanguageSwitcher(languages: languages, lecturerID: id, selection: language)
            }

            if loading && topics.isEmpty {
                HStack { Spacer(); ClassicSpinner(); Spacer() }.plainRow()
            } else if failed && topics.isEmpty {
                ErrorRetryRow(message: String(localized: "Couldn’t load the topics")) {
                    Task { await loadTopics(language) }
                }.plainRow()
            }

            if let selections = selectionsByLanguage[language ?? ""], !selections.isEmpty {
                Section {
                    ForEach(selections) { SelectionRow(selection: $0) }
                        .plainRow()
                } header: {
                    PlainSectionHeader(title: String(localized: "Selections"))
                }
            }

            ForEach(sections, id: \.group) { section in
                Section {
                    ForEach(section.topics) { TopicRow(topic: $0) }
                        .plainRow()
                } header: {
                    PlainSectionHeader(title: section.group)
                }
            }
        }
        .listStyle(.plain)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .topicRowsOmit(.lecturer)
        .classicNavigationTitle(lecturer?.name ?? fallbackName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NowPlayingToolbarItem() }
        .task { await loadLecturer() }
        .task(id: language) { await loadTopics(language) }
        .task(id: language) { await loadSelections(language) }
    }

    /// Fetches the selections in `language` (all for nil), once per language.
    /// Without them the page is still whole, so a failure just leaves them out.
    private func loadSelections(_ language: String?) async {
        let key = language ?? ""
        guard selectionsByLanguage[key] == nil else { return }
        let ref = LecturerRef(id: id, name: lecturer?.name ?? fallbackName)
        if let selections = try? await API.library.selections(lecturer: ref, language: language) {
            selectionsByLanguage[key] = selections
        }
    }

    private func loadLecturer() async {
        guard let page = try? await API.library.lecturer(id: id) else { return }
        lecturer = page.lecturer
        languages = page.languages
    }

    /// Fetches the topics in `language` (all for nil), once per language.
    private func loadTopics(_ language: String?) async {
        let key = language ?? ""
        guard topicsByLanguage[key] == nil else { return }
        loading = true
        failed = false
        do {
            topicsByLanguage[key] = try await API.library.topics(lecturerID: id, language: language)
        } catch {
            if !error.isCancellation { failed = true }
        }
        // A switch to another language cancelled this run, and the new one is loading.
        if !Task.isCancelled { loading = false }
    }
}

/// The page's head as an iOS 6 Contacts card on the pinstripe: the framed
/// photo with the name beside it, the counts in a grouped panel, and the pin
/// as a full-width white button.
private struct LecturerHeader: View {
    let lecturer: Lecturer?
    let fallbackName: String

    @ObservedObject private var pins = PinStore.shared

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                PersonPhoto(url: lecturer?.photoURL, size: 80)
                VStack(alignment: .leading, spacing: 3) {
                    Text(lecturer?.name ?? fallbackName)
                        .font(.app(.title3, weight: .bold))
                        .embossed(Palette.embossedStrong)
                        .lineLimit(3)
                    if let level = lecturer?.level {
                        Text(level.title).font(.rowSubtitle).embossed()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let lecturer {
                HStack(spacing: 0) {
                    stat(String(localized: "\(lecturer.topicsCount)\ntopics"))
                    Rectangle().fill(Palette.groupedBorder).frame(width: 1)
                    stat(String(localized: "\(lecturer.lecturesCount)\nlectures"))
                }
                .frame(height: 54)
                .groupedPanel()

                Button { pins.toggle(lecturer) } label: {
                    Text(pins.isPinned(lecturer.id) ? "Unpin" : "Pin to Lecturers")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.classicWhite)
            }
        }
        .padding(.horizontal, GroupedMetrics.margin)
        .padding(.vertical, 14)
        .background(PinstripeBackground())
    }

    /// One even column: the count in bold over its name in grey.
    /// "12\ntopics": the number over its noun, which agrees with it — one
    /// string, so the translation can decline the noun.
    private func stat(_ text: String) -> some View {
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        return VStack(spacing: 2) {
            Text(lines.first ?? "").font(.groupedLabel).foregroundStyle(Palette.text)
            Text(lines.dropFirst().first ?? "").font(.rowCaption).foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
