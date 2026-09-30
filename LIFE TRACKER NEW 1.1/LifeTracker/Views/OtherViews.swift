import SwiftUI
import SwiftData
import Charts
import Combine
import LocalAuthentication

// MARK: - Calendar

struct CalendarPageView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Habit.sortIndex) private var habits: [Habit]
    @Query private var journals: [JournalEntry]
    @Query private var marks: [CalendarMark]

    @State private var selectedDate: Date = .now
    @State private var month: Date = .now
    @State private var showingSync = false
    @ObservedObject private var sync = CalendarSync.shared
    private let cal = Calendar.current

    /// Apple Calendar events for the visible month (read-only), minus the
    /// ones we created ourselves from marks.
    private var external: [ExternalEvent] {
        _ = sync.revision
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let own = Set(marks.compactMap(\.appleEventID))
        return sync.externalEvents(from: interval.start, to: interval.end, excluding: own)
    }

    var body: some View {
        let external = self.external
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(title: "Calendar")
                    Button { showingSync = true } label: {
                        Label(syncLabel, systemImage: sync.appleEnabled || sync.googleEnabled
                              ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                            .font(.mono(12))
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                }
                HStack(spacing: 10) {
                    Button {
                        month = cal.date(byAdding: .month, value: -1, to: month) ?? month
                    } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(.plain)
                    Text(monthTitle.uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1)
                        .frame(minWidth: 150)
                    Button {
                        month = cal.date(byAdding: .month, value: 1, to: month) ?? month
                    } label: { Image(systemName: "arrow.right") }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.tan, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Button("Today") { month = .now; selectedDate = .now }
                        .buttonStyle(.bordered)
                }

                MonthGrid(month: month, selected: $selectedDate, marks: marks, external: external)
                    .hairlineCard()

                DayDetail(date: selectedDate,
                          habits: habits,
                          journal: journals.first { cal.isDate($0.date, inSameDayAs: selectedDate) },
                          marks: marks.filter { cal.isDate($0.date, inSameDayAs: selectedDate) },
                          external: external.filter { cal.isDate($0.start, inSameDayAs: selectedDate) })
            }
            .pageContainer(maxWidth: 900)
        }
        .navigationTitle("Calendar")
        .sheet(isPresented: $showingSync) {
            CalendarSyncSheet(marks: marks)
        }
    }

    private var syncLabel: String {
        switch (sync.appleEnabled, sync.googleEnabled) {
        case (true, true): return "Apple + Google"
        case (true, false): return "Apple Calendar"
        case (false, true): return "Google Calendar"
        default: return "Sync"
        }
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: month)
    }
}

private struct MonthGrid: View {
    let month: Date
    @Binding var selected: Date
    let marks: [CalendarMark]
    var external: [ExternalEvent] = []
    private let cal = Calendar.current
    private let weekdayLabels = ["S","M","T","W","T","F","S"]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ForEach(0..<7, id: \.self) { i in
                    Text(weekdayLabels[i])
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(Palette.mutedText)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        DayCell(date: day,
                                selected: cal.isDate(day, inSameDayAs: selected),
                                today: cal.isDateInToday(day),
                                marks: marks.filter { cal.isDate($0.date, inSameDayAs: day) },
                                external: external.filter { cal.isDate($0.start, inSameDayAs: day) })
                            .onTapGesture { selected = day }
                    } else {
                        Color.clear.frame(height: 62)
                    }
                }
            }
        }
    }

    private var days: [Date?] {
        let interval = cal.dateInterval(of: .month, for: month)!
        let firstWeekday = cal.component(.weekday, from: interval.start) // 1 = Sun
        let daysInMonth = cal.range(of: .day, in: .month, for: month)!.count
        var result: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for d in 1...daysInMonth {
            let comp = DateComponents(year: cal.component(.year, from: month),
                                      month: cal.component(.month, from: month),
                                      day: d)
            result.append(cal.date(from: comp))
        }
        return result
    }
}

private struct DayCell: View {
    let date: Date
    let selected: Bool
    let today: Bool
    let marks: [CalendarMark]
    var external: [ExternalEvent] = []

