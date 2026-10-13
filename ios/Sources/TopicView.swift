import SwiftUI

/// A topic's page, laid out as the iOS 6 App Store laid out an app: the head
/// on white, the buttons, then Lectures | Details switching what follows.
struct TopicView: View {
    private let id: Int
    private let initialDetail: TopicDetail?
    private let seed: Topic?

    init(topic: Topic) {
        id = topic.id
        initialDetail = nil
        seed = topic
        // Seed from the page cache so a reopened topic (or the view rebuild when
        // playback starts) shows instantly instead of flashing a spinner.
        let cached = TopicCache.shared.get(topic.id)
        _page = State(initialValue: cached)
        _loading = State(initialValue: cached == nil)
    }

    /// A downloaded topic, opened from Downloads: its lectures without the extras.
    init(detail: TopicDetail) {
        id = detail.id
        initialDetail = detail
        seed = nil
    }

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter
    @ObservedObject private var dl = DownloadManager.shared
    @ObservedObject private var choices = LanguageChoiceStore.shared
    @State private var page: TopicPage?
    @State private var loading = true
    @State private var failed = false
    @State private var tab = TopicTab.lectures

    var body: some View {
        Group {
            if loading {
                ClassicSpinner()
            } else if let page {
                content(page)
            } else if failed {
                LoadFailedState { await load() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cell)
        .classicNavigationTitle(page?.detail.title ?? seed?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NowPlayingToolbarItem() }
        .task(id: id) { await load() }
    }

    private func content(_ page: TopicPage) -> some View {
        let language = chosenLanguage(page)
        // What the page lists and plays: the lectures in the chosen language.
        let topic = page.detail.only(language: language)
        var shown = page
        shown.detail = topic
        return List {
            Section {
                TopicPageHead(page: shown, cover: dl.coverURL(for: topic), progress: progressLine(topic)) {
                    listenButton(topic, summary: page.summary)
                    // Downloads keep the whole topic, whatever the page shows.
                    TopicDownloadButton(topic: page.detail, dl: dl)
                    TopicShelfButton(topic: page.summary)
                }
                .listRowSeparator(.hidden)
                .plainRow()

                ClassicSegmentedControl(options: TopicTab.allCases.map { ($0, $0.rawValue) },
                                        selection: $tab, skin: .blue)
                    .padding(.bottom, 10)
                    .listRowSeparator(.hidden)
                    .plainRow()
            }

            switch tab {
            case .lectures:
                if page.detail.languages.count > 1 {
                    LanguageSwitcher(languages: switcherLanguages(page), lecturerID: lecturerID(page),
                                     selection: language)
                }
                lectures(topic, whole: page.detail, summary: page.summary, tagged: language == nil)
            case .details: details(page)
            }
        }
        .listStyle(.plain)
        .plainBackground()
        .environment(\.fieldLabelWidth, FieldRow.labelWidth(fitting: information(page).map(\.label) + ["lecturer"]))
    }

    /// The description, the facts as Contacts fields and more from the lecturer.
    @ViewBuilder
    private func details(_ page: TopicPage) -> some View {
        if let description = page.description, !description.isEmpty {
            Section {
                TopicDescription(text: description)
                    .padding(.vertical, 10)
                    .listRowSeparator(.hidden)
                    .plainRow()
            } header: {
                PlainSectionHeader(title: "Description")
            }
        }

        Section {
            Group {
                RowLink(value: page.lecturer ?? Lecturer(id: page.summary.lecturer.id, name: page.summary.lecturer.name)) {
                    FieldRow(label: "lecturer", value: page.summary.lecturer.name)
                }
                ForEach(information(page), id: \.label) { field in
                    FieldRow(label: field.label, value: field.value, lines: 6)
                }
            }
            .plainRow()
        } header: {
            PlainSectionHeader(title: "Information")
        }

        if !page.related.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: RowMetrics.margin) {
                        ForEach(page.related) { topic in
                            NavigationLink(value: topic) { RelatedCard(topic: topic) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, RowMetrics.margin)
                    .padding(.vertical, 10)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            } header: {
                PlainSectionHeader(title: "More from \(page.summary.lecturer.name)")
            }
        }
    }

    /// The facts the App Store kept under "Information", label and value.
    private func information(_ page: TopicPage) -> [(label: String, value: String)] {
        let topic = page.detail
        var fields: [(String, String?)] = []
        fields.append(("group", page.summary.group?.name))
        if !topic.lectures.isEmpty {
            fields.append(("lectures", formatNumber(topic.lectures.count)))
            fields.append(("length", formatDuration(topic.totalDuration)))
        }
        fields.append(("language", page.languages.isEmpty ? nil : page.languages.map(\.name).joined(separator: ", ")))
        fields.append(("years", page.years.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }))
        fields.append(("added", page.addedDate.map { $0.formatted(.dateTime.day().month(.abbreviated).year()) }))
        return fields.compactMap { label, value in value.map { (label, $0) } }
    }

