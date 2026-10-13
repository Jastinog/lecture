import SwiftUI

/// The topics saved on this phone, A to Z: how much of each is down, its size
/// on disk, a swipe to delete it.
struct DownloadsView: View {
    @ObservedObject private var dl = DownloadManager.shared
    @State private var query = ""

    var body: some View {
        let matching = dl.library.filter { searchMatches(query, $0.title, $0.lecturer) }
        List {
            if !dl.library.isEmpty {
                TableSearchBar(text: $query, prompt: "Search Downloads")
            }
            ForEach(matching) { topic in
                DownloadRow(topic: topic)
                    .classicSwipeButton(id: topic.id) { dl.deleteTopic(topic.id) }
            }
            .plainRow()
        }
        .classicSwipeList()
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .overlay {
            if dl.library.isEmpty {
                ClassicEmptyState("No Downloads", message: "Topics you download will appear here")
            } else if matching.isEmpty {
                ClassicEmptyState.noResults
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ClassicToolbarItem(.trailing) {
                ConfirmingButton(confirm: "Delete Finished Topics") { dl.deleteFinished() } label: {
                    Text("Clean Up")
                }
                .buttonStyle(.classicBar)
                .disabled(dl.finishedTopics.isEmpty)
            }
            NowPlayingToolbarItem()
        }
        .libraryDestinations()
    }
}

/// A saved topic: "12 of 20 lectures · 340 MB", with a bar filling while it
/// downloads.
private struct DownloadRow: View {
    let topic: TopicDetail
    @ObservedObject private var dl = DownloadManager.shared

    var body: some View {
        RowLink(value: topic) {
            MediaRow(coverURL: dl.coverURL(for: topic), title: topic.title, subtitle: topic.lecturer) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(detail)
                        .font(.rowDetail)
                        .rowForeground(Palette.secondaryText)
                        .lineLimit(1)
                    TopicProgressBar(topic: topic)
                }
            }
        }
    }

    private var detail: String {
        let total = formatCount(topic.lectures.count, "lecture", "lectures")
        let lectures = dl.isFullyDownloaded(topic) ? total : "\(dl.downloadedCount(topic.id)) of \(total)"
        guard let size = dl.topicSizes[topic.id], size > 0 else { return lectures }
        return "\(lectures) · \(formatBytes(size))"
    }
}

/// The topic's download bar, shown while any of its lectures is coming in. The
/// only view watching the 1% steps, so a download redraws just this bar.
private struct TopicProgressBar: View {
    let topic: TopicDetail
    @ObservedObject private var live = DownloadManager.shared.live

    var body: some View {
        if live.isDownloading(topic) {
            ClassicProgressBar(value: DownloadManager.shared.topicFraction(topic))
        }
    }
}
