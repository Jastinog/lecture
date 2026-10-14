import SwiftUI

/// The lectures saved on this phone, under their topics A to Z: each one's
/// size, a ring while it comes in, a tap to play it, a swipe to delete it.
struct DownloadsView: View {
    @ObservedObject private var dl = DownloadManager.shared
    @ObservedObject private var live = DownloadManager.shared.live
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter
    @State private var query = ""

    var body: some View {
        let sections = self.sections
        List {
            if !dl.library.isEmpty {
                TableSearchBar(text: $query, prompt: String(localized: "Search Downloads"))
            }
            ForEach(sections, id: \.topic.id) { section in
                Section {
                    ForEach(section.lectures, id: \.lecture.id) { item in
                        DownloadedLectureRow(topic: section.topic, lecture: item.lecture, index: item.index,
                                             live: live) { play(item.index, of: section.topic) }
                            .classicSwipeButton(id: "\(section.topic.id)-\(item.lecture.id)") {
                                dl.deleteLecture(topicID: section.topic.id, lectureID: item.lecture.id)
                            }
                    }
                    .plainRow()
                } header: {
                    PlainSectionHeader(title: section.topic.title)
                }
            }
        }
        .classicSwipeList()
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .plainBackground()
        .overlay {
            if dl.library.isEmpty {
                ClassicEmptyState(String(localized: "No Downloads"), message: String(localized: "Lectures you download will appear here"))
            } else if sections.isEmpty {
                ClassicEmptyState.noResults
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ClassicToolbarItem(.trailing) {
                ConfirmingButton(confirm: String(localized: "Delete Finished Topics")) { dl.deleteFinished() } label: {
                    Text("Clean Up")
                }
                .buttonStyle(.classicBar)
                .disabled(dl.finishedTopics.isEmpty)
            }
            NowPlayingToolbarItem()
        }
        .libraryDestinations()
    }

    /// Each saved topic with its lectures on the phone or coming in, in the
    /// topic's order, narrowed by the search (a match on the topic or its
    /// lecturer keeps all of them).
    private var sections: [(topic: TopicDetail, lectures: [(index: Int, lecture: Lecture)])] {
        dl.library.compactMap { topic in
            let whole = searchMatches(query, topic.title, topic.lecturer)
            let lectures = topic.lectures.enumerated()
                .filter { dl.isDownloaded(topic.id, $0.element.id) || live.value(topic.id, $0.element.id) != nil }
                .filter { whole || searchMatches(query, $0.element.displayTitle(at: $0.offset)) }
                .map { (index: $0.offset, lecture: $0.element) }
            return lectures.isEmpty ? nil : (topic, lectures)
        }
    }

    /// Plays the lecture from its saved topic and opens the player.
    private func play(_ index: Int, of topic: TopicDetail) {
        if player.topic?.id == topic.id, player.currentIndex == index, player.isPlaying {
            router.openPlayer()
            return
        }
        player.load(topic: topic, summary: Topic(topic), index: index)
        router.openPlayer()
    }
}

/// A saved lecture as Music listed a track: its number in the topic (the blue
/// speaker on the one playing), the title, the size and length; while it
/// downloads, the ring to stop it.
private struct DownloadedLectureRow: View {
    let topic: TopicDetail
    let lecture: Lecture
    let index: Int
    @ObservedObject var live: DownloadProgress
    let onPlay: () -> Void

    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        HStack(spacing: 6) {
            RowButton(action: onPlay) {
                HStack(spacing: 10) {
                    LectureNumber(index: index, isCurrent: isCurrent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(lecture.displayTitle(at: index))
                            .font(.rowTitle)
                            .rowForeground(Palette.text)
                            .lineLimit(1)
                        Text(facts)
                            .font(.rowCaption)
                            .rowForeground(Palette.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    LanguageTag(code: lecture.language)
                    Text(formatTime(lecture.duration))
                        .font(.rowDetail)
                        .rowForeground(Palette.secondaryText)
                }
                .padding(.vertical, 5)
                .frame(minHeight: 44)
            }
            .accessibilityValue(isCurrent ? "Now playing" : "")

            if let progress = live.value(topic.id, lecture.id) {
                Button {
                    DownloadManager.shared.cancelLecture(topicID: topic.id, lectureID: lecture.id)
                } label: {
                    ZStack {
                        Image.classic("DownloadBase")
                        Image.classic("DownloadFill")
                            .mask { PieSlice(fraction: progress) }
                        Image.classic("DownloadStop")
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 29)
                .contentShape(Rectangle().inset(by: -8))
                .accessibilityLabel("Stop Download")
                .accessibilityValue("\(Int(progress * 100))%")
            }
        }
    }

    private var isCurrent: Bool { player.topic?.id == topic.id && player.currentLecture?.id == lecture.id }

    /// "34 MB · Bombay", or "Downloading…" while it comes in.
    private var facts: String {
        guard live.value(topic.id, lecture.id) == nil else { return String(localized: "Downloading…") }
        let file = DownloadPaths.lectureFile(topic.id, lecture.id)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
        return [size.map(formatBytes), lecture.event].compactMap { $0 }.joined(separator: " · ")
    }
}
