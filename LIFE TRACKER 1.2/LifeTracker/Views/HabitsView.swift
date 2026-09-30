import SwiftUI
import SwiftData

struct HabitsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Habit.sortIndex) private var habits: [Habit]
    @State private var showingAdd = false
    @State private var editing: Habit?

    var body: some View {
        Group {
            if habits.isEmpty {
                EmptyState(icon: "checklist",
                           title: "No habits yet",
                           message: "Add a habit to start tracking. Small, consistent actions compound.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        PageTitle(title: "Habits", subtitle: "tick today's habits right here")
                        SectionHeader(title: "All Habits",
                                      trailing: "\(habits.count) total")
                        VStack(spacing: 0) {
                            ForEach(habits) { habit in
                                HabitManageRow(habit: habit, onEdit: { editing = habit })
                                if habit.id != habits.last?.id {
                                    Divider().overlay(Palette.hairline)
                                }
                            }
                        }
                        .hairlineCard()

                        // This month — calendar-shaped grid per habit
                        SectionHeader(title: "This Month")
                        VStack(spacing: 12) {
                            ForEach(habits) { habit in
                                HabitMonthGrid(habit: habit)
                            }
                        }
                        .hairlineCard()

                        // History grid — last 30 days per habit
                        SectionHeader(title: "Last 30 days")
                        VStack(spacing: 12) {
                            ForEach(habits) { habit in
                                HabitHistoryStrip(habit: habit)
                            }
                        }
                        .hairlineCard()
                    }
                    .pageContainer(maxWidth: 900)
                }
            }
        }
        .navigationTitle("Habits")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("New Habit", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            HabitEditor(habit: nil)
        }
        .sheet(item: $editing) { habit in
            HabitEditor(habit: habit)
        }
    }
}

private struct HabitManageRow: View {
    @Environment(\.modelContext) private var context
    let habit: Habit
    let onEdit: () -> Void
    private let calendar = Calendar.current
    private var today: Date { .now }

    private var isScheduledToday: Bool { habit.isScheduled(on: today, calendar: calendar) }
    private var isCompletedToday: Bool { habit.isCompleted(on: today, calendar: calendar) }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: toggleToday) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isCompletedToday ? Palette.accent : Palette.hairline, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isCompletedToday ? Palette.accent : Color.clear)
                        )
                    if isCompletedToday {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.onAccent)
                    }
                }
                .opacity(isScheduledToday ? 1 : 0.35)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isScheduledToday)
            .help(isScheduledToday ? "Mark today done / not done" : "Not scheduled today")
            .animation(.easeInOut(duration: 0.15), value: isCompletedToday)

            Image(systemName: habit.iconName)
                .foregroundStyle(Palette.mutedText)
                .frame(width: 20)
                .onTapGesture { onEdit() }
            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name)
                Text(habit.frequency.label)
                    .font(.caption)
                    .foregroundStyle(Palette.mutedText)
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }
            Spacer()
            if habit.isPaused {
                Text("Paused")
                    .font(.caption)
                    .foregroundStyle(Palette.mutedText)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.subtleFill, in: Capsule())
            }
            Menu {
                Button(habit.isPaused ? "Resume" : "Pause") {
                    if habit.isPaused { habit.resume() } else { habit.pause() }
                    try? context.save()
                }
                Button("Delete", role: .destructive) {
                    context.delete(habit)
                    try? context.save()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Palette.mutedText)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func toggleToday() {
        guard isScheduledToday else { return }
        let day = calendar.startOfDay(for: today)
        if let existing = habit.completions.first(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
            context.delete(existing)
        } else {
            context.insert(HabitCompletion(date: day, habit: habit))
        }
        try? context.save()
    }
}

private struct HabitMonthGrid: View {
    let habit: Habit
    private let cal = Calendar.current

    private var monthDays: [Date?] {
        let now = Date()
        let year = cal.component(.year, from: now), month = cal.component(.month, from: now)
        let comps = DateComponents(year: year, month: month, day: 1)
        guard let firstOfMonth = cal.date(from: comps) else { return [] }
        let firstWeekday = cal.component(.weekday, from: firstOfMonth) // 1 = Sun
        let daysInMonth = cal.range(of: .day, in: .month, for: firstOfMonth)!.count
        var result: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for d in 1...daysInMonth {
            result.append(cal.date(from: DateComponents(year: year, month: month, day: d)))
        }
        return result
    }
    /// Month days up to today — future days aren't "due" yet.
    private var elapsedDays: [Date] {
        let today = cal.startOfDay(for: .now)
        return monthDays.compactMap { $0 }.filter { $0 <= today }
    }
    private var scheduledCount: Int {
        elapsedDays.filter { habit.isScheduled(on: $0, calendar: cal) }.count
    }
    private var completedCount: Int {
        elapsedDays.filter { habit.isScheduled(on: $0, calendar: cal) && habit.isCompleted(on: $0, calendar: cal) }.count
    }