    /// The language the page is narrowed to: the one last chosen for this
    /// lecturer, if the topic has it and more than one language; else all.
    private func chosenLanguage(_ page: TopicPage) -> String? {
        let languages = page.detail.languages
        guard languages.count > 1 else { return nil }
        return choices.language(lecturerID: lecturerID(page), among: languages)
    }

    private func lecturerID(_ page: TopicPage) -> Int {
        page.detail.lecturerID ?? page.summary.lecturer.id
    }

    /// The topic's languages for the switcher, named as the page names them;
    /// a downloaded copy has no names, so those show their tags.
    private func switcherLanguages(_ page: TopicPage) -> [Language] {
        page.detail.languages.map { code in
            page.languages.first { $0.code == code } ?? Language(code: code, name: Language.tag(code))
        }
    }

    /// Music's track list: every lecture, the one playing marked. `topic` is
    /// what's listed (maybe narrowed to one language), `whole` the topic as
    /// downloads keep it. `tagged` marks each lecture with its language.
    private func lectures(_ topic: TopicDetail, whole: TopicDetail, summary: Topic, tagged: Bool) -> some View {
        Section {
            let loaded = player.holds(topic)
            let saved = ProgressStore.entry(topicID: topic.id)
            // Where the listener is: the player's live lecture, else the saved one.
            let reached = loaded ? player.currentIndex : saved?.index(in: topic.lectures)
            ForEach(Array(topic.lectures.enumerated()), id: \.element.id) { index, lecture in
                LectureRow(
                    index: index, lecture: lecture,
                    isCurrent: isCurrent(topic, lecture),
                    listened: reached.map { index < $0 } ?? false,
                    played: index == reached
                        ? (loaded ? .live(player.clock)
                                  : .fixed(lecture.duration > 0 ? (saved?.time ?? 0) / lecture.duration : 0))
                        : nil,
                    language: tagged ? lecture.language : nil,
                    downloaded: dl.isDownloaded(topic.id, lecture.id),
                    live: dl.live,
                    onPlay: {
                        if isCurrent(topic, lecture) && loaded {
                            player.togglePlayPause()
                        } else {
                            player.load(topic: topic, summary: summary, index: index)
                            router.openPlayer()
                        }
                    },
                    onDownload: { dl.downloadLecture(topic: whole, lecture: lecture) }
                )
            }
            .plainRow()
        } header: {
            PlainSectionHeader(title: "Lectures — \(topic.lectures.count)")
        }
    }

    private func isCurrent(_ topic: TopicDetail, _ lecture: Lecture) -> Bool {
        player.topic?.id == topic.id && player.currentLecture?.id == lecture.id
    }