    var body: some View {
        let shown = Array(marks.prefix(2))
        let extShown = Array(external.prefix(max(0, 2 - shown.count)))
        let overflow = marks.count + external.count - shown.count - extShown.count
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 12, weight: today ? .semibold : .regular))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown) { mark in
                    Text((mark.kind == .habit ? "✓ " : "") + mark.title)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: mark.colorHex).opacity(0.28), in: RoundedRectangle(cornerRadius: 3))
                }
                ForEach(extShown) { ev in
                    Text(ev.title)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(ev.color).frame(width: 2)
                        }
                        .foregroundStyle(Palette.mutedText)
                }
                if overflow > 0 {
                    Text("+\(overflow) more")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Palette.mutedText)
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .top)
        .background(selected ? Palette.callout : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(today ? Palette.accent : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

private struct DayDetail: View {
    @Environment(\.modelContext) private var context
    let date: Date
    let habits: [Habit]
    let journal: JournalEntry?
    let marks: [CalendarMark]
    var external: [ExternalEvent] = []
    private let cal = Calendar.current

    @State private var newTitle = ""
    @State private var newColorHex = CategoryColorSwatches.hexValues[0]
    @State private var newKind: CalendarMarkKind = .event

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: dayTitle)
            VStack(alignment: .leading, spacing: 8) {
                // ---- Important Dates: at the top, add + manage what's marked for this day ----
                Text("Important Dates").font(.caption).foregroundStyle(Palette.mutedText)

                if marks.isEmpty {
                    Text("Nothing marked for this day yet.")
                        .font(.caption)
                        .foregroundStyle(Palette.mutedText)
                } else {
                    ForEach(marks) { mark in
                        MarkRow(mark: mark)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("e.g. Exam, Deadline, Anniversary", text: $newTitle)
                        .textFieldStyle(.plain)
                    HStack(spacing: 10) {
                        Picker("", selection: $newKind) {
                            Text("Event").tag(CalendarMarkKind.event)
                            Text("Habit (this day)").tag(CalendarMarkKind.habit)
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        ColorSwatchButton(selection: $newColorHex)
                        Button("Add") { addMark() }
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }
                }
                .padding(.top, 4)

                if !external.isEmpty {
                    Divider().overlay(Palette.hairline).padding(.vertical, 4)
                    Text("From your calendars").font(.caption).foregroundStyle(Palette.mutedText)
                    ForEach(external) { ev in
                        HStack(spacing: 8) {
                            Circle().fill(ev.color).frame(width: 8, height: 8)
                            Text(ev.title).font(.subheadline)
                            Spacer()
                            Text(ev.isAllDay ? "all day" : ev.start.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(Palette.mutedText)
                            Text(ev.calendarTitle)
                                .font(.caption2).foregroundStyle(Palette.mutedText)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Palette.subtleFill, in: Capsule())
                        }
                    }
                }

                Divider().overlay(Palette.hairline).padding(.vertical, 4)

                let scheduled = habits.filter { $0.isScheduled(on: date, calendar: cal) }
                if scheduled.isEmpty {
                    Text("No habits scheduled.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.mutedText)
                } else {
                    ForEach(scheduled) { h in
                        HStack {
                            Image(systemName: h.isCompleted(on: date, calendar: cal) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(h.isCompleted(on: date, calendar: cal) ? Palette.accent : Palette.mutedText)
                            Text(h.name)
                            Spacer()
                        }
                        .font(.subheadline)
                    }
                }
                if let journal, !journal.text.isEmpty {
                    Divider().overlay(Palette.hairline).padding(.vertical, 4)
                    Text("Journal").font(.caption).foregroundStyle(Palette.mutedText)
                    if UserDefaults.standard.bool(forKey: "journal.lockEnabled") {
                        Label("Locked — open Journal to read", systemImage: "lock.fill")
                            .font(.subheadline).foregroundStyle(Palette.mutedText)
                    } else {
                        Text(journal.text).font(.subheadline)
                    }
                }
            }
            .hairlineCard()
        }
        .id(date) // reset local @State (newTitle/newColorHex/newKind) when the selected day changes
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }

    private func addMark() {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let mark = CalendarMark(date: date, title: trimmed, colorHex: newColorHex, kind: newKind)
        context.insert(mark)
        try? context.save()
        Task {
            await CalendarSync.shared.push(mark)
            try? context.save()
        }
        newTitle = ""
        newColorHex = CategoryColorSwatches.hexValues.randomElement() ?? newColorHex
    }
}

private struct MarkRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var mark: CalendarMark

    private func pushChange() {
        try? context.save()
        Task {
            await CalendarSync.shared.push(mark)
            try? context.save()
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if mark.kind == .habit {
                Button {
                    mark.completed.toggle()
                    mark.completedAt = mark.completed ? .now : nil
                    pushChange()
                } label: {
                    Image(systemName: mark.completed ? "checkmark.square.fill" : "square")
                        .foregroundStyle(mark.completed ? Palette.accent : Palette.mutedText)
                }
                .buttonStyle(.plain)
            }
            ColorSwatchButton(selection: Binding(
                get: { mark.colorHex },
                set: { mark.colorHex = $0; try? context.save() }
            ))
            TextField("Title", text: Binding(
                get: { mark.title },
                set: { mark.title = $0 }
            ))
            .textFieldStyle(.plain)
            .onSubmit { pushChange() }
            Text(mark.kind == .habit ? "Habit" : "Event")
                .font(.caption2)
                .foregroundStyle(Palette.mutedText)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Palette.subtleFill, in: Capsule())
            Spacer()
            if mark.appleEventID != nil || mark.googleEventID != nil {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.mutedText)
                    .help("Synced to your calendar")
            }
            Button {
                let apple = mark.appleEventID, google = mark.googleEventID
                let id = mark.id, day = mark.date
                context.delete(mark)
                try? context.save()
                Task { await CalendarSync.shared.remove(appleID: apple, googleID: google, markID: id, on: day) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.mutedText)
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
    }
}


// MARK: - Progress

struct ProgressPageView: View {
    @Query(sort: \Habit.sortIndex) private var habits: [Habit]
    @Query private var marks: [CalendarMark]
    @Query private var scheduleDone: [ScheduleCompletion]
    @State private var selectedDay: Date?     // live chart selection (hover / drag)
    @State private var pinnedDay: Date?       // last picked day — stays after the pointer leaves
    @AppStorage("progressRange") private var rangeRaw: String = ProgressRange.month.rawValue
    @State private var now: Date = .now
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let cal = Calendar.current

    enum ProgressRange: String, CaseIterable, Identifiable {
        case week, month30, month, quarter
        var id: String { rawValue }
        var title: String {
            switch self {
            case .week: "7 days"
            case .month30: "30 days"
            case .month: "This month"
            case .quarter: "90 days"
            }
        }
    }

    private var range: ProgressRange { ProgressRange(rawValue: rangeRaw) ?? .month }
    private var engine: ProgressEngine {
        ProgressEngine(habits: habits, marks: marks, scheduleDone: scheduleDone, calendar: cal, now: now)
    }

    /// Number of days in the selected range (ending today).
    private var rangeLength: Int {
        switch range {
        case .week: return 7
        case .month30: return 30
        case .quarter: return 90
        case .month:
            let today = cal.startOfDay(for: now)
            let start = cal.dateInterval(of: .month, for: now)?.start ?? today
            return max((cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1, 1)
        }
    }

    var body: some View {
        let engine = self.engine                       // build lookup tables once per render
        let rangeDays = engine.lastDays(rangeLength)
        let previousDays = engine.lastDays(rangeLength, endingDaysAgo: rangeLength)
        let current = PeriodProgress(days: rangeDays.map { engine.day($0) })
        let previous = PeriodProgress(days: previousDays.map { engine.day($0) })
        let perHabit = engine.habitProgress(over: rangeDays)
            .filter { $0.scheduled > 0 }
            .sorted { ($0.rate ?? 0, $0.completed) > ($1.rate ?? 0, $1.completed) }
        let oneOff = oneOffProgress(over: rangeDays, today: engine.today)
        let weekdays = engine.weekdayCounts(over: current)
        let logDay = cal.startOfDay(for: pinnedDay ?? engine.today)
        let log = engine.log(on: logDay)

        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom) {
                        PageTitle(title: "Progress", subtitle: rangeSubtitle(rangeDays))
                            .fixedSize()
                        Spacer(minLength: 16)
                        rangePicker.frame(width: 340)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        PageTitle(title: "Progress", subtitle: rangeSubtitle(rangeDays))
                        rangePicker
                    }
                }

                if habits.isEmpty && marks.allSatisfy({ $0.kind != .habit }) && scheduleDone.isEmpty {
                    EmptyState(icon: "chart.bar",
                               title: "Nothing to measure yet",
                               message: "Add a habit and tick it off — your progress will show up here.",
                               fillsSpace: false)
                        .padding(.top, 60)
                } else {
                    // Headline numbers
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        StatCard(label: "Completion",
                                 value: percent(current.rate),
                                 sublabel: deltaText(current.rate, previous.rate, days: rangeLength))
                        StatCard(label: "Done",
                                 value: "\(current.completed)",
                                 sublabel: "of \(current.scheduled) due")
                        StatCard(label: "Perfect days",
                                 value: "\(current.perfectDays)",
                                 sublabel: "of \(current.days.filter { $0.scheduled > 0 && !$0.isToday }.count) days")
                        StatCard(label: "Active days",
                                 value: "\(current.activeDays)",
                                 sublabel: "of \(current.days.count) days")
                    }

                    // Daily completion chart
                    SectionHeader(title: "Daily completion",
                                  trailing: Platform.isMac ? "click a day to see times" : "tap a day to see times")
                    VStack(alignment: .leading, spacing: 18) {
                        dailyChart(current)
                            .frame(height: 200)
                        Divider().overlay(Palette.hairline)
                        DayLogView(day: logDay, entries: log, isToday: logDay == engine.today)
                    }
                    .hairlineCard()

                    // Weekday pattern
                    SectionHeader(title: "By weekday", trailing: weekdayInsight(weekdays))
                    WeekdayBars(counts: weekdays)
                        .hairlineCard()

                    // Per-habit
                    SectionHeader(title: "Habits", trailing: "done / due")
                    VStack(spacing: 14) {
                        ForEach(perHabit) { p in
                            HabitProgressRow(name: p.name, icon: p.iconName,
                                             completed: p.completed, scheduled: p.scheduled)
                        }
                        if oneOff.scheduled > 0 {
                            HabitProgressRow(name: "One-off (Calendar)", icon: "calendar",
                                             completed: oneOff.completed, scheduled: oneOff.scheduled)
                        }
                        if perHabit.isEmpty && oneOff.scheduled == 0 {
                            Text("Nothing was due in this range yet.")
                                .font(.subheadline).foregroundStyle(Palette.mutedText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .hairlineCard()

                    Text("Only days a habit was actually scheduled count. Paused days and days before a habit started are ignored, and today only counts what you've already finished — it won't show as a miss until the day is over.")
                        .font(.caption)
                        .foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .pageContainer(maxWidth: 900)
        }
        .navigationTitle("Progress")
        .onReceive(clock) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
        .onChange(of: selectedDay) { _, new in
            if let new, new <= .now { pinnedDay = cal.startOfDay(for: new) }
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $rangeRaw) {
            ForEach(ProgressRange.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: Chart

    @ViewBuilder
    private func dailyChart(_ period: PeriodProgress) -> some View {
        let points = period.days.filter { $0.rate != nil }
        if points.isEmpty {
            Text("No habits were due in this range.")
                .font(.subheadline).foregroundStyle(Palette.mutedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(points) { d in
                    BarMark(x: .value("Day", d.date, unit: .day),
                            y: .value("Completion", (d.rate ?? 0) * 100))
                        .foregroundStyle(Palette.accent.opacity(d.isToday ? 0.35 : 0.85))
                        .cornerRadius(2)
                }
                if let avg = period.rate {
                    RuleMark(y: .value("Average", avg * 100))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Palette.mutedText)
                }
                if let sel = pinnedDay {
                    RuleMark(x: .value("Selected", sel, unit: .day))
                        .foregroundStyle(Palette.accent.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 14))
                }
            }
            .chartXSelection(value: $selectedDay)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0.0, 50.0, 100.0]) { value in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))%").font(.caption2).foregroundStyle(Palette.mutedText)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: xStride)) { _ in
                    AxisValueLabel(format: axisFormat)
                }
            }
        }
    }

    private var axisFormat: Date.FormatStyle {
        range == .week
            ? Date.FormatStyle.dateTime.weekday(.abbreviated)
            : Date.FormatStyle.dateTime.day().month(.abbreviated)
    }

    private var xStride: Int {
        switch range {
        case .week: 1
        case .month, .month30: 5
        case .quarter: 15
        }
    }

    // MARK: Helpers

    private func rangeSubtitle(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let f = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return "\(first.formatted(f)) – \(last.formatted(f))"
    }

    private func percent(_ r: Double?) -> String {
        r.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private func deltaText(_ cur: Double?, _ prev: Double?, days: Int) -> String {
        guard let cur else { return "nothing due yet" }
        guard let prev else { return "no earlier data" }
        let diff = Int(((cur - prev) * 100).rounded())
        if diff == 0 { return "same as previous \(days)d" }
        return "\(diff > 0 ? "▲" : "▼") \(abs(diff)) pts vs previous \(days)d"
    }

    private func weekdayInsight(_ counts: [(habits: Int, schedule: Int)]) -> String? {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let totals = counts.map { $0.habits + $0.schedule }
        guard let best = totals.indices.max(by: { totals[$0] < totals[$1] }), totals[best] > 0 else { return nil }
        return "most done on \(names[best])"
    }

    private func oneOffProgress(over days: [Date], today: Date) -> (scheduled: Int, completed: Int) {
        let set = Set(days.map { cal.startOfDay(for: $0) })
        var due = 0, done = 0
        for m in marks where m.kind == .habit {
            let d = cal.startOfDay(for: m.date)
            guard set.contains(d) else { continue }
            if d == today && !m.completed { continue }
            due += 1
            if m.completed { done += 1 }
        }
        return (due, done)
    }
}

