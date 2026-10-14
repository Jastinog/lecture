import SwiftUI

/// Route to the listening calendar.
struct ListeningCalendarRoute: Hashable {}

/// The listening calendar, after iOS 6 Calendar's month view: the days
/// listened on are dotted, and a tap on one lists what was heard that day.
struct ListeningCalendarView: View {
    @ObservedObject private var log = ListeningLog.shared

    /// The first day of the month shown.
    @State private var month = CalendarMonth.start(of: Date())
    @State private var selected = Calendar.current.startOfDay(for: Date())

    var body: some View {
        List {
            Section {
                VStack(spacing: 0) {
                    MonthHeader(month: month, step: step, today: showToday)
                    MonthGrid(month: month, selected: selected, log: log) { day in
                        selected = day
                        let start = CalendarMonth.start(of: day)
                        if start != month { withAnimation(.easeInOut(duration: 0.25)) { month = start } }
                    }
                    .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        step(value.translation.width < 0 ? 1 : -1)
                    })
                    Text(monthSummary)
                        .font(.rowCaption)
                        .embossed()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(CalendarInk.headerBottom)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }

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
                PlainSectionHeader(title: dayTitle)
            }
        }
        .listStyle(.plain)
        .plainBackground(emptyRowHeight: RowMetrics.bookRowHeight)
        .classicNavigationTitle(String(localized: "Listening Calendar"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NowPlayingToolbarItem() }
    }

    private func step(_ months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { month = next }
    }

    private func showToday() {
        let today = Calendar.current.startOfDay(for: Date())
        selected = today
        withAnimation(.easeInOut(duration: 0.25)) { month = CalendarMonth.start(of: today) }
    }

    /// "Thursday, 15 October · 1 h 20 min".
    private var dayTitle: String {
        let date = selected.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let seconds = log.seconds(on: selected)
        return seconds >= 60 ? "\(date) · \(formatDuration(seconds))" : date
    }

    /// "12 days · 14 h 30 min" for the month shown, and the streak while it's
    /// this month.
    private var monthSummary: String {
        let days = CalendarMonth.days(in: month)
        let listened = days.filter(log.listened(on:))
        guard !listened.isEmpty else { return String(localized: "No listening this month") }
        let total = listened.reduce(0) { $0 + log.seconds(on: $1) }
        var parts = [String(localized: "\(listened.count) days"), formatDuration(total)]
        let streak = log.streak()
        if month == CalendarMonth.start(of: Date()), streak > 1 {
            parts.append(String(localized: "\(streak) days in a row"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A lecture heard on the chosen day; opens its topic.
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

// MARK: - Home's week

/// This week in the calendar, for Home: a strip of the week's days, the time
/// heard in it and the streak. Opens the calendar.
struct ListeningWeekRow: View {
    @ObservedObject private var log = ListeningLog.shared

    var body: some View {
        RowLink(value: ListeningCalendarRoute()) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        VStack(spacing: 2) {
                            Text(day.formatted(.dateTime.weekday(.short)))
                                .font(.helvetica(10, weight: .bold))
                                .rowForeground(Palette.secondaryText)
                            DayTile(day: day, inMonth: true, selected: false,
                                    listened: log.listened(on: day), height: 34)
                        }
                    }
                }
                Text(summary)
                    .font(.rowCaption)
                    .rowForeground(Palette.secondaryText)
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
        }
    }

    /// The days of this week, in the phone's order.
    private var week: [Date] {
        let calendar = Calendar.current
        guard let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// "This week 2 h 10 min · 4 days in a row".
    private var summary: String {
        let total = week.reduce(0) { $0 + log.seconds(on: $1) }
        guard total >= 60 else { return String(localized: "Nothing listened to this week yet") }
        let streak = log.streak()
        let week = String(localized: "This week \(formatDuration(total))")
        return streak > 1 ? "\(week) · \(String(localized: "\(streak) days in a row"))" : week
    }
}

// MARK: - Month

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

/// The grey band over the grid: the month between its arrows (a tap on it
/// comes back to today), and the weekday names.
private struct MonthHeader: View {
    let month: Date
    let step: (Int) -> Void
    let today: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                arrow(-1)
                Spacer()
                Button(action: today) {
                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(.helvetica(20, weight: .bold))
                        .embossed(Palette.embossedStrong)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows today")
                Spacer()
                arrow(1)
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            HStack(spacing: 0) {
                ForEach(CalendarMonth.weekdays, id: \.self) { name in
                    Text(name)
                        .font(.helvetica(10, weight: .bold))
                        .embossed()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 3)
        }
        .background(LinearGradient(colors: [CalendarInk.headerTop, CalendarInk.headerBottom],
                                   startPoint: .top, endPoint: .bottom))
    }

    private func arrow(_ direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: direction < 0 ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                .font(.system(size: 14))
                .embossed()
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction < 0 ? "Previous Month" : "Next Month")
    }
}

/// The month's days as tiles, ruled like iOS 6 Calendar's.
private struct MonthGrid: View {
    let month: Date
    let selected: Date
    @ObservedObject var log: ListeningLog
    let select: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let calendar = Calendar.current
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(CalendarMonth.grid(for: month), id: \.self) { day in
                Button { select(day) } label: {
                    DayTile(day: day, inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                            selected: calendar.isDate(day, inSameDayAs: selected),
                            listened: log.listened(on: day), height: 46)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(CalendarInk.rule).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(CalendarInk.rule).frame(height: 1) }
    }
}

/// A day in the calendar: its number on a grey tile, slate blue for today and
/// bright blue when chosen, with a dot under it when it was listened on.
struct DayTile: View {
    let day: Date
    let inMonth: Bool
    let selected: Bool
    let listened: Bool
    var height: CGFloat = 46

    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        let lit = selected || today
        VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.helvetica(height > 40 ? 18 : 15, weight: .bold))
                .foregroundStyle(lit ? .white : inMonth ? CalendarInk.number : CalendarInk.otherMonth)
                .shadow(color: lit ? .black.opacity(0.45) : CalendarInk.numberShadow,
                        radius: 0, x: 0, y: lit ? -1 : 1)
            Circle()
                .fill(lit ? .white : CalendarInk.dot)
                .frame(width: 5, height: 5)
                .opacity(listened ? 1 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .background { background(today: today) }
        .overlay(alignment: .trailing) { Rectangle().fill(CalendarInk.rule).frame(width: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(CalendarInk.rule).frame(height: 0.5) }
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(listened ? String(localized: "Listened") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func background(today: Bool) -> some View {
        if selected {
            LinearGradient(colors: [Palette.rgb(0x3F8BEF), Palette.rgb(0x1257C4)], startPoint: .top, endPoint: .bottom)
        } else if today {
            LinearGradient(colors: [Palette.rgb(0x8193B0), Palette.rgb(0x5C7193)], startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(colors: inMonth ? [CalendarInk.tileTop, CalendarInk.tileBottom]
                                           : [CalendarInk.otherTileTop, CalendarInk.otherTileBottom],
                           startPoint: .top, endPoint: .bottom)
                // The white edge along the tile's top.
                .overlay(alignment: .top) { Rectangle().fill(CalendarInk.highlight).frame(height: 1) }
        }
    }
}

/// iOS 6 Calendar's greys, and their dark-theme counterparts.
private enum CalendarInk {
    static let headerTop = Palette.rgb(0xF7F7F8, dark: 0x3A3A3D)
    static let headerBottom = Palette.rgb(0xD5D6DB, dark: 0x252527)
    static let tileTop = Palette.rgb(0xEDEEF1, dark: 0x2C2C2F)
    static let tileBottom = Palette.rgb(0xDDDFE4, dark: 0x232325)
    static let otherTileTop = Palette.rgb(0xDFE0E4, dark: 0x1E1E20)
    static let otherTileBottom = Palette.rgb(0xD2D4DA, dark: 0x19191A)
    static let highlight = Palette.rgb(0xFAFAFB, dark: 0x38383B)
    static let rule = Palette.rgb(0xA5A8B0, dark: 0x000000)
    static let number = Palette.rgb(0x3D4253, dark: 0xD8D9DE)
    static let otherMonth = Palette.rgb(0x9DA1AB, dark: 0x5E5F65)
    static let numberShadow = Palette.shade(UIColor(white: 1, alpha: 0.8), dark: UIColor(white: 0, alpha: 0.6))
    static let dot = Palette.rgb(0x3D4253, dark: 0xB4B6BD)
}
