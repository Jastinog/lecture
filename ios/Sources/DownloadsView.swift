import SwiftUI

/// The lectures saved on this phone, their topics A to Z: each one's size, a
/// ring while it comes in, a tap to play it, a swipe to delete it.
struct DownloadsView: View {
    @ObservedObject private var dl = DownloadManager.shared
    @ObservedObject private var live = DownloadManager.shared.live
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter
    @StateObject private var starter = LectureStarter()
    @State private var query = ""

    var body: some View {
        let lectures = self.lectures
        List {
            if !dl.library.isEmpty {
                TableSearchBar(text: $query, prompt: String(localized: "Search Downloads"))
            }
            ForEach(lectures.indexed, id: \.element.id) { row, item in
                DownloadedLectureRow(topic: item.topic, lecture: item.lecture, index: item.index, live: live,
                                     isCurrent: player.isCurrent(topicID: item.topic.id, lectureID: item.lecture.id)) {
                    starter.play(item.id, topicID: item.topic.id, lectureID: item.lecture.id, player: player, router: router)
                }
                .classicSwipeButton(id: item.id) {
                    dl.deleteLecture(topicID: item.topic.id, lectureID: item.lecture.id)
                }
                .zebraRow(row)
            }
            .plainRow()
        }
        .classicSwipeList()
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .plainBackground()
        .overlay {
            if dl.library.isEmpty {
                ClassicEmptyState(String(localized: "No Downloads"), message: String(localized: "Lectures you download will appear here"))
            } else if lectures.isEmpty {
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

    /// The lectures on the phone or coming in, topic by topic in each one's
    /// order, narrowed by the search (a match on the topic or its lecturer
    /// keeps all of its lectures).
    private var lectures: [SavedLecture] {
        dl.library.flatMap { topic in
            let whole = searchMatches(query, topic.title, topic.lecturer)
            return topic.lectures.enumerated()
                .filter { dl.isDownloaded(topic.id, $0.element.id) || live.value(topic.id, $0.element.id) != nil }
                .filter { whole || searchMatches(query, $0.element.displayTitle(at: $0.offset)) }
                .map { SavedLecture(topic: topic, index: $0.offset, lecture: $0.element) }
        }
    }
}

private struct SavedLecture {
    let topic: TopicDetail
    let index: Int
    let lecture: Lecture
    var id: String { "\(topic.id)-\(lecture.id)" }
}

/// A saved lecture: its title, topic and lecturer, its size and length; while
/// it downloads, the ring to stop it.
private struct DownloadedLectureRow: View {
    let topic: TopicDetail
    let lecture: Lecture
    let index: Int
    @ObservedObject var live: DownloadProgress
    let isCurrent: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            RowButton(action: onPlay) {
                LectureLine(title: lecture.displayTitle(at: index), topic: topic.title, lecturer: topic.lecturer,
                            caption: caption, detail: formatTime(lecture.duration),
                            isCurrent: isCurrent)
            }
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
        .nestedRowBackground()
    }

    /// "34 MB · Bombay", or "Downloading…" while it comes in.
    private var caption: String {
        guard live.value(topic.id, lecture.id) == nil else { return String(localized: "Downloading…") }
        let file = DownloadPaths.lectureFile(topic.id, lecture.id)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
        return [size.map(formatBytes), lecture.event].compactMap { $0 }.joined(separator: " · ")
    }
}