private struct HabitProgressRow: View {
    let name: String
    let icon: String
    let completed: Int
    let scheduled: Int
    private var rate: Double { scheduled == 0 ? 0 : Double(completed) / Double(scheduled) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.mutedText)
                    .frame(width: 16)
                Text(name).font(.subheadline)
                Spacer()
                Text("\(completed)/\(scheduled)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(Palette.mutedText)
                Text("\(Int((rate * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            LinearBar(value: rate)
        }
    }
}

/// Per weekday: how many things you actually ticked off in the selected range.
private struct WeekdayBars: View {
    let counts: [(habits: Int, schedule: Int)]   // Mon … Sun
    @Environment(\.layoutWidth) private var width
    private let labels = ["M", "T", "W", "T", "F", "S", "S"]
    private var totals: [Int] { counts.map { $0.habits + $0.schedule } }
    private var maxTotal: Int { max(1, totals.max() ?? 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: AppLayout.isCompact(width) ? 6 : 14) {
            ForEach(0..<7, id: \.self) { i in
                let n = totals[i]
                VStack(spacing: 6) {
                    Text("\(n)")
                        .font(.mono(n > 0 ? 15 : 13, n > 0 ? .bold : .regular))
                        .foregroundStyle(n > 0 ? Palette.accent : Palette.mutedText.opacity(0.6))
                    Text("done")
                        .font(.mono(9))
                        .foregroundStyle(Palette.mutedText)
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.subtleFill)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.accent.opacity(0.85))
                            .frame(height: n == 0 ? 0 : max(6, 80 * CGFloat(n) / CGFloat(maxTotal)))
                    }
                    .frame(height: 80)
                    Text(labels[i])
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.mutedText)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Everything ticked on one day with the exact time — habits and schedule
/// tasks listed separately.
private struct DayLogView: View {
    let day: Date
    let entries: [CompletionLogEntry]
    let isToday: Bool

