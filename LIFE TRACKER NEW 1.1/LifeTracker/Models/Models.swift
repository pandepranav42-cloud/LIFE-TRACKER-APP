import Foundation
import SwiftData

enum HabitFrequency: String, Codable, CaseIterable, Identifiable {
    case daily, weekdays, weekends, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily: return "Every day"
        case .weekdays: return "Weekdays"
        case .weekends: return "Weekends"
        case .custom: return "Custom"
        }
    }
}

@Model
final class Habit {
    var name: String
    var iconName: String
    var frequencyRaw: String
    /// For .custom — weekday numbers (1 = Sun … 7 = Sat, matching Calendar.component(.weekday:))
    var customWeekdays: [Int]
    var startDate: Date
    var isPaused: Bool
    var sortIndex: Int
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \HabitCompletion.habit)
    var completions: [HabitCompletion] = []

    init(name: String,
         iconName: String = "circle",
         frequency: HabitFrequency = .daily,
         customWeekdays: [Int] = [],
         startDate: Date = .now,
         sortIndex: Int = 0) {
        self.name = name
        self.iconName = iconName
        self.frequencyRaw = frequency.rawValue
        self.customWeekdays = customWeekdays
        self.startDate = startDate
        self.isPaused = false
        self.sortIndex = sortIndex
        self.createdAt = .now
    }

    var frequency: HabitFrequency {
        get { HabitFrequency(rawValue: frequencyRaw) ?? .daily }
        set { frequencyRaw = newValue.rawValue }
    }

    /// Pause history as alternating timestamps: [pause, resume, pause, resume, …].
    /// An odd count means the habit is paused right now. Optional so existing
    /// stores migrate automatically.
    var pauseLog: [Date]? = nil

    /// Whether the habit is scheduled on the given day.
    /// Days that fall inside a pause period are not scheduled, but days before
    /// the pause still count — so pausing never erases past progress.
    func isScheduled(on date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        if day < calendar.startOfDay(for: startDate) { return false }
        if isPausedOn(day, calendar: calendar) { return false }
        let weekday = calendar.component(.weekday, from: day) // 1 Sun ... 7 Sat
        switch frequency {
        case .daily: return true
        case .weekdays: return (2...6).contains(weekday)
        case .weekends: return weekday == 1 || weekday == 7
        case .custom: return customWeekdays.contains(weekday)
        }
    }

    private func isPausedOn(_ day: Date, calendar: Calendar) -> Bool {
        let log = pauseLog ?? []
        // Legacy data: paused before pause history existed — treat as paused throughout.
        if log.isEmpty { return isPaused }
        var i = 0
        while i < log.count {
            let from = calendar.startOfDay(for: log[i])
            let to: Date? = i + 1 < log.count ? calendar.startOfDay(for: log[i + 1]) : nil
            if day >= from && (to == nil || day < to!) { return true }
            i += 2
        }
        return false
    }

    func pause(at date: Date = .now) {
        guard !isPaused else { return }
        isPaused = true
        var log = pauseLog ?? []
        if log.count % 2 == 1 { log.removeLast() }
        log.append(date)
        pauseLog = log
    }

    func resume(at date: Date = .now) {
        guard isPaused else { return }
        isPaused = false
        var log = pauseLog ?? []
        if log.count % 2 == 1 { log.append(date) }
        pauseLog = log
    }

    func isCompleted(on date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return completions.contains { calendar.isDate($0.date, inSameDayAs: day) }
    }
}

@Model
final class HabitCompletion {
    var date: Date
    var habit: Habit?
    /// The exact moment it was ticked (nil for ticks made before this was tracked).
    var completedAt: Date?

    init(date: Date, habit: Habit? = nil, completedAt: Date? = .now) {
        self.date = Calendar.current.startOfDay(for: date)
        self.habit = habit
        self.completedAt = completedAt
    }
}

