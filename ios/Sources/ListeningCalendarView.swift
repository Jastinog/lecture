import SwiftUI

/// Route to the listening calendar.
struct ListeningCalendarRoute: Hashable {}

/// The listening calendar, as iOS 6's Calendar: the toolbar at the foot with
/// Today and the List | Day | Month segments, and the chosen view above it.
/// Month dots the days listened on and lists the chosen day's lectures; Day
/// lays them on the hours, when they were heard; List runs through every day.
struct ListeningCalendarView: View {
    enum Mode: String, CaseIterable { case list, day, month }

    @ObservedObject private var log = ListeningLog.shared
    @AppStorage("listeningCalendarMode") private var mode: Mode = .month
    /// The first day of the month shown.
    @State private var month = CalendarMonth.start(of: Date())
    @State private var selected = Calendar.current.startOfDay(for: Date())

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .month: monthView
            case .day: dayView
            case .list: listView
            }
            toolbar
        }
        .classicNavigationTitle(String(localized: "Listening Calendar"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NowPlayingToolbarItem() }
    }

    // MARK: - Month

    private var monthView: some View {
        VStack(spacing: 0) {
            CalendarMonthGrid(month: month, selected: selected, listened: log.listened(on:),
                              step: stepMonth, pick: pick)
                .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    stepMonth(value.translation.width < 0 ? 1 : -1)
                })
            List {
                Section {
                    let entries = log.entries(on: selected)
                    if entries.isEmpty {
                        Text("Nothing listened to on this day")
                            .font(.rowSubtitle)
                            .foregroundStyle(Palette.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .listRowSeparator(.hidden)
                            .plainRow()
                    } else {
                        ForEach(entries) { ListeningEntryRow(entry: $0) }
                            .plainRow()
                    }
                } header: {
                    PlainSectionHeader(title: dayTitle(selected))
                } footer: {
                    Text(monthSummary)
                        .font(.rowCaption)
                        .foregroundStyle(Palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .listStyle(.plain)
            .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        }
    }

    private func stepMonth(_ months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: month),
              next <= CalendarMonth.start(of: Date()) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { month = next }
    }

    private func pick(_ day: Date) {
        selected = day
        let start = CalendarMonth.start(of: day)
        if start != month { withAnimation(.easeInOut(duration: 0.25)) { month = start } }
    }

    /// "12 days · 14 h 30 min" for the month shown, and the streak while it's
    /// this month.
    private var monthSummary: String {
        let listened = CalendarMonth.days(in: month).filter(log.listened(on:))
        guard !listened.isEmpty else { return String(localized: "No listening this month") }
        let total = listened.reduce(0) { $0 + log.seconds(on: $1) }
        var parts = [String(localized: "\(listened.count) days"), formatDuration(total)]
        let streak = log.streak()
        if month == CalendarMonth.start(of: Date()), streak > 1 {
            parts.append(String(localized: "\(streak) days in a row"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Day

    private var dayView: some View {
        let isToday = Calendar.current.isDateInToday(selected)
        return VStack(spacing: 0) {
            CalendarBanner(canStepForward: !isToday, step: stepDay) {
                VStack(spacing: 0) {
                    Text(isToday ? String(localized: "Today") + ", " + selected.formatted(.dateTime.day().month(.wide))
                                 : selected.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.helvetica(17, weight: .bold))
                    let seconds = log.seconds(on: selected)
                    if seconds >= 60 {
                        Text(formatDuration(seconds)).font(.helvetica(12, weight: .bold))
                    }
                }
                .bannerInk()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            ListeningDayGrid(day: selected, entries: log.entries(on: selected))
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
            stepDay(value.translation.width < 0 ? 1 : -1)
        })
    }

    private func stepDay(_ days: Int) {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .day, value: days, to: selected),
              next <= calendar.startOfDay(for: Date()) else { return }
        selected = next
        month = CalendarMonth.start(of: next)
    }

    // MARK: - List

    private var listView: some View {
        let days = log.days.keys.sorted(by: >).compactMap { key in
            Self.dayKey.date(from: key).map { (key: key, date: $0) }
        }.filter { log.listened(on: $0.date) }
        return List {
            ForEach(days, id: \.key) { day in
                Section {
                    ForEach(log.entries(on: day.date)) { ListeningEntryRow(entry: $0) }
                        .plainRow()
                } header: {
                    PlainSectionHeader(title: dayTitle(day.date))
                }
            }
        }
        .listStyle(.plain)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .overlay {
            if days.isEmpty {
                ClassicEmptyState(String(localized: "No Listening Yet"),
                                  message: String(localized: "The lectures you listen to show up here, day by day"))
            }
        }
    }

    /// The log's "2026-10-15" keys, in the phone's calendar.
    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "Thursday, 15 October · 1 h 20 min".
    private func dayTitle(_ day: Date) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let seconds = log.seconds(on: day)
        return seconds >= 60 ? "\(date) · \(formatDuration(seconds))" : date
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        ClassicToolbar {
            today
            Spacer(minLength: 8)
            BarSegmented(options: [(Mode.list, String(localized: "List")), (.day, String(localized: "Day")),
                                   (.month, String(localized: "Month"))],
                         selection: mode) { mode = $0 }
                .frame(width: 210)
            Spacer(minLength: 8)
            // Balances Today, as Calendar's Inbox did on the right.
            today.hidden()
        }
    }

    private var today: some View {
        Button(String(localized: "Today")) {
            let today = Calendar.current.startOfDay(for: Date())
            selected = today
            withAnimation(.easeInOut(duration: 0.25)) { month = CalendarMonth.start(of: today) }
        }
        .buttonStyle(.classicBar)
    }
}

/// A lecture heard on a day; opens its topic.
private struct ListeningEntryRow: View {
    let entry: ListeningEntry

    var body: some View {
        RowLink(value: entry.topic) {
            MediaRow(coverURL: entry.topic.coverURL, title: entry.lectureTitle, subtitle: entry.topic.title) {
                Text(facts)
                    .font(.rowCaption)
                    .rowForeground(Palette.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    /// "34 min · 21:05": how long, and when it was last heard.
    private var facts: String {
        let time = Date(timeIntervalSince1970: entry.lastHeard).formatted(date: .omitted, time: .shortened)
        return "\(formatDuration(entry.seconds)) · \(time)"
    }
}

// MARK: - Months

/// Months and their days in the phone's calendar.
enum CalendarMonth {
    static func start(of date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? Calendar.current.startOfDay(for: date)
    }

    static func days(in month: Date) -> [Date] {
        let calendar = Calendar.current
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
    }

    /// The month's grid: whole weeks, from the week its first day is in to
    /// the week of its last.
    static func grid(for month: Date) -> [Date] {
        let calendar = Calendar.current
        let days = days(in: month)
        guard let first = days.first, let last = days.last,
              let start = calendar.dateInterval(of: .weekOfYear, for: first)?.start,
              let end = calendar.dateInterval(of: .weekOfYear, for: last)?.end else { return days }
        var grid: [Date] = [], day = start
        while day < end {
            grid.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return grid
    }

    /// The weekday names in the phone's order: "Mon", "Tue"…
    static var weekdays: [String] {
        let calendar = Calendar.current
        let names = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(names[first...] + names[..<first])
    }
}

/// Calendar's month view, from MobileCal's own tiles: the month named on the
/// banner with the weekdays under it, a grid of day tiles over the month
/// gradient — today in slate, the chosen day in blue, a dot under each day
/// listened on.
private struct CalendarMonthGrid: View {
    let month: Date
    let selected: Date
    let listened: (Date) -> Bool
    let step: (Int) -> Void
    let pick: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            banner
            grid
        }
        .environment(\.colorScheme, .light)
    }

    private var banner: some View {
        let thisMonth = calendar.isDate(month, equalTo: Date(), toGranularity: .month)
        return CalendarBanner(canStepForward: !thisMonth, step: step) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.helvetica(20, weight: .bold))
                .bannerInk()
                .padding(.bottom, 12)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                ForEach(CalendarMonth.weekdays, id: \.self) { day in
                    Text(day)
                        .font(.helvetica(10, weight: .bold))
                        .bannerInk()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 3)
            .allowsHitTesting(false)
        }
    }

    private var grid: some View {
        let days = CalendarMonth.grid(for: month)
        return VStack(spacing: 0) {
            ForEach(0..<days.count / 7, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in tile(days[week * 7 + i]) }
                }
                .frame(height: 44)
            }
        }
        .background { Image.classic("CalMonthGradient").resizable() }
        .overlay(alignment: .top) { Image.classic("CalMonthShadow").resizable().frame(height: 7) }
    }

    private func tile(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let lit = isToday || isSelected
        let heard = listened(day)

        return Button { pick(day) } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.helvetica(22, weight: .bold))
                    .foregroundStyle(lit ? Color.white : (inMonth ? Palette.rgb(0x4B5563) : Palette.rgb(0x9FA4AD)))
                    .shadow(color: lit ? .black.opacity(0.5) : .white, radius: 0, x: 0, y: lit ? -1 : 1)
                Image.classic(lit ? (isSelected ? "CalMarkerSelected" : "CalMarkerToday") : "CalMarker")
                    .opacity(heard ? 1 : 0)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { background(isToday: isToday, isSelected: isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(day > Date())
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(heard ? String(localized: "Listened") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func background(isToday: Bool, isSelected: Bool) -> some View {
        if isSelected {
            Image.classic(isToday ? "CalMonthTileTodaySelected" : "CalMonthTileSelected",
                          top: 2, leading: isToday ? 7 : 1, bottom: 2, trailing: isToday ? 7 : 1)
        } else if isToday {
            Image.classic("CalMonthTileToday", top: 2, leading: 7, bottom: 2, trailing: 7)
        } else {
            Image.classic("CalMonthTile", top: 2, leading: 1, bottom: 1, trailing: 2)
        }
    }
}

// MARK: - Day

/// Calendar's day view: the hours down the left, a hairline at each and a
/// fainter one at each half, and the day's listening laid on them as blocks,
/// each topic in a calendar colour of its own. Today, a red line with
/// Calendar's own marker stands at the present minute.
private struct ListeningDayGrid: View {
    let day: Date
    let entries: [ListeningEntry]

    @EnvironmentObject private var router: NavRouter

    static let hourHeight: CGFloat = 44
    static let gutter: CGFloat = 52

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hours
                    blocks
                    if Calendar.current.isDateInToday(day) { now }
                }
                .frame(height: Self.hourHeight * 24, alignment: .top)
                .padding(.vertical, 14)
            }
            .background(Palette.cell)
            // After the first layout, or the scroll view has nothing to scroll to yet.
            .task(id: day) {
                try? await Task.sleep(for: .milliseconds(60))
                proxy.scrollTo(firstHour, anchor: .top)
            }
        }
    }

    /// Where the day opens: an hour before the first listening, or before now.
    private var firstHour: Int {
        let anchor = spans.map(\.start).min()
            ?? (Calendar.current.isDateInToday(day) ? minutes(Date().timeIntervalSince1970) : 8 * 60)
        return max(0, min(23, Int(anchor / 60) - 1))
    }

    /// Minutes after the day's midnight.
    private func minutes(_ epoch: Double) -> Double {
        (epoch - Calendar.current.startOfDay(for: day).timeIntervalSince1970) / 60
    }

    // MARK: Hours

    private var hours: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...24, id: \.self) { hour in
                let y = CGFloat(hour) * Self.hourHeight
                // Placed by alignment, not offset, so `scrollTo` finds the hour
                // where it is drawn.
                HStack(spacing: 6) {
                    Text(String(format: "%02d:00", hour % 24))
                        .font(.helvetica(12, weight: .bold))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: Self.gutter - 8, alignment: .trailing)
                    Rectangle().fill(Palette.separator).frame(height: 1)
                }
                .frame(height: 14)
                .alignmentGuide(.top) { _ in 7 - y }
                .id(hour)
                if hour < 24 {
                    Rectangle().fill(Palette.separator.opacity(0.45)).frame(height: 1)
                        .padding(.leading, Self.gutter)
                        .alignmentGuide(.top) { _ in -(y + Self.hourHeight / 2) }
                }
            }
        }
    }

    // MARK: Blocks

    private struct Span: Identifiable {
        let entry: ListeningEntry
        let start: Double
        let end: Double
        var column = 0
        var columns = 1
        var id: String { "\(entry.id)-\(start)" }
    }

    /// Each stretch heard, in minutes after midnight, side by side where they
    /// overlap. An entry kept before stretches were is one, ending when it
    /// was last heard.
    private var spans: [Span] {
        let dayLength: Double = 24 * 60
        var spans: [Span] = []
        for entry in entries {
            var sessions = entry.sessions ?? []
            if sessions.isEmpty {
                sessions = [ListeningSession(start: entry.lastHeard - entry.seconds, end: entry.lastHeard)]
            }
            for session in sessions {
                let start: Double = minutes(session.start)
                let end: Double = max(minutes(session.end), start)
                guard end > 0, start < dayLength else { continue }
                spans.append(Span(entry: entry, start: max(0, start), end: min(dayLength, end)))
            }
        }
        spans.sort { $0.start < $1.start }

        // Clusters of overlapping spans share the width between them.
        var cluster: [Int] = []
        var clusterEnd = -1.0
        func close() {
            var ends: [Double] = []
            for i in cluster {
                if let free = ends.firstIndex(where: { $0 <= spans[i].start }) {
                    spans[i].column = free
                    ends[free] = spans[i].end
                } else {
                    spans[i].column = ends.count
                    ends.append(spans[i].end)
                }
            }
            for i in cluster { spans[i].columns = ends.count }
            cluster = []
        }
        for i in spans.indices {
            if spans[i].start >= clusterEnd {
                close()
                clusterEnd = spans[i].end
            } else {
                clusterEnd = max(clusterEnd, spans[i].end)
            }
            cluster.append(i)
        }
        close()
        return spans
    }

    private var blocks: some View {
        GeometryReader { geo in
            let width = geo.size.width - Self.gutter - 4
            ForEach(spans) { span in
                let columnWidth = width / CGFloat(span.columns)
                let y = span.start / 60 * Self.hourHeight
                let height = max((span.end - span.start) / 60 * Self.hourHeight, 20)
                ListeningBlock(entry: span.entry, start: span.start, end: span.end,
                               color: CalendarPalette.color(for: span.entry.topic.id), compact: height < 34)
                    .frame(width: columnWidth - 2, height: height)
                    .offset(x: Self.gutter + CGFloat(span.column) * columnWidth, y: y)
                    .onTapGesture { router.push(span.entry.topic) }
            }
        }
    }

    // MARK: Now

    /// Calendar's present-minute line: red across the day, its marker in the gutter.
    private var now: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let y = minutes(Date().timeIntervalSince1970) / 60 * Self.hourHeight
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.rgb(0xBF1717)).frame(height: 1).padding(.leading, Self.gutter - 2)
                Image.classic("CalNowIndicator").offset(x: Self.gutter - 16)
            }
            .frame(height: 17)
            .offset(y: y - 8.5)
            .allowsHitTesting(false)
        }
    }
}

/// A stretch of listening on the day view: a pale wash of its colour, the
/// colour's edge, and the lecture, its topic and hours in the colour, darkened.
private struct ListeningBlock: View {
    let entry: ListeningEntry
    let start: Double
    let end: Double
    let color: Color
    let compact: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.lectureTitle)
                .font(.helvetica(13, weight: .bold))
            if !compact {
                Text("\(clock(start)) – \(clock(end))  ·  \(entry.topic.title)")
                    .font(.helvetica(11))
            }
        }
        .lineLimit(1)
        .foregroundStyle(color.mix(with: .black, by: 0.35))
        .padding(.horizontal, 5)
        .padding(.vertical, compact ? 1 : 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { shape.fill(color.opacity(0.22)) }
        .overlay { shape.strokeBorder(color.opacity(0.85), lineWidth: 1) }
        .clipShape(shape)
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "21:05" for minutes after midnight.
    private func clock(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return String(format: "%02d:%02d", m / 60 % 24, m % 60)
    }
}