    var body: some View {
        let habitEntries = entries.filter { $0.kind != .schedule }
        let scheduleEntries = entries.filter { $0.kind == .schedule }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.mono(13, .bold))
                Spacer()
                Text("habit \(habitEntries.count) · schedule \(scheduleEntries.count)")
                    .font(.mono(11))
                    .foregroundStyle(Palette.mutedText)
            }
            if entries.isEmpty {
                Text("Nothing ticked off on this day.")
                    .font(.subheadline).foregroundStyle(Palette.mutedText)
            } else {
                group(title: "Habits", color: Palette.accent, items: habitEntries)
                group(title: "Schedule tasks", color: Palette.schedule, items: scheduleEntries)
            }
        }
    }

    @ViewBuilder
    private func group(title: String, color: Color, items: [CompletionLogEntry]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.lowercased())
                    .font(.mono(11, .semibold)).italic()
                    .foregroundStyle(color)
                ForEach(items) { e in
                    HStack(spacing: 10) {
                        Text(e.time.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                            .font(.mono(12, .semibold))
                            .monospacedDigit()
                            .frame(width: 74, alignment: .leading)
                            .foregroundStyle(color)
                        Image(systemName: e.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(e.colorHex.map { Color(hex: $0) } ?? Palette.mutedText)
                            .frame(width: 16)
                        Text(e.title).font(.subheadline)
                        if e.kind == .oneOff {
                            Text("calendar").font(.caption2).foregroundStyle(Palette.mutedText)
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}

// MARK: - Journal

/// Journal page behind an optional lock (Touch ID / Face ID / device password).
struct JournalView: View {
    @ObservedObject private var lock = JournalLock.shared
    @AppStorage("journal.lockEnabled") private var lockEnabled = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if lockEnabled && !lock.isUnlocked {
                JournalLockedView()
            } else {
                JournalContentView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: lock.isUnlocked)
        // Re-lock whenever you leave the Journal or the app goes to the background.
        .onDisappear { lock.lock() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { lock.lock() } }
    }
}

private struct JournalContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \JournalEntry.date, order: .reverse) private var entries: [JournalEntry]
    @AppStorage("journal.lockEnabled") private var lockEnabled = false
    @ObservedObject private var lock = JournalLock.shared
    @State private var title: String = ""
    @State private var text: String = ""
    @State private var mood: Int = 3
    @State private var energy: Int = 3
    @State private var colorHex: String = CategoryColorSwatches.hexValues[0]
    @State private var justSaved = false

    private let cal = Calendar.current
    private let today = Calendar.current.startOfDay(for: .now)

    private var savedEntries: [JournalEntry] {
        entries
            .filter { !$0.text.isEmpty || !$0.title.isEmpty }
            .sorted { ($0.savedAt ?? $0.date) > ($1.savedAt ?? $1.date) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    PageTitle(title: "Journal", subtitle: "\(dateLabel) · you can only write today's entry")
                    Button {
                        Task {
                            if lockEnabled {
                                lockEnabled = false            // turning off: already unlocked
                            } else if await lock.authenticate(reason: "Turn on the Journal lock") {
                                lockEnabled = true
                            }
                        }
                    } label: {
                        Label(lockEnabled ? "Locked" : "Lock", systemImage: lockEnabled ? "lock.fill" : "lock.open")
                            .font(.mono(12))
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .help(lockEnabled ? "Journal asks for Touch ID / password every time you open it. Click to turn off." : "Protect your journal with Touch ID / Face ID or your password")
                }

                HStack(spacing: 10) {
                    TextField("Give today a title (optional)", text: $title)
                        .font(.system(size: 15, weight: .medium))
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Palette.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
                    ColorSwatchButton(selection: $colorHex, size: 22)
                }

                SectionHeader(title: "How was your day?")
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(12)
                    .background(Palette.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        RatingPicker(label: "Mood", value: $mood)
                        RatingPicker(label: "Energy", value: $energy)
                        Spacer()
                        saveButton
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        RatingPicker(label: "Mood", value: $mood)
                        RatingPicker(label: "Energy", value: $energy)
                        saveButton
                    }
                }

                SectionHeader(title: "Saved Entries", trailing: "\(savedEntries.count)")
                if savedEntries.isEmpty {
                    Text("Nothing saved yet — your entries will show up here.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.mutedText)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(savedEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if let hex = entry.colorHex {
                                        Circle().fill(Color(hex: hex)).frame(width: 8, height: 8)
                                    }
                                    Text(entry.title.isEmpty ? "Untitled" : entry.title)
                                        .font(.subheadline).fontWeight(.medium)
                                    Spacer()
                                    Text(metaLabel(for: entry))
                                        .font(.caption2)
                                        .foregroundStyle(Palette.mutedText)
                                        .monospacedDigit()
                                }
                                if !entry.text.isEmpty {
                                    Text(entry.text)
                                        .font(.caption)
                                        .foregroundStyle(Palette.mutedText)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 10)
                            if entry.id != savedEntries.last?.id {
                                Divider().overlay(Palette.hairline)
                            }
                        }
                    }
                    .hairlineCard()
                }
            }
            .pageContainer(maxWidth: 900)
        }
        .navigationTitle("Journal")
        .onAppear { load() }
    }

    private var dateLabel: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f.string(from: today)
    }
    private var saveButton: some View {
        Button(justSaved ? "Saved" : "Save") { save() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }
    private func metaLabel(for entry: JournalEntry) -> String {
        let df = DateFormatter(); df.dateFormat = "MMM d, yyyy"
        var label = df.string(from: entry.date)
        if let savedAt = entry.savedAt {
            let tf = DateFormatter(); tf.dateFormat = "h:mm a"
            label += " · saved \(tf.string(from: savedAt))"
        }
        return label
    }
    private func load() {
        if let e = entries.first(where: { cal.isDate($0.date, inSameDayAs: today) }) {
            title = e.title; text = e.text; mood = e.mood; energy = e.energy
            colorHex = e.colorHex ?? CategoryColorSwatches.hexValues[0]
        } else {
            title = ""; text = ""; mood = 3; energy = 3
            colorHex = CategoryColorSwatches.hexValues.randomElement() ?? CategoryColorSwatches.hexValues[0]
        }
        justSaved = false
    }
    private func save() {
        if let e = entries.first(where: { cal.isDate($0.date, inSameDayAs: today) }) {
            e.title = title; e.text = text; e.mood = mood; e.energy = energy; e.colorHex = colorHex; e.savedAt = .now
        } else {
            let entry = JournalEntry(date: today, title: title, text: text, mood: mood, energy: energy, savedAt: .now, colorHex: colorHex)
            context.insert(entry)
        }
        try? context.save()
        justSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSaved = false }
    }
}