    /// Where the listener is, as a grey line in the head: "Lecture 5 · 12:30",
    /// "Lecture 5" while it's in the player, or "Finished". Numbered as the
    /// page lists them.
    private func progressLine(_ topic: TopicDetail) -> String? {
        if player.topic?.id == topic.id, let current = player.currentLecture,
           let index = topic.lectures.firstIndex(where: { $0.id == current.id }) {
            return "Lecture \(index + 1)"
        }
        if ProgressStore.isFinished(topicID: topic.id) { return "Finished" }
        guard let entry = ProgressStore.entry(topicID: topic.id), entry.index > 0 || entry.time > 1,
              let index = entry.index(in: topic.lectures) else { return nil }
        return "Lecture \(index + 1) · \(formatTime(entry.time))"
    }

    /// The main call to action, worded for where the listener is: "Listen",
    /// "Resume", "Pause" or "Start Over". Over lectures other than the ones
    /// playing, it loads these in their place, keeping the spot.
    private func listenButton(_ topic: TopicDetail, summary: Topic) -> some View {
        let loaded = player.holds(topic)
        let entry = ProgressStore.entry(topicID: topic.id)
        let finished = !loaded && ProgressStore.isFinished(topicID: topic.id)
        let started = entry.map { $0.index > 0 || $0.time > 1 } ?? false

        let title = loaded ? (player.isPlaying ? "Pause" : "Resume")
            : finished ? "Start Over" : started ? "Resume" : "Listen"

        return Button {
            if loaded {
                player.togglePlayPause()
            } else {
                if finished { ProgressStore.remove(topicID: topic.id) }
                player.load(topic: topic, summary: summary)
                router.openPlayer()
            }
        } label: {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .contentTransition(.identity)
        }
        .buttonStyle(.classicBlue)
        .disabled(topic.lectures.isEmpty)
    }

    private func load() async {
        if let initialDetail {
            page = TopicPage(detail: initialDetail, summary: Topic(initialDetail), lecturer: nil, description: nil)
            loading = false
            return
        }
        failed = false
        if let cached = TopicCache.shared.get(id) {
            page = cached; loading = false; return
        }
        if page == nil { loading = true }
        do {
            let fetched = try await TopicCache.shared.resolve(id)
            guard !Task.isCancelled else { return }
            page = fetched
        } catch {
            guard !Task.isCancelled else { return }
            if page == nil { failed = true }
        }
        loading = false
    }
}

extension Palette {
    /// A Contacts field's label ("lecturer", "length").
    static let fieldLabel = rgb(0x526691, dark: 0x93A6CF)
}

/// The page's head, after iTunes: the cover on the left; the title, lecturer
/// and the facts in grey on the right; the buttons on one line beneath.
private struct TopicPageHead<Buttons: View>: View {
    let page: TopicPage
    let cover: URL?
    let progress: String?
    @ViewBuilder var buttons: Buttons

    var body: some View {
        let topic = page.detail
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                CoverImage(url: cover, width: TopicPageMetrics.coverWidth, corner: 0, hiRes: true)
                    .bookCover()

                VStack(alignment: .leading, spacing: 3) {
                    Text(topic.title)
                        .font(.helvetica(18, weight: .bold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(topic.lecturer)
                        .font(.rowSubtitle)
                        .foregroundStyle(Palette.detailText)
                        .lineLimit(2)
                    if let group = page.summary.group?.name {
                        Text(group)
                            .font(.rowDetail)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(facts, id: \.self) { Text($0) }
                    }
                    .font(.rowCaption)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) { buttons }
        }
        .padding(.vertical, 12)
    }

    /// The size of the topic and where the listener is.
    private var facts: [String] {
        let topic = page.detail
        var lines: [String] = []
        if !topic.lectures.isEmpty {
            lines.append("\(formatCount(topic.lectures.count, "lecture", "lectures")) · \(formatTime(topic.totalDuration))")
        }
        if let progress { lines.append(progress) }
        return lines
    }
}

/// What the page shows under its head.
enum TopicTab: String, CaseIterable {
    case lectures = "Lectures", details = "Details"
}

enum TopicPageMetrics {
    static let coverWidth: CGFloat = 120
}

extension EnvironmentValues {
    /// The width of the field labels' column on a topic page.
    @Entry var fieldLabelWidth: CGFloat = 60
}

/// A Contacts-style field: the label small and bold in a right-aligned column
/// as wide as the longest label on the page, the value in bold beside it.
private struct FieldRow: View {
    let label: String
    let value: String
    var lines = 2
    @Environment(\.fieldLabelWidth) private var labelWidth