@Model
final class ScheduleItem {
    var title: String
    var startTime: Date        // Only hour/minute components used
    var endTime: Date
    var category: String
    var notes: String
    var reminderEnabled: Bool
    var sortIndex: Int
    var colorHex: String
    /// Minutes before the start to notify (nil = at start time).
    var reminderLeadMinutes: Int?

    /// Days this schedule item was ticked off. Nullify keeps the history
    /// (with its title snapshot) even if the item is later deleted.
    @Relationship(deleteRule: .nullify, inverse: \ScheduleCompletion.item)
    var completions: [ScheduleCompletion] = []

    func completion(on date: Date, calendar: Calendar = .current) -> ScheduleCompletion? {
        completions.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    init(title: String,
         startTime: Date,
         endTime: Date,
         category: String = "General",
         notes: String = "",
         reminderEnabled: Bool = false,
         sortIndex: Int = 0,
         colorHex: String = "B7C4D6") {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.category = category
        self.notes = notes
        self.reminderEnabled = reminderEnabled
        self.sortIndex = sortIndex
        self.colorHex = colorHex
    }
}

/// One schedule item done on one day, with the time it was ticked.
@Model
final class ScheduleCompletion {
    var date: Date          // startOfDay
    var completedAt: Date
    var title: String       // snapshot, so history survives renames/deletes
    var colorHex: String
    var item: ScheduleItem?

    init(item: ScheduleItem, date: Date, completedAt: Date = .now) {
        self.date = Calendar.current.startOfDay(for: date)
        self.completedAt = completedAt
        self.title = item.title
        self.colorHex = item.colorHex
        self.item = item
    }
}

/// User-defined timetable category. No fixed set — people add exactly the
/// categories that make sense for their week and pick a color per category.
@Model
final class TimetableCategory {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String     // e.g. "8AA6C9" — resolved to a muted fill/accent at render time
    var sortIndex: Int

    init(name: String, colorHex: String, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.sortIndex = sortIndex
    }
}

@Model
final class TimetableBlock {
    /// 1 = Monday … 7 = Sunday (ISO-style, differs from Calendar.weekday).
    var day: Int
    var startTime: String   // "HH:MM"
    var endTime: String     // "HH:MM"
    var title: String
    var categoryID: UUID?

    init(day: Int, startTime: String, endTime: String, title: String, categoryID: UUID?) {
        self.day = day
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.categoryID = categoryID
    }
}

/// Defines one row in the Timetable grid — just a time range, no content.
/// Kept separate from TimetableBlock so the grid can exist "empty" (just
/// borders) before any content is filled in.
@Model
final class TimetableSlot {
    @Attribute(.unique) var id: UUID
    var startTime: String   // "HH:MM"
    var endTime: String     // "HH:MM"

    init(startTime: String, endTime: String) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A single uploaded photo of a hand-made timetable, shown instead of the
/// interactive grid when present. Only one is expected at a time.
@Model
final class TimetableImageAsset {
    @Attribute(.unique) var id: UUID
    @Attribute(.externalStorage) var imageData: Data
    /// Google Drive backup copy (nil until uploaded).
    var driveFileID: String?

    init(imageData: Data) {
        self.id = UUID()
        self.imageData = imageData
    }
}

/// Whether a Calendar mark is a plain event (informational, shown on Today
/// with no tick) or a one-off habit tied to a specific day (shown on Today
/// with a tick, and counted in Progress once completed).
enum CalendarMarkKind: String, Codable {
    case event, habit
}

/// A user-marked "important date" — a colored note attached to a specific
/// day on the Calendar. Independent of habits/schedule; purely for the
/// person to flag things like exams, deadlines, anniversaries, or one-off
/// habits for a single day.
@Model
final class CalendarMark {
    @Attribute(.unique) var id: UUID
    var date: Date       // startOfDay
    var title: String
    var colorHex: String
    var kindRaw: String
    var completed: Bool
    /// When a one-off habit mark was ticked.
    var completedAt: Date?
    /// Identifier of the mirrored event in Apple Calendar (EventKit).
    var appleEventID: String?
    /// Identifier of the mirrored event in Google Calendar.
    var googleEventID: String?

