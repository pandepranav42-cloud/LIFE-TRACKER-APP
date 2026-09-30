import Foundation
import SwiftData

// MARK: - What Life AI is allowed to change
//
// Every tool call the model makes ends up here. Nothing else in the app gives
// it write access, so this file is the complete list of what it can do to your
// data — and it can only add, never delete or overwrite.
//
// Each function returns one short sentence. That sentence goes back to the
// model (so it can confirm in its own words) and is also shown as a green tick
// under the answer, so you always see what changed.

enum LifeAIActions {

    @MainActor
    static func perform(_ action: AIAction, context: ModelContext) -> String {
        switch action.name {
        case "add_reminder":       return addReminder(action.args, context: context)
        case "add_schedule_block": return addScheduleBlock(action.args, context: context)
        case "add_calendar_mark":  return addCalendarMark(action.args, context: context)
        case "add_habit":          return addHabit(action.args, context: context)
        case "add_syllabus_topic": return addSyllabusTopic(action.args, context: context)
        case "add_subject_note":   return addSubjectNote(action.args, context: context)
        default:                   return "Unknown action \"\(action.name)\" — nothing was changed."
        }
    }

    // MARK: Study reminders

    @MainActor
    private static func addReminder(_ args: [String: String], context: ModelContext) -> String {
        guard let title = clean(args["title"]) else { return "No reminder text given, so nothing was added." }
        let existing = (try? context.fetch(FetchDescriptor<StudyTodo>())) ?? []
        if existing.contains(where: { !$0.isDone && $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            return "\"\(title)\" is already on the reminder list."
        }
        context.insert(StudyTodo(title: title, day: 0))
        try? context.save()
        return "Added reminder: \(title)"
    }

    // MARK: Schedule

    @MainActor
    private static func addScheduleBlock(_ args: [String: String], context: ModelContext) -> String {
        guard let title = clean(args["title"]) else { return "No title given, so no block was added." }
        guard let start = time(args["start"]) else { return "Couldn't read the start time, so no block was added." }
        let end = time(args["end"]) ?? Calendar.current.date(byAdding: .hour, value: 1, to: start) ?? start
        let wantsReminder = (args["reminder"] ?? "").lowercased() == "true"

        let existing = (try? context.fetch(FetchDescriptor<ScheduleItem>())) ?? []
        let item = ScheduleItem(title: title,
                                startTime: start,
                                endTime: end,
                                category: "Study",
                                reminderEnabled: wantsReminder,
                                sortIndex: (existing.map(\.sortIndex).max() ?? 0) + 1,
                                colorHex: CategoryColorSwatches.hexValues.randomElement() ?? "D9B38C")
        context.insert(item)
        try? context.save()
        // Saving the store is what re-schedules notifications and refreshes
        // the widgets (BackgroundCoordinator listens for didSave), so there is
        // nothing else to poke here.

        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        return "Added \(formatter.string(from: start))–\(formatter.string(from: end)) \(title) to Schedule"
    }

    // MARK: Calendar

    @MainActor
    private static func addCalendarMark(_ args: [String: String], context: ModelContext) -> String {
        guard let title = clean(args["title"]) else { return "No title given, so nothing was marked." }
        guard let date = day(args["date"]) else { return "Couldn't read that date, so nothing was marked." }
        let kind: CalendarMarkKind = (args["kind"] ?? "event").lowercased() == "habit" ? .habit : .event

        let existing = (try? context.fetch(FetchDescriptor<CalendarMark>())) ?? []
        if existing.contains(where: {
            Calendar.current.isDate($0.date, inSameDayAs: date)
                && $0.title.caseInsensitiveCompare(title) == .orderedSame
        }) {
            return "\"\(title)\" was already on the calendar that day."
        }

        let mark = CalendarMark(date: date, title: title,
                                colorHex: kind == .habit ? "B9C7A5" : "E6B8B0",
                                kind: kind)
        context.insert(mark)
        try? context.save()
        // Mirror it into Apple / Google Calendar if either is connected.
        Task { await CalendarSync.shared.push(mark) }

        let formatter = DateFormatter(); formatter.dateFormat = "EEE d MMM"
        return "Marked \(formatter.string(from: date)): \(title)"
    }

    // MARK: Habits

    @MainActor
    private static func addHabit(_ args: [String: String], context: ModelContext) -> String {
        guard let name = clean(args["name"]) else { return "No habit name given, so nothing was added." }
        let existing = (try? context.fetch(FetchDescriptor<Habit>())) ?? []
        if existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "\"\(name)\" is already one of your habits."
        }
        let frequency: HabitFrequency
        switch (args["frequency"] ?? "daily").lowercased() {
        case "weekdays": frequency = .weekdays
        case "weekends": frequency = .weekends
        default:         frequency = .daily
        }
        context.insert(Habit(name: name,
                             iconName: "sparkles",
                             frequency: frequency,
                             sortIndex: (existing.map(\.sortIndex).max() ?? 0) + 1))
        try? context.save()
        return "Added habit: \(name) (\(frequency.label.lowercased()))"
    }