    private static let labelFont = UIFont(name: "HelveticaNeue-Bold", size: 13) ?? .boldSystemFont(ofSize: 13)

    /// A column just wide enough for the widest of `labels`, as Contacts sized
    /// its own, so short labels don't sit far out in white space.
    static func labelWidth(fitting labels: [String]) -> CGFloat {
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0
        return max(60, widest.rounded(.up))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.helvetica(13, weight: .bold))
                .rowForeground(Palette.fieldLabel)
                .frame(width: labelWidth, alignment: .trailing)
            Text(value)
                .font(.rowTitle)
                .rowForeground(Palette.text)
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
}

/// "Download" in the head; while the lectures come in, how many have, and once
/// all are here, "Downloaded". Stopping and deleting confirm in an action sheet.
private struct TopicDownloadButton: View {
    let topic: TopicDetail
    @ObservedObject var dl: DownloadManager
    /// Downloads starting/stopping show up here first; observing it keeps the
    /// title current.
    @ObservedObject private var live = DownloadManager.shared.live

    var body: some View {
        Group {
            if dl.isFullyDownloaded(topic) {
                Button("Downloaded") {
                    ActionSheets.shared.show("This topic is downloaded to your phone.",
                                             [.destructive("Delete Download") { dl.deleteTopic(topic.id) }])
                }
            } else if dl.isTopicDownloading(topic) {
                Button("\(dl.downloadedCount(topic.id)) of \(topic.lectures.count)") {
                    ActionSheets.shared.show(nil, [SheetAction(title: "Stop Download") { dl.cancelTopic(topic) }])
                }
            } else {
                Button("Download") { dl.downloadTopic(topic) }
            }
        }
        .lineLimit(1)
        .buttonStyle(.classicWhite)
        .disabled(topic.lectures.isEmpty)
    }
}

/// The topic's shelf status, or "Add to Shelf"; the statuses come up in an
/// action sheet, as on a topic row's long press.
private struct TopicShelfButton: View {
    let topic: Topic
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        Button(shelf.status(topic.id)?.shortTitle ?? "Add to Shelf") { ShelfActions.show(for: topic) }
            .lineLimit(1)
            .buttonStyle(.classicWhite)
    }
}

/// Another topic of the lecturer: the cover at the rows' size, the title under it.
private struct RelatedCard: View {
    let topic: Topic

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CoverImage(url: topic.coverURL, width: RowMetrics.coverWidth, corner: 0)
                .bookCover()
                .padding(.bottom, 4)
            Text(topic.title)
                .font(.helvetica(12, weight: .bold))
                .foregroundStyle(Palette.text)
                .lineLimit(2)
            if let group = topic.group?.name {
                Text(group).font(.rowCaption).foregroundStyle(Palette.secondaryText).lineLimit(1)
            }
        }
        .frame(width: RowMetrics.coverWidth, alignment: .leading)
    }
}

/// The description, cut to six lines with "More" under it, as the App Store
/// cut an app's; "More" opens the rest in place.
struct TopicDescription: View {
    let text: String
    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.helvetica(15))
                .foregroundStyle(Palette.bodyText)
                .lineSpacing(2)
                .lineLimit(expanded ? nil : 6)
                // Measure the full text against the cut one to know whether
                // "More" has anything to open.
                .background {
                    Text(text)
                        .font(.helvetica(15))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full in
                            truncated = full > 6 * 21
                        }
                }
            if truncated && !expanded {
                Button("More") { withAnimation(.easeOut(duration: 0.25)) { expanded = true } }
                    .font(.helvetica(15, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.plain)
            }
        }
    }
}

