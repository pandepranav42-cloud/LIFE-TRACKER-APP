import Foundation
import SwiftUI
import UserNotifications

/// Local notifications for schedule items — "⏰ Maths lecture starts at 9:00".
/// Scheduled on each device (Mac and iPad) from the schedule stored there,
/// repeating every day at the item's time (or a few minutes before).
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    @Published private(set) var pendingCount = 0

    private let prefix = "schedule."
    private override init() { super.init() }

    /// Call once at launch.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshStatus() }
    }

    @MainActor
    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        pendingCount = await UNUserNotificationCenter.current().pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(prefix) }.count
    }

    @MainActor
    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        return granted
    }

    /// Plain copy of what we need from a ScheduleItem (safe to hand to async code).
    struct Reminder {
        let title: String
        let start: Date
        let end: Date
        let lead: Int
        let category: String
    }

    /// Replaces all schedule notifications with the current set.
    @MainActor
    func reschedule(_ reminders: [Reminder], enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: existing)

        await refreshStatus()
        guard enabled, status == .authorized || status == .provisional else { return }

        let cal = Calendar.current
        let timeFmt = Date.FormatStyle(date: .omitted, time: .shortened)
        // iOS keeps at most 64 pending requests — plenty for a daily schedule.
        for (i, r) in reminders.prefix(60).enumerated() {
            guard let fire = cal.date(byAdding: .minute, value: -r.lead, to: r.start) else { continue }
            var comps = cal.dateComponents([.hour, .minute], from: fire)
            comps.second = 0

            let content = UNMutableNotificationContent()
            content.title = "⏰ \(r.title)"
            content.body = r.lead == 0
                ? "Starts now · until \(r.end.formatted(timeFmt))"
                : "Starts in \(Self.leadText(r.lead)) · \(r.start.formatted(timeFmt))–\(r.end.formatted(timeFmt))"
            content.subtitle = r.category
            content.sound = .default
            content.threadIdentifier = "schedule"

            let request = UNNotificationRequest(identifier: "\(prefix)\(i)",
                                                content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true))
            try? await center.add(request)
        }
        await refreshStatus()
    }

    private static func leadText(_ m: Int) -> String {
        m >= 60 ? "\(m / 60) hour\(m >= 120 ? "s" : "")" : "\(m) min"
    }

    // Show banners even while LifeTracker is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