    var kind: CalendarMarkKind {
        get { CalendarMarkKind(rawValue: kindRaw) ?? .event }
        set { kindRaw = newValue.rawValue }
    }

    init(date: Date, title: String, colorHex: String, kind: CalendarMarkKind = .event, completed: Bool = false) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.title = title
        self.colorHex = colorHex
        self.kindRaw = kind.rawValue
        self.completed = completed
    }
}

@Model
final class JournalEntry {
    /// Stored as the startOfDay for that day — one entry per day.
    var date: Date
    var title: String
    var text: String
    var mood: Int      // 1...5
    var energy: Int    // 1...5
    var savedAt: Date?
    var colorHex: String?

    init(date: Date, title: String = "", text: String = "", mood: Int = 3, energy: Int = 3, savedAt: Date? = nil, colorHex: String? = nil) {
        self.date = Calendar.current.startOfDay(for: date)
        self.title = title
        self.text = text
        self.mood = mood
        self.energy = energy
        self.savedAt = savedAt
        self.colorHex = colorHex
    }
}

// MARK: - Progress engine
//
// One place that computes every progress number in the app, so Today,
// Habits and Progress always agree. Rules:
//  • A habit only counts on days it was actually scheduled (frequency,
//    start date and pause periods respected).
//  • A completion on an unscheduled day never inflates the numbers.
//  • Calendar "habit" marks count as a one-off item on their own day.
//  • Today is still in progress, so its unfinished items are not counted
//    as misses — only what's been done so far is counted.
//  • Future days are never counted.

struct DayProgress: Identifiable {
    var id: Date { date }
    let date: Date
    let scheduled: Int
    let completed: Int
    let isToday: Bool
    /// Items still open today (always 0 for past days).
    let pending: Int
    var rate: Double? { scheduled == 0 ? nil : Double(completed) / Double(scheduled) }
    /// Every item that was due that day was done.
    var isPerfect: Bool { scheduled > 0 && completed == scheduled && pending == 0 }
}

struct HabitProgress: Identifiable {
    let id: ObjectIdentifier
    let name: String
    let iconName: String
    let scheduled: Int
    let completed: Int
    var rate: Double? { scheduled == 0 ? nil : Double(completed) / Double(scheduled) }
}

struct PeriodProgress {
    let days: [DayProgress]
    var scheduled: Int { days.reduce(0) { $0 + $1.scheduled } }
    var completed: Int { days.reduce(0) { $0 + $1.completed } }
    var rate: Double? { scheduled == 0 ? nil : Double(completed) / Double(scheduled) }
    var perfectDays: Int { days.filter(\.isPerfect).count }
    var activeDays: Int { days.filter { $0.completed > 0 }.count }
    var trackedDays: Int { days.filter { $0.scheduled > 0 || $0.pending > 0 }.count }
}

struct CompletionLogEntry: Identifiable {
    enum Kind: String { case habit, oneOff, schedule }
    let kind: Kind
    let title: String
    let icon: String
    let colorHex: String?
    let time: Date?
    /// Breaks a tie when the same thing is ticked twice in one second.
    var ordinal: Int = 0

    /// Built from what the entry *is*, not from a fresh UUID.
    ///
    /// This list is rebuilt from scratch on every redraw of the Progress page
    /// — and the page redraws on a timer, on any SwiftData change, and on
    /// every step of picking a day in the chart. With `let id = UUID()` each
    /// of those rebuilds handed SwiftUI a set of rows it had never seen, so
    /// it tore the old ones out and animated new ones in: the times showed
    /// for a moment and then vanished. A stable id makes the same tick the
    /// same row, and it simply stays put.
    var id: String {
        "\(kind.rawValue)|\(title)|\(time?.timeIntervalSince1970 ?? -1)|\(ordinal)"
    }
}

struct ProgressEngine {
    let habits: [Habit]
    let marks: [CalendarMark]
    let calendar: Calendar
    let now: Date

