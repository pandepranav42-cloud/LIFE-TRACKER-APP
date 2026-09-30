import Foundation
import SwiftData

// MARK: - What Life AI is allowed to see
//
// This file is the single gate between your data and the model. Every fact the
// assistant knows about you is assembled here and nowhere else, so there is one
// place to read if you ever want to check what leaves the device.
//
// Included: habits, schedule, timetable, subjects (names, syllabus, material
// list, links), study reminders, calendar marks, progress figures, and your
// GitHub summary if connected.
//
// **Excluded on purpose: Journal.** Entries, moods, energy and the mood board
// are never read here, never summarised, and never sent. If you add a page to
// the app it is invisible to Life AI until it is added below deliberately.

enum AIContextBuilder {

    /// A compact digest of the app, written for a language model rather than a
    /// person. Kept to a few thousand characters so it can ride along with
    /// every message without eating the context window.
    @MainActor
    static func snapshot(context: ModelContext,
                         github: GitHubSync = .shared,
                         now: Date = .now,
                         calendar: Calendar = .current) -> String {

        var out: [String] = []

        let habits      = (try? context.fetch(FetchDescriptor<Habit>())) ?? []
        let marks       = (try? context.fetch(FetchDescriptor<CalendarMark>())) ?? []
        let schedule    = (try? context.fetch(FetchDescriptor<ScheduleItem>())) ?? []
        let doneBlocks  = (try? context.fetch(FetchDescriptor<ScheduleCompletion>())) ?? []
        let subjects    = (try? context.fetch(FetchDescriptor<StudySubject>())) ?? []
        let todos       = (try? context.fetch(FetchDescriptor<StudyTodo>())) ?? []
        let blocks      = (try? context.fetch(FetchDescriptor<TimetableBlock>())) ?? []
        let categories  = (try? context.fetch(FetchDescriptor<TimetableCategory>())) ?? []

        let engine = ProgressEngine(habits: habits, marks: marks, scheduleDone: doneBlocks,
                                    calendar: calendar, now: now)
        let today = calendar.startOfDay(for: now)

        // MARK: Habits

        if habits.isEmpty {
            out.append("HABITS: none set up yet.")
        } else {
            var lines: [String] = []
            let month = engine.lastDays(30)
            let rates = engine.habitProgress(over: month)
            let rateByName = Dictionary(rates.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for h in habits.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                let dueToday = h.isScheduled(on: today, calendar: calendar)
                let done = engine.isDone(h, on: today)
                var bits = [h.frequency.label.lowercased()]
                if h.isPaused { bits.append("paused") }
                else if dueToday { bits.append(done ? "done today" : "DUE TODAY, not done") }
                else { bits.append("not scheduled today") }
                if let r = rateByName[h.name]?.rate {
                    bits.append("\(Int((r * 100).rounded()))% over 30 days")
                }
                lines.append("- \(h.name) — \(bits.joined(separator: ", "))")
            }
            out.append("HABITS (\(habits.count)):\n" + lines.joined(separator: "\n"))
        }

        // MARK: Schedule

        if schedule.isEmpty {
            out.append("SCHEDULE: no blocks.")
        } else {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let lines = schedule
                .sorted { $0.startTime < $1.startTime }
                .prefix(20)
                .map { item -> String in
                    let ticked = item.completion(on: today, calendar: calendar) != nil
                    return "- \(f.string(from: item.startTime))–\(f.string(from: item.endTime)) \(item.title)"
                        + (item.category.isEmpty ? "" : " [\(item.category)]")
                        + (ticked ? " (done today)" : "")
                }
            out.append("DAILY SCHEDULE:\n" + lines.joined(separator: "\n"))
        }

        // MARK: Timetable (today and tomorrow only — the rest is noise)

        if !blocks.isEmpty {
            let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            // TimetableBlock.day is 1 = Monday … 7 = Sunday.
            let isoToday = ((calendar.component(.weekday, from: today) + 5) % 7) + 1
            let isoTomorrow = isoToday % 7 + 1
            func day(_ index: Int, _ label: String) -> String? {
                let rows = blocks.filter { $0.day == index }.sorted { $0.startTime < $1.startTime }
                guard !rows.isEmpty else { return nil }
                let text = rows.map { block -> String in
                    let cat = block.categoryID.flatMap { names[$0] }
                    return "  \(block.startTime)–\(block.endTime) \(block.title)" + (cat.map { " [\($0)]" } ?? "")
                }.joined(separator: "\n")
                return "\(label):\n\(text)"
            }
            let parts = [day(isoToday, "Today"), day(isoTomorrow, "Tomorrow")].compactMap { $0 }
            if !parts.isEmpty { out.append("TIMETABLE\n" + parts.joined(separator: "\n")) }
        }

        // MARK: Subjects

        if subjects.isEmpty {
            out.append("SUBJECTS: none added yet.")
        } else {
            var lines: [String] = []
            for s in subjects.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                var bits: [String] = []
                if !s.teacher.isEmpty { bits.append("taught by \(s.teacher)") }
                if !s.topics.isEmpty {
                    let done = s.topics.filter(\.isDone).count
                    bits.append("syllabus \(done)/\(s.topics.count) done")
                }
                if !s.materials.isEmpty { bits.append("\(s.materials.count) file\(s.materials.count == 1 ? "" : "s")") }
                if !s.links.isEmpty { bits.append("\(s.links.count) link\(s.links.count == 1 ? "" : "s")") }
                lines.append("- \(s.name)\(bits.isEmpty ? "" : " — " + bits.joined(separator: ", "))")

                let pending = s.sortedTopics.filter { !$0.isDone }.prefix(6).map(\.title)
                if !pending.isEmpty {
                    lines.append("    still to cover: " + pending.joined(separator: "; "))
                }
                let files = s.materials.sorted { $0.addedAt > $1.addedAt }.prefix(6).map(\.fileName)
                if !files.isEmpty {
                    lines.append("    material: " + files.joined(separator: "; "))
                }
            }
            out.append("SUBJECTS (\(subjects.count)):\n" + lines.joined(separator: "\n"))
        }