private struct RatingPicker: View {
    let label: String
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(Palette.mutedText)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Circle()
                        .fill(i <= value ? Palette.accent : Palette.subtleFill)
                        .frame(width: 10, height: 10)
                                .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { value = i }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("userName") private var userName: String = "there"
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("journal.lockEnabled") private var journalLock = false
    @ObservedObject private var notifications = NotificationManager.shared
    @AppStorage("appearance") private var appearanceRaw: String = AppearanceMode.system.rawValue
    @State private var showingResetConfirm = false
    @State private var copyFeedback = false

    private let devEmail = "pandepranav42@hotmail.com"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    AppLogo(size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LifeTracker").font(.mono(20, .bold))
                        Text("your study & life space").font(.mono(11)).italic()
                            .foregroundStyle(Palette.mutedText)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .font(.caption2).foregroundStyle(Palette.mutedText)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            Section("Profile") {
                FormTextField("Your name", text: $userName)
            }
            AccountsSection()
            Section("Appearance") {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text("System follows your Mac or iPad automatically when it switches between light and dark.")
                    .font(.caption).foregroundStyle(Palette.mutedText)
            }
            Section("Notifications") {
                Toggle("Schedule reminders", isOn: $notificationsEnabled)
                switch notifications.status {
                case .denied:
                    Text("Notifications are blocked for LifeTracker. Turn them on in System Settings → Notifications → LifeTracker.")
                        .font(.caption).foregroundStyle(.red)
                case .notDetermined:
                    Button("Allow notifications") { Task { await notifications.requestPermission() } }
                default:
                    Text(notificationsEnabled
                         ? "You'll get a notification for each schedule item that has “Notify me” on (\(notifications.pendingCount) set up on this device)."
                         : "Schedule reminders are off.")
                        .font(.caption).foregroundStyle(Palette.mutedText)
                }
            }
            .task { await notifications.refreshStatus() }
            .onChange(of: notificationsEnabled) { _, on in
                Task {
                    if on { await notifications.requestPermission() }
                    await BackgroundCoordinator.shared.refreshNow(context)
                }
            }
            Section("Privacy") {
                Toggle(isOn: Binding(
                    get: { journalLock },
                    set: { on in
                        // Changing the lock always needs your fingerprint / password.
                        Task {
                            if await JournalLock.shared.authenticate(reason: on ? "Turn on the Journal lock" : "Turn off the Journal lock") {
                                journalLock = on
                                JournalLock.shared.lock()
                            }
                        }
                    })) {
                    Label("Lock Journal", systemImage: "lock.fill")
                }
                Text("Asks for \(JournalLock.shared.biometryName) every time you open the Journal, and hides journal text on the Calendar page.")
                    .font(.caption).foregroundStyle(Palette.mutedText)
            }
            // Grouped so the Form stays within ViewBuilder's 10-child limit.
            Group {
                LifeAISection()
                TransferSection()
            }
            Section("Data") {
                Button("Reset all data…", role: .destructive) { showingResetConfirm = true }
                Text("This erases every habit, schedule item, timetable, calendar mark, journal entry, and all study subjects and materials — and, if you ask it to, the Google Drive backup as well. Cannot be undone.")
                    .font(.caption).foregroundStyle(Palette.mutedText)
            }
            Section("About") {
                Text("Track your life without making tracking your life another chore.")
                    .font(.caption).foregroundStyle(Palette.mutedText)
            }
            Section("Developer") {
                DeveloperCard(email: devEmail, copyFeedback: $copyFeedback, onCopy: copyEmail)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .themedForm()
        .macMinSize(width: 480, height: 480)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingResetConfirm) {
            ResetDataSheet { alsoDrive in
                Task { @MainActor in
                    // Calendars and Drive first — once the database is wiped
                    // the event and file ids are gone with it.
                    let marks = (try? context.fetch(FetchDescriptor<CalendarMark>())) ?? []
                    await CalendarSync.shared.removeEverything(marks)
                    if alsoDrive { await DriveSync.shared.removeEverything(context: context) }
                    resetAllData()
                    await BackgroundCoordinator.shared.refreshNow(context)
                }
            }
        }
    }