    private let doneDays: [ObjectIdentifier: Set<Date>]
    private let oneOffs: [Date: (total: Int, done: Int)]
    /// Schedule items ticked off, grouped by day.
    private let scheduleByDay: [Date: [ScheduleCompletion]]

    init(habits: [Habit], marks: [CalendarMark], scheduleDone: [ScheduleCompletion] = [],
         calendar: Calendar = .current, now: Date = .now) {
        self.scheduleByDay = Dictionary(grouping: scheduleDone) { calendar.startOfDay(for: $0.date) }
        self.habits = habits
        self.marks = marks
        self.calendar = calendar
        self.now = now
        var done: [ObjectIdentifier: Set<Date>] = [:]
        for h in habits {
            done[ObjectIdentifier(h)] = Set(h.completions.map { calendar.startOfDay(for: $0.date) })
        }
        self.doneDays = done
        var one: [Date: (total: Int, done: Int)] = [:]
        for m in marks where m.kind == .habit {
            let d = calendar.startOfDay(for: m.date)
            let cur = one[d] ?? (0, 0)
            one[d] = (cur.total + 1, cur.done + (m.completed ? 1 : 0))
        }
        self.oneOffs = one
    }

    var today: Date { calendar.startOfDay(for: now) }

    func isDone(_ habit: Habit, on day: Date) -> Bool {
        doneDays[ObjectIdentifier(habit)]?.contains(calendar.startOfDay(for: day)) ?? false
    }

    func day(_ date: Date) -> DayProgress {
        let d = calendar.startOfDay(for: date)
        let isToday = d == today
        if d > today {
            return DayProgress(date: d, scheduled: 0, completed: 0, isToday: false, pending: 0)
        }
        var due = 0, done = 0
        for h in habits where h.isScheduled(on: d, calendar: calendar) {
            due += 1
            if isDone(h, on: d) { done += 1 }
        }
        if let o = oneOffs[d] { due += o.total; done += o.done }
        if isToday {
            // Don't count today's open items as misses yet.
            return DayProgress(date: d, scheduled: done, completed: done, isToday: true, pending: due - done)
        }
        return DayProgress(date: d, scheduled: due, completed: done, isToday: false, pending: 0)
    }

    /// The `count` days ending today (oldest first).
    func lastDays(_ count: Int, endingDaysAgo offset: Int = 0) -> [Date] {
        (0..<count).reversed().compactMap {
            calendar.date(byAdding: .day, value: -($0 + offset), to: today)
        }
    }

    func period(lastDays count: Int, endingDaysAgo offset: Int = 0) -> PeriodProgress {
        PeriodProgress(days: lastDays(count, endingDaysAgo: offset).map { day($0) })
    }

