import SwiftUI

/// Route to the listening calendar.
struct ListeningCalendarRoute: Hashable {}

/// The listening calendar: iOS 6 Calendar's month on top, the days listened
/// on dotted, and under it the lectures heard in that month, day by day, the
/// latest first. A tap on a day scrolls to it; a tap on a lecture plays it.
struct ListeningCalendarView: View {
    @ObservedObject private var log = ListeningLog.shared
    /// The first day of the month shown.
    @State private var month = CalendarMonth.start(of: Date())
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: NavRouter
    @StateObject private var starter = LectureStarter()

    var body: some View {
        VStack(spacing: 0) {
            CalendarMonthGrid(month: month, selected: selected, listened: log.listened(on:),
                              step: step, pick: { selected = $0 })
                .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    step(value.translation.width < 0 ? 1 : -1)
                })
            days
        }
        .classicNavigationTitle(String(localized: "Listening Calendar"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NowPlayingToolbarItem() }
        .onDisappear { starter.cancel() }
    }

    /// The month's days listened on, the latest first.
    private var listenedDays: [Date] {
        CalendarMonth.days(in: month).filter(log.listened(on:)).reversed()
    }

    private var days: some View {
        let days = listenedDays
        return ScrollViewReader { proxy in
            List {
                ForEach(days, id: \.self) { day in
                    Section {
                        ForEach(log.entries(on: day).indexed, id: \.element.id) { i, entry in
                            RowButton(action: { play(entry) }) {
                                LectureLine(entry, detail: heardFacts(entry), loading: starter.loading == entry.id,
                                            isCurrent: player.isCurrent(topicID: entry.topic.id, lectureID: entry.lectureID))
                            }
                            .zebraRow(i)
                        }
                        .plainRow()
                    } header: {
                        PlainSectionHeader(title: dayTitle(day))
                    }
                    .id(day)
                }
                if !days.isEmpty {
                    Text(monthSummary(days))
                        .font(.rowCaption)
                        .foregroundStyle(Palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .listRowSeparator(.hidden)
                        .plainRow()
                }
            }
            .listStyle(.plain)
            .plainBackground()
            .overlay {
                if days.isEmpty {
                    ClassicEmptyState(String(localized: "No listening this month"))
                }
            }
            .onChange(of: selected) { _, day in
                guard days.contains(day) else { return }
                withAnimation { proxy.scrollTo(day, anchor: .top) }
            }
        }
    }

    private func play(_ entry: ListeningEntry) { starter.play(entry, player: player, router: router) }

    /// "34 min · 21:05": how long it was heard that day, and when last.
    private func heardFacts(_ entry: ListeningEntry) -> String {
        "\(formatDuration(entry.seconds)) · \(entry.lastHeardTime)"
    }

    private func step(_ months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: month),
              next <= CalendarMonth.start(of: Date()) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { month = next }
    }

    /// "12 days · 14 h 30 min", and the streak while it's this month.
    private func monthSummary(_ days: [Date]) -> String {
        let total = days.reduce(0) { $0 + log.seconds(on: $1) }
        var parts = [String(localized: "\(days.count) days"), formatDuration(total)]
        let streak = log.streak()
        if month == CalendarMonth.start(of: Date()), streak > 1 {
            parts.append(String(localized: "\(streak) days in a row"))
        }
        return parts.joined(separator: " · ")
    }

    /// "Thursday, 15 October · 1 h 20 min".
    private func dayTitle(_ day: Date) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return "\(date) · \(formatDuration(log.seconds(on: day)))"
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