    private func resetAllData() {
        func deleteAll<T: PersistentModel>(_ type: T.Type) {
            if let items = try? context.fetch(FetchDescriptor<T>()) {
                for item in items { context.delete(item) }
            }
        }
        deleteAll(Habit.self)
        deleteAll(HabitCompletion.self)
        deleteAll(ScheduleCompletion.self)
        deleteAll(ScheduleItem.self)
        deleteAll(JournalEntry.self)
        deleteAll(TimetableCategory.self)
        deleteAll(TimetableSlot.self)
        deleteAll(TimetableImageAsset.self)
        deleteAll(TimetableBlock.self)
        deleteAll(CalendarMark.self)
        deleteAll(StudySubject.self)
        deleteAll(SyllabusTopic.self)
        deleteAll(StudyMaterial.self)
        deleteAll(StudyLink.self)
        deleteAll(StudyTodo.self)
        deleteAll(MoodBoardImage.self)
        deleteAll(UniPortal.self)
        // Life AI's chat history and the passages indexed from your material.
        deleteAll(AIMessage.self)
        deleteAll(AIConversation.self)
        deleteAll(AIChunk.self)
        try? context.save()
        userName = "there"
    }

    private func copyEmail() {
        Platform.copy(devEmail)
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copyFeedback = false }
    }
}