    func period(from start: Date, to end: Date) -> PeriodProgress {
        var result: [DayProgress] = []
        var cursor = calendar.startOfDay(for: start)
        let last = min(calendar.startOfDay(for: end), today)
        while cursor <= last {
            result.append(day(cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return PeriodProgress(days: result)
    }

    func habitProgress(over days: [Date]) -> [HabitProgress] {
        habits.map { h in
            var due = 0, done = 0
            for d in days {
                let isToday = calendar.startOfDay(for: d) == today
                guard d <= today, h.isScheduled(on: d, calendar: calendar) else { continue }
                let completed = isDone(h, on: d)
                if isToday && !completed { continue } // today not over yet
                due += 1
                if completed { done += 1 }
            }
            return HabitProgress(id: ObjectIdentifier(h), name: h.name, iconName: h.iconName,
                                 scheduled: due, completed: done)
        }
    }

    // MARK: What was actually done (habits and schedule kept separate)

    /// Habits ticked (regular + one-off calendar habits) and schedule tasks
    /// ticked on a day. Only real ticks are counted — nothing is inferred.
    func counts(on date: Date) -> (habits: Int, schedule: Int) {
        let d = calendar.startOfDay(for: date)
        guard d <= today else { return (0, 0) }
        var h = habits.filter { isDone($0, on: d) }.count
        h += oneOffs[d]?.done ?? 0
        return (h, scheduleByDay[d]?.count ?? 0)
    }

    /// Totals per weekday over a period (index 0 = Monday … 6 = Sunday).
    func weekdayCounts(over period: PeriodProgress) -> [(habits: Int, schedule: Int)] {
        var result = Array(repeating: (habits: 0, schedule: 0), count: 7)
        for d in period.days {
            let idx = (calendar.component(.weekday, from: d.date) + 5) % 7
            let c = counts(on: d.date)
            result[idx].habits += c.habits
            result[idx].schedule += c.schedule
        }
        return result
    }

    /// Everything completed on a day, with the time it was ticked, oldest first.
    func log(on date: Date) -> [CompletionLogEntry] {
        let d = calendar.startOfDay(for: date)
        var out: [CompletionLogEntry] = []
        for h in habits {
            for c in h.completions where calendar.isDate(c.date, inSameDayAs: d) {
                out.append(.init(kind: .habit, title: h.name, icon: h.iconName, colorHex: nil, time: c.completedAt))
            }
        }
        for m in marks where m.kind == .habit && m.completed && calendar.isDate(m.date, inSameDayAs: d) {
            out.append(.init(kind: .oneOff, title: m.title, icon: "calendar", colorHex: m.colorHex, time: m.completedAt))
        }
        for s in scheduleByDay[d] ?? [] {
            out.append(.init(kind: .schedule, title: s.title, icon: "clock", colorHex: s.colorHex, time: s.completedAt))
        }
        let sorted = out.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
        return sorted.enumerated().map { index, entry in
            var numbered = entry
            numbered.ordinal = index
            return numbered
        }
    }

    /// Average completion rate per weekday (index 0 = Monday … 6 = Sunday).
    func weekdayRates(over period: PeriodProgress) -> [Double?] {
        var due = Array(repeating: 0, count: 7), done = Array(repeating: 0, count: 7)
        for d in period.days where !d.isToday {
            let wd = calendar.component(.weekday, from: d.date) // 1 Sun … 7 Sat
            let idx = (wd + 5) % 7                               // Mon = 0
            due[idx] += d.scheduled
            done[idx] += d.completed
        }
        return (0..<7).map { due[$0] == 0 ? nil : Double(done[$0]) / Double(due[$0]) }
    }
}

// MARK: - University portals

/// A university portal you added yourself.
///
/// LifeTracker ships with none. The University page starts empty with an Add
/// button, and whichever ERP your college runs — JUNO, ERP, Samarth, Moodle,
/// anything with a login page — becomes one of these. Each keeps its own
/// cookies (the web view separates them by host) and its own saved logins.
@Model
final class UniPortal {
    @Attribute(.unique) var id: UUID
    var name: String
    var urlString: String
    var colorHex: String
    var iconName: String
    var sortIndex: Int
    var addedAt: Date
    /// Used to put the one you actually use at the top.
    var lastOpenedAt: Date?

    init(name: String, urlString: String, colorHex: String = "D9B38C",
         iconName: String = "graduationcap.fill", sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.urlString = urlString
        self.colorHex = colorHex
        self.iconName = iconName
        self.sortIndex = sortIndex
        self.addedAt = .now
    }

    var url: URL? { URL(string: urlString) }

    /// What the saved logins and the cookie jar are keyed on.
    var host: String {
        (url?.host ?? "").replacingOccurrences(of: "www.", with: "")
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? (host.isEmpty ? "Portal" : host) : name
    }
}

/// Icons offered when adding a portal — no logos, just plain signifiers.
enum PortalIcons {
    static let all = ["graduationcap.fill", "building.columns.fill", "book.closed.fill",
                      "globe", "person.text.rectangle.fill", "doc.text.fill",
                      "chart.bar.doc.horizontal.fill", "studentdesk"]
}

// MARK: - Study

/// A class / subject in the Study space. Holds its own syllabus, notes and
/// uploaded study material (PDF, PowerPoint, Word, …).
@Model
final class StudySubject {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var colorHex: String
    var teacher: String
    var time: String
    var section: String
    var notes: String
    var sortIndex: Int
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SyllabusTopic.subject)
    var topics: [SyllabusTopic] = []

    @Relationship(deleteRule: .cascade, inverse: \StudyMaterial.subject)
    var materials: [StudyMaterial] = []

    @Relationship(deleteRule: .cascade, inverse: \StudyLink.subject)
    var links: [StudyLink] = []

    init(name: String, emoji: String = "📘", colorHex: String = "D9C2A7",
         teacher: String = "", time: String = "", section: String = "",
         sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.teacher = teacher
        self.time = time
        self.section = section
        self.notes = ""
        self.sortIndex = sortIndex
        self.createdAt = .now
    }

    var sortedTopics: [SyllabusTopic] { topics.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) } }
    var syllabusProgress: Double {
        topics.isEmpty ? 0 : Double(topics.filter(\.isDone).count) / Double(topics.count)
    }
}

@Model
final class SyllabusTopic {
    var title: String
    var isDone: Bool
    var sortIndex: Int
    var createdAt: Date
    var subject: StudySubject?