/// How far into a lecture the listener is.
enum LecturePlayed {
    case live(PlaybackClock)
    case fixed(Double)
}

/// A lecture as Music listed a track: the number (the blue speaker on the one
/// that's playing), the title, the length, and the cloud while it isn't on the
/// phone. The row plays the lecture.
private struct LectureRow: View {
    static let numberWidth: CGFloat = 26

    let index: Int
    let lecture: Lecture
    let isCurrent: Bool
    /// The listener is past this lecture.
    let listened: Bool
    /// Progress within this lecture, when it's where the listener is.
    let played: LecturePlayed?
    /// The lecture's language code, on a page listing more than one.
    let language: String?
    let downloaded: Bool
    /// Observed only by the download indicator, so progress ticks redraw it alone.
    let live: DownloadProgress
    let onPlay: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            RowButton(action: onPlay) {
                HStack(spacing: 10) {
                    Group {
                        if isCurrent {
                            Image.classic("SpeakerIconBlack")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 13)
                                .rowForeground(Palette.selection)
                        } else {
                            Text("\(index + 1)")
                                .font(.rowDetail)
                                .rowForeground(Palette.secondaryText)
                        }
                    }
                    .frame(width: Self.numberWidth, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(lecture.displayTitle(at: index))
                            .font(.rowTitle)
                            .rowForeground(listened ? Palette.secondaryText : Palette.text)
                            .lineLimit(1)
                        if let event = lecture.event {
                            Text(event)
                                .font(.rowCaption)
                                .rowForeground(Palette.secondaryText)
                                .lineLimit(1)
                        }
                        if let played {
                            LecturePlayedBar(played: played)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let language {
                        LanguageTag(code: language)
                    }
                    Text(formatTime(lecture.duration))
                        .font(.rowDetail)
                        .rowForeground(Palette.secondaryText)
                }
                .padding(.vertical, 5)
                .frame(minHeight: 44)
            }

            LectureDownloadIndicator(lectureID: lecture.id, downloaded: downloaded, live: live,
                                     onDownload: onDownload)
        }
    }
}

/// Music's iCloud control: the cloud to fetch a lecture, the ring filling blue
/// while it comes in, nothing once it's on the phone.
private struct LectureDownloadIndicator: View {
    let lectureID: Int
    let downloaded: Bool
    @ObservedObject var live: DownloadProgress
    let onDownload: () -> Void

    var body: some View {
        Group {
            if downloaded {
                Color.clear
            } else if let progress = live.values[lectureID] {
                ZStack {
                    Image.classic("DownloadBase")
                    Image.classic("DownloadFill")
                        .mask { PieSlice(fraction: progress) }
                    Image.classic("DownloadStop")
                }
                .accessibilityLabel("Downloading")
            } else {
                Button(action: onDownload) { Image.classic("CloudDownload") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Download Lecture")
            }
        }
        .frame(width: 34, height: 29)
    }
}

/// The part of a circle swept clockwise from twelve o'clock.
private struct PieSlice: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: max(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(max(fraction, 0), 1)),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Thin progress line under the lecture the listener is in. The live variant
/// observes only the clock, so the tick doesn't rebuild the whole topic page.
private struct LecturePlayedBar: View {
    let played: LecturePlayed

    var body: some View {
        switch played {
        case .live(let clock): LiveBar(clock: clock)
        case .fixed(let fraction): Bar(fraction: fraction)
        }
    }

    private struct LiveBar: View {
        @ObservedObject var clock: PlaybackClock
        var body: some View {
            Bar(fraction: clock.fraction)
        }
    }

    private struct Bar: View {
        let fraction: Double
        var body: some View {
            ClassicProgressBar(value: fraction, height: 7)
                .frame(maxWidth: 180)
        }
    }
}