// MARK: - Reset warning

/// The last thing standing between you and an empty app. Spells out exactly
/// what's about to go, offers to take the Google Drive backup with it, and
/// won't let you press the button until you've typed ERASE.
private struct ResetDataSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var drive = DriveSync.shared

    /// Called with `true` when the Drive backup should go too.
    var onErase: (Bool) -> Void

    @State private var alsoDrive = true

    private func count<T: PersistentModel>(_ type: T.Type) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
    }

    private var driveCount: Int {
        let materials = (try? context.fetch(FetchDescriptor<StudyMaterial>()))?.filter { $0.driveFileID != nil }.count ?? 0
        let images = (try? context.fetch(FetchDescriptor<MoodBoardImage>()))?.filter { $0.driveFileID != nil }.count ?? 0
        let timetable = (try? context.fetch(FetchDescriptor<TimetableImageAsset>()))?.filter { $0.driveFileID != nil }.count ?? 0
        return materials + images + timetable
    }

    private var rows: [(String, Int)] {
        [("Habits", count(Habit.self)),
         ("Habit ticks", count(HabitCompletion.self)),
         ("Schedule items", count(ScheduleItem.self)),
         ("Timetable blocks", count(TimetableBlock.self)),
         ("Calendar marks", count(CalendarMark.self)),
         ("Journal entries", count(JournalEntry.self)),
         ("Study subjects", count(StudySubject.self)),
         ("Syllabus topics", count(SyllabusTopic.self)),
         ("Files in subjects", count(StudyMaterial.self)),
         ("Saved links", count(StudyLink.self)),
         ("Mood board pictures", count(MoodBoardImage.self))]
            .filter { $0.1 > 0 }
    }

    /// Only as tall as it needs to be — a short list shouldn't leave a big
    /// empty gap above the buttons.
    private var sheetHeight: CGFloat {
        min(560, 300 + CGFloat(rows.count) * 21)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(hex: "C0453F"))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Erase everything?")
                        .font(.mono(17, .bold))
                    Text("Every single thing in LifeTracker will be deleted. This cannot be undone.")
                        .font(.mono(12))
                        .foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: "C0453F").opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: "C0453F").opacity(0.35)))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if rows.isEmpty {
                        Text("There's nothing stored yet — the app is already empty.")
                            .font(.mono(12)).foregroundStyle(Palette.mutedText)
                    } else {
                        Text("WHAT GOES")
                            .font(.mono(10, .semibold))
                            .tracking(1)
                            .foregroundStyle(Palette.mutedText)
                        ForEach(rows, id: \.0) { row in
                            HStack {
                                Text(row.0).font(.mono(12))
                                Spacer()
                                Text("\(row.1)").font(.mono(12, .semibold)).foregroundStyle(Palette.mutedText)
                            }
                        }
                    }

                    Divider().overlay(Palette.hairline).padding(.vertical, 4)

                    if accounts.isGoogleSignedIn {
                        Toggle(isOn: $alsoDrive) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Also delete the Google Drive backup")
                                    .font(.mono(12, .medium))
                                Text(driveCount > 0
                                     ? "\(driveCount) uploaded file\(driveCount == 1 ? "" : "s") and the whole LifeTracker folder move to Drive's Bin, where they can still be restored for 30 days."
                                     : "The LifeTracker folder in your Drive moves to the Bin, where it can still be restored for 30 days.")
                                    .font(.mono(11))
                                    .foregroundStyle(Palette.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        Label("No Google account is connected, so there's no Drive backup to remove.",
                              systemImage: "info.circle")
                            .font(.mono(11))
                            .foregroundStyle(Palette.mutedText)
                    }

                    Label("Events LifeTracker added to Apple Calendar and Google Calendar are removed too, along with the LifeTracker calendar itself.",
                          systemImage: "calendar.badge.minus")
                        .font(.mono(11))
                        .foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("Want a copy first? Close this and use Export & Import above to save a .lifetracker file.",
                          systemImage: "arrow.down.doc")
                        .font(.mono(11))
                        .foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Erase everything", role: .destructive) {
                    let driveToo = accounts.isGoogleSignedIn && alsoDrive
                    dismiss()
                    onErase(driveToo)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "C0453F"))
            }
        }
        .padding(20)
        .sheetFrame(width: 480, height: sheetHeight)
    }
}