    init(title: String, sortIndex: Int = 0, subject: StudySubject? = nil) {
        self.title = title
        self.isDone = false
        self.sortIndex = sortIndex
        self.createdAt = .now
        self.subject = subject
    }
}

/// An uploaded study file. The bytes live in SwiftData external storage, so
/// the material stays with the app even if the original file is moved.
@Model
final class StudyMaterial {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var fileExtension: String
    @Attribute(.externalStorage) var data: Data
    var byteCount: Int
    var addedAt: Date
    var subject: StudySubject?
    /// Google Drive backup copy (nil until uploaded).
    var driveFileID: String?

    init(fileName: String, fileExtension: String, data: Data, subject: StudySubject? = nil) {
        self.id = UUID()
        self.fileName = fileName
        self.fileExtension = fileExtension.lowercased()
        self.data = data
        self.byteCount = data.count
        self.addedAt = .now
        self.subject = subject
    }
}

/// A saved link for a subject — a YouTube video or any website.
@Model
final class StudyLink {
    @Attribute(.unique) var id: UUID
    var urlString: String
    var title: String
    var note: String
    var addedAt: Date
    var subject: StudySubject?

    init(url: URL, title: String, subject: StudySubject? = nil) {
        self.id = UUID()
        self.urlString = url.absoluteString
        self.title = title
        self.note = ""
        self.addedAt = .now
        self.subject = subject
    }

    var url: URL? { URL(string: urlString) }
    var host: String { url?.host?.replacingOccurrences(of: "www.", with: "") ?? urlString }

    /// YouTube video id for youtube.com/watch?v=, youtu.be/, /shorts/, /embed/ and /live/ links.
    var youTubeID: String? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("youtu.be") {
            let id = url.pathComponents.dropFirst().first
            return id?.isEmpty == false ? id : nil
        }
        guard host.contains("youtube.com") else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        let parts = url.pathComponents
        if let i = parts.firstIndex(where: { ["shorts", "embed", "live"].contains($0) }), i + 1 < parts.count {
            return parts[i + 1]
        }
        return nil
    }
    var isYouTube: Bool { youTubeID != nil }