    // MARK: Syllabus

    @MainActor
    private static func addSyllabusTopic(_ args: [String: String], context: ModelContext) -> String {
        guard let title = clean(args["title"]) else { return "No topic given, so nothing was added." }
        guard let wanted = clean(args["subject"]) else { return "No subject named, so nothing was added." }

        let subjects = (try? context.fetch(FetchDescriptor<StudySubject>())) ?? []
        guard let subject = match(wanted, in: subjects) else {
            let names = subjects.map(\.name).joined(separator: ", ")
            return "There's no subject called \"\(wanted)\". Existing subjects: \(names.isEmpty ? "none yet" : names)."
        }
        if subject.topics.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            return "\"\(title)\" is already in \(subject.name)'s syllabus."
        }
        let topic = SyllabusTopic(title: title,
                                  sortIndex: (subject.topics.map(\.sortIndex).max() ?? 0) + 1,
                                  subject: subject)
        context.insert(topic)
        try? context.save()
        return "Added \"\(title)\" to \(subject.name)"
    }

    // MARK: Subject notes

    @MainActor
    private static func addSubjectNote(_ args: [String: String], context: ModelContext) -> String {
        guard let body = clean(args["body"]) else { return "No note text given, so nothing was saved." }
        guard let wanted = clean(args["subject"]) else { return "No subject named, so nothing was saved." }

        let subjects = (try? context.fetch(FetchDescriptor<StudySubject>())) ?? []
        guard let subject = match(wanted, in: subjects) else {
            let names = subjects.map(\.name).joined(separator: ", ")
            return "There's no subject called \"\(wanted)\". Existing subjects: \(names.isEmpty ? "none yet" : names)."
        }
        let heading = clean(args["heading"]) ?? AINotes.suggestedHeading(for: body)
        AINotes.append(body, heading: heading, to: subject, context: context)
        return "Saved \"\(heading)\" to \(subject.name)'s notes"
    }

    // MARK: Parsing helpers

    private static func clean(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Exact name first, then a case-insensitive contains either way, so
    /// "CV lab" still finds "Computer Vision Lab".
    private static func match(_ wanted: String, in subjects: [StudySubject]) -> StudySubject? {
        if let exact = subjects.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return exact
        }
        let needle = wanted.lowercased()
        return subjects.first { $0.name.lowercased().contains(needle) || needle.contains($0.name.lowercased()) }
    }

    /// "HH:MM" on today's date — ScheduleItem only uses the time components.
    private static func time(_ value: String?) -> Date? {
        guard let value = clean(value) else { return nil }
        let parts = value.components(separatedBy: ":")
        guard let hour = Int(parts.first ?? ""), (0...23).contains(hour) else { return nil }
        let minute = parts.count > 1 ? (Int(parts[1].prefix(2)) ?? 0) : 0
        return Calendar.current.date(bySettingHour: hour, minute: min(minute, 59), second: 0, of: .now)
    }

    /// "YYYY-MM-DD", plus "today" and "tomorrow" in case the model uses them.
    private static func day(_ value: String?) -> Date? {
        guard let value = clean(value)?.lowercased() else { return nil }
        let today = Calendar.current.startOfDay(for: .now)
        if value == "today" { return today }
        if value == "tomorrow" { return Calendar.current.date(byAdding: .day, value: 1, to: today) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: String(value.prefix(10))) else { return nil }
        return Calendar.current.startOfDay(for: parsed)
    }
}