/// Matches the reference "Built by" card design: avatar initials, serif
/// name, email, small studio credit, and right-aligned action buttons.
private struct DeveloperCard: View {
    let email: String
    @Binding var copyFeedback: Bool
    var onCopy: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(hex: "A0714F"), Color(hex: "5E3B24")],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("PP")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text("BUILT BY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Palette.mutedText)
                Text("Pranav Pande")
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                Text(email)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.mutedText)
            }

            Spacer()

            VStack(spacing: 8) {
                Link("Contact", destination: URL(string: "mailto:\(email)")!)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button(copyFeedback ? "Copied" : "Copy email") { onCopy() }
                    .font(.system(size: 13, weight: .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Palette.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(16)
        .background(Palette.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
        .padding(.vertical, 4)
    }
}


// MARK: - Journal lock


/// Unlock state for the Journal. Never persisted: every launch starts locked.
final class JournalLock: ObservableObject {
    static let shared = JournalLock()
    @Published private(set) var isUnlocked = false
    @Published var lastError: String?
    private init() {}

    @MainActor
    func lock() { if isUnlocked { isUnlocked = false } }

    /// Touch ID / Face ID / Optic ID, falling back to the device password.
    @MainActor
    func authenticate(reason: String = "Unlock your journal") async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = "Set up a password or Touch ID / Face ID on this device to use the Journal lock."
            return false
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { lastError = nil; withAnimation { isUnlocked = true } }
            return ok
        } catch {
            if (error as? LAError)?.code != .userCancel && (error as? LAError)?.code != .appCancel {
                lastError = error.localizedDescription
            }
            return false
        }
    }

    var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return "your password"
        }
    }
}

private struct JournalLockedView: View {
    @ObservedObject private var lock = JournalLock.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 76, height: 76)
                .background(Palette.callout, in: Circle())
            Text("Your journal is locked").font(.mono(17, .bold))
            Text("Only you can read it. Unlock with \(lock.biometryName).")
                .font(.mono(12)).foregroundStyle(Palette.mutedText)
                .multilineTextAlignment(.center)
            Button {
                Task { await lock.authenticate() }
            } label: {
                Label("Unlock Journal", systemImage: "touchid")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            if let e = lock.lastError {
                Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
        .navigationTitle("Journal")
        .task { await lock.authenticate() }   // ask straight away when you open Journal
    }
}