    private let columns = Array(repeating: GridItem(.fixed(14), spacing: 3), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(habit.name).font(.subheadline)
                Spacer()
                Text("\(completedCount) / \(scheduledCount)")
                    .font(.caption)
                    .foregroundStyle(Palette.mutedText)
            }
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let scheduled = habit.isScheduled(on: date, calendar: cal)
                        let completed = habit.isCompleted(on: date, calendar: cal)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(scheduled && completed ? Palette.accent : Color.clear)
                            .frame(width: 14, height: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(!scheduled ? Color.clear : Palette.hairline,
                                                  lineWidth: scheduled && !completed ? 1 : 0)
                            )
                            .background(!scheduled ? Palette.subtleFill : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                    } else {
                        Color.clear.frame(width: 14, height: 14)
                    }
                }
            }
        }
    }
}

private struct HabitHistoryStrip: View {
    let habit: Habit
    private let days = 30
    private let cal = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(habit.name).font(.subheadline)
                Spacer()
                Text("\(completedInWindow) / \(scheduledInWindow)")
                    .font(.caption)
                    .foregroundStyle(Palette.mutedText)
            }
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(dayList, id: \.self) { date in
                    let scheduled = habit.isScheduled(on: date, calendar: cal)
                    let completed = habit.isCompleted(on: date, calendar: cal)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fill(scheduled: scheduled, completed: completed))
                        .frame(width: 14, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: scheduled && !completed ? 1 : 0)
                        )
                        .help(dateLabel(date))
                }
            }
            }
            .defaultScrollAnchor(.trailing)
        }
    }

    private var dayList: [Date] {
        let today = cal.startOfDay(for: .now)
        return (0..<days).reversed().compactMap {
            cal.date(byAdding: .day, value: -$0, to: today)
        }
    }
    private var scheduledInWindow: Int {
        dayList.filter { habit.isScheduled(on: $0, calendar: cal) }.count
    }
    private var completedInWindow: Int {
        dayList.filter { habit.isScheduled(on: $0, calendar: cal) && habit.isCompleted(on: $0, calendar: cal) }.count
    }
    private func fill(scheduled: Bool, completed: Bool) -> Color {
        if !scheduled { return Palette.subtleFill }
        return completed ? Palette.accent : Color.clear
    }
    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

// MARK: - Editor

struct HabitEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let habit: Habit?

    @State private var name = ""
    @State private var iconName = "circle"
    @State private var frequency: HabitFrequency = .daily
    @State private var customWeekdays: Set<Int> = []
    @State private var startDate: Date = .now

    private let iconChoices = [
        "circle", "book", "figure.run", "drop", "moon.stars",
        "keyboard", "leaf", "brain.head.profile", "cup.and.saucer",
        "pencil", "guitars", "dumbbell", "fork.knife"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(habit == nil ? "New Habit" : "Edit Habit")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            Divider().overlay(Palette.hairline)

            Form {
                Section {
                    FormTextField("Name", text: $name)
                    Picker("Icon", selection: $iconName) {
                        ForEach(iconChoices, id: \.self) { icon in
                            Label(icon, systemImage: icon).tag(icon)
                        }
                    }
                    Picker("Frequency", selection: $frequency) {
                        ForEach(HabitFrequency.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    if frequency == .custom {
                        WeekdayPicker(selection: $customWeekdays)
                    }
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                }
            }
            .themedForm()
        }
        .sheetFrame(width: 460, height: 460)
        .onAppear {
            if let habit {
                name = habit.name
                iconName = habit.iconName
                frequency = habit.frequency
                customWeekdays = Set(habit.customWeekdays)
                startDate = habit.startDate
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let habit {
            habit.name = trimmed
            habit.iconName = iconName
            habit.frequency = frequency
            habit.customWeekdays = Array(customWeekdays).sorted()
            habit.startDate = startDate
        } else {
            let newHabit = Habit(
                name: trimmed,
                iconName: iconName,
                frequency: frequency,
                customWeekdays: Array(customWeekdays).sorted(),
                startDate: startDate,
                sortIndex: Int.random(in: 0...100000)
            )
            context.insert(newHabit)
        }
        try? context.save()
        dismiss()
    }
}

private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private let days = [("S", 1), ("M", 2), ("T", 3), ("W", 4), ("T", 5), ("F", 6), ("S", 7)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.1) { letter, num in
                Button {
                    if selection.contains(num) { selection.remove(num) } else { selection.insert(num) }
                } label: {
                    Text(letter)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(selection.contains(num) ? Palette.accent : Color.clear)
                        .foregroundStyle(selection.contains(num) ? Palette.elevated : .primary)
                        .overlay(
                            Circle().strokeBorder(Palette.hairline, lineWidth: 1)
                        )
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