    /// What kind of link this is — used for the icon, label and filters.
    var kind: StudyLinkKind { StudyLinkKind.of(urlString, isYouTube: isYouTube) }
}

/// Every link is welcome: videos, cloud files, docs, code, app links, mail…
enum StudyLinkKind: String, CaseIterable, Identifiable {
    case video, drive, document, code, social, mail, app, website
    var id: String { rawValue }

    static func of(_ urlString: String, isYouTube: Bool) -> StudyLinkKind {
        if isYouTube { return .video }
        let url = URL(string: urlString)
        let scheme = (url?.scheme ?? "https").lowercased()
        let host = (url?.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        if scheme == "mailto" { return .mail }
        if !["http", "https", "ftp", "ftps", "file"].contains(scheme) { return .app }
        if host.contains("drive.google") || host.contains("docs.google") || host.contains("dropbox")
            || host.contains("onedrive") || host.contains("1drv.ms") || host.contains("icloud")
            || host.contains("mega.nz") || host.contains("box.com") || host.contains("wetransfer") {
            return .drive
        }
        if ["youtu.be", "vimeo.com", "dailymotion.com", "twitch.tv", "coursera.org", "udemy.com",
            "khanacademy.org", "nptel.ac.in", "ted.com"].contains(where: { host.contains($0) }) { return .video }
        if ["github.com", "gitlab.com", "stackoverflow.com", "stackexchange.com", "leetcode.com",
            "kaggle.com", "colab.research.google.com", "replit.com", "codepen.io"].contains(where: { host.contains($0) }) { return .code }
        if ["notion.so", "notion.site", "medium.com", "wikipedia.org", "scholar.google", "arxiv.org",
            "researchgate.net", "jstor.org", "slideshare.net", "academia.edu"].contains(where: { host.contains($0) }) { return .document }
        if ["instagram.com", "x.com", "twitter.com", "linkedin.com", "reddit.com", "facebook.com",
            "discord.", "t.me", "whatsapp.com", "pinterest."].contains(where: { host.contains($0) }) { return .social }
        return .website
    }

    var title: String {
        switch self {
        case .video: return "Video"
        case .drive: return "Cloud file"
        case .document: return "Reading"
        case .code: return "Code"
        case .social: return "Social"
        case .mail: return "Email"
        case .app: return "App link"
        case .website: return "Website"
        }
    }
    var icon: String {
        switch self {
        case .video: return "play.rectangle.fill"
        case .drive: return "externaldrive.fill.badge.icloud"
        case .document: return "doc.text.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .social: return "bubble.left.and.bubble.right.fill"
        case .mail: return "envelope.fill"
        case .app: return "app.badge"
        case .website: return "globe"
        }
    }
    var colorHex: String {
        switch self {
        case .video: return "D2453F"
        case .drive: return "2E9E5B"
        case .document: return "3B6FD8"
        case .code: return "7A5CC6"
        case .social: return "C2567A"
        case .mail: return "E07B39"
        case .app: return "8A6446"
        case .website: return "7F9AB5"
        }
    }
}

/// Weekly to-do item (day 1 = Monday … 7 = Sunday) or a reminder (day 0).
@Model
final class StudyTodo {
    var title: String
    var day: Int
    var isDone: Bool
    var createdAt: Date

    init(title: String, day: Int) {
        self.title = title
        self.day = day
        self.isDone = false
        self.createdAt = .now
    }
}

@Model
final class MoodBoardImage {
    @Attribute(.unique) var id: UUID
    @Attribute(.externalStorage) var data: Data
    var addedAt: Date
    /// true = the Study page banner image rather than a mood-board tile.
    var isCover: Bool
    /// Google Drive backup copy (nil until uploaded).
    var driveFileID: String?

    init(data: Data, isCover: Bool = false) {
        self.id = UUID()
        self.data = data
        self.addedAt = .now
        self.isCover = isCover
    }
}