        // MARK: Study reminders

        let openTodos = todos.filter { !$0.isDone }
        if openTodos.isEmpty {
            out.append("STUDY REMINDERS: nothing open.")
        } else {
            let lines = openTodos.sorted { $0.createdAt < $1.createdAt }.prefix(20).map { "- \($0.title)" }
            out.append("STUDY REMINDERS open (\(openTodos.count)):\n" + lines.joined(separator: "\n"))
        }

        // MARK: Calendar — the fortnight ahead, plus anything overdue

        let f = DateFormatter(); f.dateFormat = "EEE d MMM"
        let horizon = calendar.date(byAdding: .day, value: 14, to: today) ?? today
        let upcoming = marks
            .filter { $0.date >= today && $0.date <= horizon }
            .sorted { $0.date < $1.date }
        let overdue = marks
            .filter { $0.kind == .habit && !$0.completed && $0.date < today }
            .sorted { $0.date < $1.date }
            .suffix(5)

        if upcoming.isEmpty && overdue.isEmpty {
            out.append("CALENDAR: nothing marked in the next 14 days.")
        } else {
            var lines: [String] = []
            for m in upcoming.prefix(20) {
                let days = calendar.dateComponents([.day], from: today, to: m.date).day ?? 0
                let when = days == 0 ? "TODAY" : (days == 1 ? "tomorrow" : "in \(days) days")
                lines.append("- \(f.string(from: m.date)) (\(when)): \(m.title)"
                             + (m.kind == .habit ? (m.completed ? " [task, done]" : " [task, not done]") : ""))
            }
            for m in overdue {
                lines.append("- \(f.string(from: m.date)): \(m.title) [OVERDUE task]")
            }
            out.append("CALENDAR next 14 days:\n" + lines.joined(separator: "\n"))
        }

        // MARK: Progress

        let week = engine.period(lastDays: 7)
        let month = engine.period(lastDays: 30)
        func pct(_ value: Double?) -> String {
            guard let value else { return "n/a" }
            return "\(Int((value * 100).rounded()))%"
        }
        var progress = [
            "- last 7 days: \(pct(week.rate)) of scheduled items done, \(week.perfectDays) perfect day\(week.perfectDays == 1 ? "" : "s")",
            "- last 30 days: \(pct(month.rate)), active on \(month.activeDays) of \(month.trackedDays) tracked days"
        ]
        let rates = engine.weekdayRates(over: month)
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var scored: [(String, Double)] = []
        for (index, rate) in rates.enumerated() {
            if let rate, index < names.count { scored.append((names[index], rate)) }
        }
        if let best = scored.max(by: { $0.1 < $1.1 }), let worst = scored.min(by: { $0.1 < $1.1 }), best.0 != worst.0 {
            progress.append("- strongest weekday \(best.0) (\(pct(best.1))), weakest \(worst.0) (\(pct(worst.1)))")
        }
        let doneToday = engine.counts(on: today)
        progress.append("- today so far: \(doneToday.habits) habit tick\(doneToday.habits == 1 ? "" : "s"), \(doneToday.schedule) schedule task\(doneToday.schedule == 1 ? "" : "s")")
        out.append("PROGRESS:\n" + progress.joined(separator: "\n"))

        // MARK: GitHub

        if let user = github.user {
            var lines = ["- signed in as \(user.login)\(user.name.map { " (\($0))" } ?? "")"]
            if let repos = user.public_repos { lines.append("- \(repos) public repos, \(github.repos.count) visible to the app") }
            let recent = github.repos
                .sorted { ($0.updated_at ?? "") > ($1.updated_at ?? "") }
                .prefix(8)
                .map { "\($0.name)\($0.isPrivate ? " (private)" : "")" }
            if !recent.isEmpty { lines.append("- most recently updated: " + recent.joined(separator: ", ")) }
            if let year = github.contributionCache {
                lines.append("- \(year.total) contributions in the last year, \(year.currentStreak)-day current streak")
                if let fortnightAgo = calendar.date(byAdding: .day, value: -14, to: today) {
                    let last14 = year.weeks.flatMap { $0 }
                        .filter { $0.date <= now && $0.date > fortnightAgo }
                    let recentTotal = last14.reduce(0) { $0 + $1.count }
                    let activeDays = last14.filter { $0.count > 0 }.count
                    lines.append("- last 14 days: \(recentTotal) contributions across \(activeDays) day\(activeDays == 1 ? "" : "s")")
                }
            }
            out.append("GITHUB:\n" + lines.joined(separator: "\n"))
        } else {
            out.append("GITHUB: not connected in the app.")
        }

        // MARK: Material index

        let chunks = (try? context.fetchCount(FetchDescriptor<AIChunk>())) ?? 0
        out.append("SEARCHABLE MATERIAL: \(chunks) passage\(chunks == 1 ? "" : "s") indexed from uploaded files. Use search_material to read them.")

        out.append("JOURNAL: private — deliberately not shared with you.")

        return out.joined(separator: "\n\n")
    }
}
