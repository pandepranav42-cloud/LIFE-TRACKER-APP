import SwiftUI
import SwiftData
import Combine

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Habit.sortIndex) private var habits: [Habit]
    @Query private var scheduleRaw: [ScheduleItem]
    @Query private var allMarks: [CalendarMark]
    @AppStorage("userName") private var userName: String = "there"
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutWidth) private var width
    private var compact: Bool { AppLayout.isCompact(width) }

    /// Live clock. Drives the greeting, the "now" card, day roll-over at
    /// midnight and the automatic quote rotation — no manual refresh needed.
    @State private var now: Date = .now
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private let calendar = Calendar.current

    // MARK: Derived data

    private var engine: ProgressEngine {
        ProgressEngine(habits: habits, marks: allMarks, calendar: calendar, now: now)
    }
    /// Sorted by time of day (stored dates can carry different calendar days).
    private var schedule: [ScheduleItem] {
        scheduleRaw.sorted { minutes(of: $0.startTime) < minutes(of: $1.startTime) }
    }
    private var scheduledHabits: [Habit] {
        habits.filter { $0.isScheduled(on: now, calendar: calendar) }
    }
    private var todayMarks: [CalendarMark] {
        allMarks.filter { calendar.isDate($0.date, inSameDayAs: now) }
    }
    private var todayEvents: [CalendarMark] { todayMarks.filter { $0.kind == .event } }
    private var todayMarkHabits: [CalendarMark] { todayMarks.filter { $0.kind == .habit } }

    private var completedCount: Int {
        scheduledHabits.filter { $0.isCompleted(on: now, calendar: calendar) }.count
            + todayMarkHabits.filter(\.completed).count
    }
    private var totalCount: Int { scheduledHabits.count + todayMarkHabits.count }
    private var dailyProgress: Double {
        totalCount == 0 ? 0 : Double(completedCount) / Double(totalCount)
    }

    private var greeting: String {
        switch calendar.component(.hour, from: now) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }
    private var dateString: String {
        now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased()
    }
    private var summaryLine: String {
        if totalCount == 0 { return "Nothing to tick off today — enjoy the space." }
        if completedCount == totalCount { return "All \(totalCount) done. Lovely work." }
        let left = totalCount - completedCount
        return "\(left) of \(totalCount) left to do today."
    }

    private var currentItem: ScheduleItem? { schedule.first { isCurrent($0) } }
    private var nextItem: ScheduleItem? {
        let n = minutes(of: now)
        return schedule
            .filter { minutes(of: $0.startTime) > n }
            .min { minutes(of: $0.startTime) < minutes(of: $1.startTime) }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 28 : 36) {
                header
                QuoteView(quote: QuoteBank.quote(at: now))

                if currentItem != nil || nextItem != nil {
                    NowCard(current: currentItem, next: nextItem, now: now, stacked: compact)
                }

                if !todayEvents.isEmpty {
                    section("Marked today") { FlowChips(marks: todayEvents) }
                }

                habitsSection
                scheduleSection
                weekSection
            }
            .pageContainer(maxWidth: 820)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Today")
        .onReceive(clock) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
        .onChange(of: scenePhase) { _, phase in if phase == .active { now = .now } }
        .animation(.easeInOut(duration: 0.6), value: QuoteBank.quote(at: now).id)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(dateString)
                    .font(.mono(11, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.accent)
                Text("\(greeting), \(userName)")
                    .font(.mono(compact ? 24 : 30, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(summaryLine)
                    .font(.mono(13))
                    .foregroundStyle(Palette.mutedText)
            }
            Spacer(minLength: 12)
            ProgressRing(progress: dailyProgress, size: compact ? 60 : 76, lineWidth: 5)
        }
    }

    private var habitsSection: some View {
        section("Habits", trailing: totalCount == 0 ? nil : "\(completedCount)/\(totalCount)") {
            if totalCount == 0 {
                emptyLine("No habits scheduled for today.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    LinearBar(value: dailyProgress)
                    VStack(spacing: 2) {
                        ForEach(scheduledHabits) { habit in
                            HabitRow(name: habit.name,
                                     iconName: habit.iconName,
                                     isCompleted: habit.isCompleted(on: now, calendar: calendar),
                                     detail: doneTime(habit),
                                     onToggle: { toggle(habit) })
                        }
                        ForEach(todayMarkHabits) { mark in
                            HabitRow(name: mark.title,
                                     iconName: "calendar",
                                     isCompleted: mark.completed,
                                     detail: mark.completed
                                        ? "Calendar · " + (mark.completedAt?.formatted(date: .omitted, time: .shortened) ?? "done")
                                        : "Calendar",
                                     dotColor: Color(hex: mark.colorHex),
                                     onToggle: { toggleMark(mark) })
                        }
                    }
                    .padding(.horizontal, -12)
                }
            }
        }
    }

    private var scheduleSection: some View {
        let doneCount = schedule.filter { $0.completion(on: now, calendar: calendar) != nil }.count
        return section("Schedule", trailing: schedule.isEmpty ? nil : "\(doneCount)/\(schedule.count) done") {
            if schedule.isEmpty {
                emptyLine("No schedule yet — add items in the Schedule tab.")
            } else {
                VStack(spacing: 0) {
                    ForEach(schedule) { item in
                        TimelineRow(item: item,
                                    state: state(of: item),
                                    isLast: item.id == schedule.last?.id,
                                    doneAt: item.completion(on: now, calendar: calendar)?.completedAt,
                                    onToggle: { toggleSchedule(item) })
                    }
                }
            }
        }
    }

    private var weekSection: some View {
        let week = engine.period(lastDays: 7)
        let rateText = week.rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        return section("Last 7 days", trailing: rateText) {
            WeekStrip(days: week.days)
        }
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, trailing: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title, trailing: trailing)
            content()
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Palette.mutedText)
    }

    private func toggle(_ habit: Habit) {
        let day = calendar.startOfDay(for: now)
        let existing = habit.completions.filter { calendar.isDate($0.date, inSameDayAs: day) }
        if existing.isEmpty {
            context.insert(HabitCompletion(date: day, habit: habit))
        } else {
            existing.forEach { context.delete($0) }   // also clears any accidental duplicates
        }
        try? context.save()
    }

    private func toggleMark(_ mark: CalendarMark) {
        mark.completed.toggle()
        mark.completedAt = mark.completed ? .now : nil
        try? context.save()
        Task {
            await CalendarSync.shared.push(mark)
            try? context.save()
        }
    }

    private func toggleSchedule(_ item: ScheduleItem) {
        let existing = item.completions.filter { calendar.isDate($0.date, inSameDayAs: now) }
        if existing.isEmpty {
            context.insert(ScheduleCompletion(item: item, date: now))
        } else {
            existing.forEach { context.delete($0) }
        }
        try? context.save()
    }

    /// "done 9:42" for habits ticked today (older ticks may have no time).
    private func doneTime(_ habit: Habit) -> String? {
        guard let c = habit.completions.first(where: { calendar.isDate($0.date, inSameDayAs: now) }) else { return nil }
        return c.completedAt.map { "done \($0.formatted(date: .omitted, time: .shortened))" } ?? "done"
    }

    private func minutes(of date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func isCurrent(_ item: ScheduleItem) -> Bool {
        let n = minutes(of: now), s = minutes(of: item.startTime), e = minutes(of: item.endTime)
        if e <= s { return n >= s || n < e }   // runs past midnight
        return s <= n && n < e
    }

    private func state(of item: ScheduleItem) -> TimelineRow.Phase {
        if isCurrent(item) { return .current }
        let e = minutes(of: item.endTime), s = minutes(of: item.startTime)
        return (e > s && e <= minutes(of: now)) ? .past : .upcoming
    }
}

