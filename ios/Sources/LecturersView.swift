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
        apply(result)
        loading = false; loadingMore = false
    }
}

/// Route to the lecturers directory.
struct LecturersRoute: Hashable {}

@MainActor
final class LecturersViewModel: PagedLoader {
    @Published private(set) var items: [Lecturer] = []

    func reload() { Task { await refresh() } }

    /// Awaitable reload for pull-to-refresh.
    func refresh() async {
        await load(reset: true, { try await API.library.lecturers() }) { result in
            switch result {
            case .success(let lecturers): items = lecturers
            case .failure: error = "Couldn’t load the lecturers"
            }
        }
    }
}

/// Every lecturer, one section per level of the line, pinned ones on top.
struct LecturersView: View {
    @StateObject private var vm = LecturersViewModel()
    @ObservedObject private var pins = PinStore.shared

    var body: some View {
        List {
            if !pins.items.isEmpty {
                Section {
                    ForEach(pins.items) { pin in
                        RowLink(value: pin.ref) { PersonRow(name: pin.name, photo: pin.photoURL) }
                            .classicSwipeButton("Unpin", id: "pin\(pin.id)", tint: .blue) {
                                pins.unpin(id: pin.id)
                            }
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: "Pinned")
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
                                .classicSwipeButton(pins.isPinned(lecturer.id) ? "Unpin" : "Pin",
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
        .task { if vm.items.isEmpty { vm.reload() } }
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
        let parts = [topicsCount > 0 ? formatCount(topicsCount, "topic", "topics") : nil,
                     lecturesCount > 0 ? formatCount(lecturesCount, "lecture", "lectures") : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Lecturer page

/// A lecturer's page: a Contacts card on the pinstripe (photo, name, level,
/// counts, pin), the biography, then their topics under one band per group.
struct LecturerView: View {
    private let id: Int
    @State private var lecturer: Lecturer?
    @State private var topics: [Topic] = []
    @State private var loading = true
    @State private var failed = false
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

    /// The lecturer's topics by group, in the catalog's group order.
    private var sections: [(group: String, topics: [Topic])] {
        let byGroup = Dictionary(grouping: topics) { $0.group?.name ?? "Other" }
        let order = API.library.groups.map(\.name) + ["Other"]
        return order.compactMap { name in byGroup[name].map { (name, $0) } }
    }

    var body: some View {
        List {
            Section {
                LecturerHeader(lecturer: lecturer, fallbackName: fallbackName)
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
                    PlainSectionHeader(title: "Biography")
                }
            }

            if loading && topics.isEmpty {
                HStack { Spacer(); ClassicSpinner(); Spacer() }.plainRow()
            } else if failed && topics.isEmpty {
                ErrorRetryRow(message: "Couldn’t load the topics") { Task { await load() } }.plainRow()
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
        .task { if topics.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        failed = false
        async let person = try? API.library.lecturer(id: id)
        do {
            topics = try await API.library.topics(lecturerID: id)
        } catch {
            failed = true
        }
        if let fetched = await person { lecturer = fetched }
        loading = false
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
                        .font(.helvetica(20, weight: .bold))
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
                    stat(lecturer.topicsCount, "topics")
                    Rectangle().fill(Palette.groupedBorder).frame(width: 1)
                    stat(lecturer.lecturesCount, "lectures")
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
    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(formatNumber(value)).font(.groupedLabel).foregroundStyle(Palette.text)
            Text(label).font(.rowCaption).foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
