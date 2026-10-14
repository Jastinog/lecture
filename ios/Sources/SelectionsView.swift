import SwiftUI

/// A selection in a list (the lecturer's page, a folder): a folder opens its
/// selections, a list of lectures opens as a topic.
struct SelectionRow: View {
    let selection: Selection

    var body: some View {
        if selection.holdsSelections {
            RowLink(value: selection) { label }
        } else {
            RowLink(value: selection.asTopic) { label }
        }
    }

    private var label: some View {
        MediaRow(coverURL: selection.coverURL, title: selection.title, subtitle: selection.about) {
            Text(facts)
                .font(.rowCaption)
                .rowForeground(Palette.secondaryText)
                .lineLimit(1)
        }
    }

    /// "17 selections · 692 lectures", or "143 lectures · 52 h 10 min".
    private var facts: String {
        let lectures = String(localized: "\(selection.lecturesCount) lectures")
        if selection.holdsSelections {
            return "\(String(localized: "\(selection.childrenCount) selections")) · \(lectures)"
        }
        return selection.duration > 0 ? "\(lectures) · \(formatDuration(selection.duration))" : lectures
    }
}

/// A folder selection's page: the selections in it, in the language the
/// lecturer's page is narrowed to.
struct SelectionFolderView: View {
    let selection: Selection

    @ObservedObject private var choices = LanguageChoiceStore.shared
    /// The selections in it as fetched per language ("" for all), so coming
    /// back from one doesn't fetch them again.
    @State private var childrenByLanguage: [String: [Selection]] = [:]
    @State private var loading = true
    @State private var failed = false

    private var language: String? {
        choices.language(lecturerID: selection.lecturer.id, among: selection.languages)
    }

    private var children: [Selection]? { childrenByLanguage[language ?? ""] }

    var body: some View {
        List {
            ForEach(children ?? []) { SelectionRow(selection: $0) }
                .plainRow()
        }
        .listStyle(.plain)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .overlay {
            if let children {
                if children.isEmpty {
                    ClassicEmptyState(String(localized: "Nothing Here"), message: String(localized: "No lectures in this language yet"))
                }
            } else if loading {
                ClassicSpinner()
            } else if failed {
                LoadFailedState { await load() }
            }
        }
        .classicNavigationTitle(selection.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NowPlayingToolbarItem() }
        .task(id: language) { await load() }
    }

    private func load() async {
        let key = language ?? ""
        guard childrenByLanguage[key] == nil else { return }
        loading = true
        failed = false
        do {
            childrenByLanguage[key] = try await API.library.selections(in: selection, language: language)
        } catch {
            if !error.isCancellation { failed = true }
        }
        loading = false
    }
}
