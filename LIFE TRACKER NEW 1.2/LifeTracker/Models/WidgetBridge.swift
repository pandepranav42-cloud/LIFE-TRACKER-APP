import Foundation
import SwiftUI
import SwiftData
import WidgetKit
import ImageIO
import UniformTypeIdentifiers

/// Keeps the widgets and the schedule notifications up to date. Runs quietly
/// in the background whenever data is saved, the app opens, or it goes to the
/// background — nothing about widgets is shown inside the app itself.
final class BackgroundCoordinator {
    static let shared = BackgroundCoordinator()
    private var pending: Task<Void, Never>?
    private init() {}

    /// Debounced: many quick saves → one refresh.
    @MainActor
    func scheduleRefresh(_ context: ModelContext, after seconds: Double = 1.2) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await refreshNow(context)
        }
    }

    @MainActor
    func refreshNow(_ context: ModelContext) async {
        WidgetBridge.update(context: context)

        let items = (try? context.fetch(FetchDescriptor<ScheduleItem>())) ?? []
        let reminders = items.filter(\.reminderEnabled).map {
            NotificationManager.Reminder(title: $0.title, start: $0.startTime, end: $0.endTime,
                                         lead: $0.reminderLeadMinutes ?? 0, category: $0.category)
        }
        let enabled = (UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool) ?? true
        await NotificationManager.shared.reschedule(reminders, enabled: enabled)
    }
}

enum WidgetBridge {
    @MainActor
    static func update(context: ModelContext) {
        guard SharedStore.containerURL != nil else { return }   // App Group not set up yet
        let cal = Calendar.current
        let now = Date()
        let habits = (try? context.fetch(FetchDescriptor<Habit>())) ?? []
        let marks = (try? context.fetch(FetchDescriptor<CalendarMark>())) ?? []
        let engine = ProgressEngine(habits: habits, marks: marks, calendar: cal, now: now)

        // Month grid
        let monthInterval = cal.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 86400)
        let count = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        var days: [WidgetSnapshot.Day] = []
        var monthDone = 0, monthDue = 0, perfect = 0, active = 0
        for i in 0..<count {
            guard let d = cal.date(byAdding: .day, value: i, to: monthInterval.start) else { continue }
            let p = engine.day(d)
            let isToday = cal.isDateInToday(d)
            let isFuture = d > engine.today
            let due = isToday ? p.completed + p.pending : p.scheduled
            days.append(.init(day: i + 1, date: d, done: p.completed, due: due, isToday: isToday, isFuture: isFuture))
            if !isFuture {
                monthDone += p.completed
                monthDue += p.scheduled          // today counts only what's done (same rule as Progress)
                if p.isPerfect { perfect += 1 }
                if p.completed > 0 { active += 1 }
            }
        }
        let today = engine.day(now)

        // Today's timetable blocks (1 = Monday … 7 = Sunday)
        let todayIndex = (cal.component(.weekday, from: now) + 5) % 7 + 1
        let blocks = ((try? context.fetch(FetchDescriptor<TimetableBlock>())) ?? [])
            .filter { $0.day == todayIndex }
            .sorted { $0.startTime < $1.startTime }
        let categories = (try? context.fetch(FetchDescriptor<TimetableCategory>())) ?? []
        let todayBlocks = blocks.map { b in
            WidgetSnapshot.Block(title: b.title, start: b.startTime, end: b.endTime,
                                 colorHex: categories.first { $0.id == b.categoryID }?.colorHex ?? "C4A27F")
        }

        let hasImage = exportTimetableImage(context: context)

        let snapshot = WidgetSnapshot(
            generatedAt: now,
            userName: UserDefaults.standard.string(forKey: "userName") ?? "",
            monthStart: monthInterval.start,
            firstWeekday: cal.component(.weekday, from: monthInterval.start),
            days: days,
            todayDone: today.completed,
            todayTotal: today.completed + today.pending,
            monthDone: monthDone,
            monthDue: monthDue,
            perfectDays: perfect,
            activeDays: active,
            todayBlocks: todayBlocks,
            hasTimetableImage: hasImage)
        SharedStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Writes a widget-sized copy of the timetable picture (only when it changed).
    @MainActor
    private static func exportTimetableImage(context: ModelContext) -> Bool {
        guard let url = SharedStore.timetableImageURL else { return false }
        guard let asset = ((try? context.fetch(FetchDescriptor<TimetableImageAsset>())) ?? []).first else {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: "widget.timetableFP")
            return false
        }
        let fingerprint = "\(asset.id.uuidString)-\(asset.imageData.count)"
        if UserDefaults.standard.string(forKey: "widget.timetableFP") == fingerprint,
           FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        guard let src = CGImageSourceCreateWithData(asset.imageData as CFData, nil) else { return false }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1100,      // widgets have a small memory budget
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        UserDefaults.standard.set(fingerprint, forKey: "widget.timetableFP")
        return true
    }
}