// MARK: - Quote (rotates automatically)

private struct QuoteView: View {
    let quote: QuoteBank.Quote

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(quote.text)
                    .font(.mono(14))
                    .italic()
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(quote.author.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.mutedText)
            }
            .padding(.leading, 18)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.accent.opacity(0.8))
                    .frame(width: 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Palette.callout, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .id(quote.id)
        .transition(.opacity)
    }
}

// MARK: - Now / Next

private struct NowCard: View {
    let current: ScheduleItem?
    let next: ScheduleItem?
    let now: Date
    var stacked: Bool = false

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                             : AnyLayout(HStackLayout(spacing: 0))
        layout {
            if let current {
                block(label: "NOW", item: current, highlight: true)
            }
            if current != nil && next != nil {
                if stacked {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                } else {
                    Rectangle().fill(Palette.hairline).frame(width: 1).padding(.vertical, 4)
                }
            }
            if let next {
                block(label: "NEXT", item: next, highlight: false)
            }
        }
        .padding(18)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
    }

    private func block(label: String, item: ScheduleItem, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: item.colorHex)).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.mutedText)
            }
            Text(item.title)
                .font(.system(size: highlight ? 17 : 15, weight: highlight ? .semibold : .medium))
                .lineLimit(1)
            Text(highlight ? remaining(until: item.endTime) : startsIn(item.startTime))
                .font(.system(size: 12))
                .foregroundStyle(Palette.mutedText)
                .monospacedDigit()
            if highlight {
                LinearBar(value: elapsed(item), height: 3)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func mins(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private func span(_ from: Int, _ to: Int) -> Int { (to - from + 1440) % 1440 }
    private func format(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
    private func remaining(until end: Date) -> String {
        "\(format(span(mins(now), mins(end)))) left · ends \(end.formatted(date: .omitted, time: .shortened))"
    }
    private func startsIn(_ start: Date) -> String {
        "in \(format(span(mins(now), mins(start)))) · \(start.formatted(date: .omitted, time: .shortened))"
    }
    private func elapsed(_ item: ScheduleItem) -> Double {
        let total = span(mins(item.startTime), mins(item.endTime))
        guard total > 0 else { return 0 }
        return Double(span(mins(item.startTime), mins(now))) / Double(total)
    }
}

// MARK: - Timeline

private struct TimelineRow: View {
    enum Phase { case past, current, upcoming }
    let item: ScheduleItem
    let state: Phase
    let isLast: Bool
    var doneAt: Date? = nil
    var onToggle: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(item.startTime.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: state == .current ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(state == .current ? .primary : Palette.mutedText)
                .frame(width: 64, alignment: .trailing)
                .padding(.top, 1)

            Color.clear.frame(width: 12, height: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: state == .current ? .semibold : .regular))
                    .strikethrough(doneAt != nil, color: Palette.mutedText)
                Text(doneAt.map { "done at \($0.formatted(date: .omitted, time: .shortened))" }
                     ?? "\(item.category) · until \(item.endTime.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(doneAt != nil ? Palette.schedule : Palette.mutedText)
            }
            .padding(.bottom, isLast ? 0 : 18)
            Spacer()
            Button(action: onToggle) {
                CheckCircle(isOn: doneAt != nil, tint: Palette.schedule, size: 20)
            }
            .buttonStyle(.plain)
            .help(doneAt == nil ? "Mark this task done" : "Mark as not done")
        }
        .background(alignment: .topLeading) {
            // Dot + connecting line, drawn behind so the line always spans the full row height.
            VStack(spacing: 0) {
                Circle()
                    .fill(state == .upcoming ? Color.clear : Color(hex: item.colorHex))
                    .overlay(Circle().strokeBorder(Color(hex: item.colorHex), lineWidth: 1.5))
                    .frame(width: state == .current ? 11 : 9, height: state == .current ? 11 : 9)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                if !isLast {
                    Rectangle().fill(Palette.hairline).frame(width: 1)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 12)
            .padding(.leading, 64 + 16)
        }
        .opacity(state == .past && doneAt == nil ? 0.45 : 1)
    }
}

// MARK: - Week strip

private struct WeekStrip: View {
    let days: [DayProgress]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(days) { d in
                VStack(spacing: 8) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Palette.subtleFill)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Palette.accent.opacity(d.isToday ? 0.45 : 0.85))
                            .frame(height: max(0, 56 * (d.rate ?? 0)))
                    }
                    .frame(height: 56)
                    Text(d.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 11, weight: d.isToday ? .bold : .regular))
                        .foregroundStyle(d.isToday ? .primary : Palette.mutedText)
                }
                .frame(maxWidth: .infinity)
                .help(tooltip(d))
            }
        }
    }

    private func tooltip(_ d: DayProgress) -> String {
        let date = d.date.formatted(.dateTime.weekday(.wide).day().month())
        if d.isToday { return "\(date): \(d.completed) done, \(d.pending) still open" }
        if d.scheduled == 0 { return "\(date): nothing scheduled" }
        return "\(date): \(d.completed) of \(d.scheduled) done"
    }
}

// MARK: - Marked Today chips

private struct FlowChips: View {
    let marks: [CalendarMark]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(marks) { mark in
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: mark.colorHex)).frame(width: 7, height: 7)
                    Text(mark.title).font(.system(size: 13))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(hex: mark.colorHex).opacity(0.15), in: Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
