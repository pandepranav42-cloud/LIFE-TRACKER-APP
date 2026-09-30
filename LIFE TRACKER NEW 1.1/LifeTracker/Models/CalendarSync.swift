import Foundation
import SwiftUI
import EventKit

/// A read-only event that lives in Apple Calendar (iCloud, Google, Exchange…
/// whatever accounts are set up on this Mac / iPad), shown on our Calendar page.
struct ExternalEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let isAllDay: Bool
    let calendarTitle: String
    let color: Color
}

/// Mirrors LifeTracker calendar marks to Apple Calendar and/or Google Calendar.
///
/// • Apple Calendar goes through EventKit, so it writes into any calendar the
///   system knows about — iCloud, and also Google/Exchange if those accounts
///   are added in System Settings → Internet Accounts.
/// • Google Calendar (direct) uses the Google account signed in under
///   Settings → Accounts and writes to your primary Google calendar.
final class CalendarSync: ObservableObject {
    static let shared = CalendarSync()

    let store = EKEventStore()

    @AppStorage("sync.apple.enabled") var appleEnabled: Bool = false { willSet { objectWillChange.send() } }
    @AppStorage("sync.apple.calendarID") var appleCalendarID: String = "" { willSet { objectWillChange.send() } }
    @AppStorage("sync.google.enabled") var googleEnabled: Bool = false { willSet { objectWillChange.send() } }

    @Published private(set) var status: String = ""
    @Published private(set) var isSyncing = false
    /// Bumped whenever Apple Calendar changes, so views reload external events.
    @Published private(set) var revision = 0

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in CalendarSync.shared.revision += 1 }
        }
    }

    // MARK: Apple Calendar access

    var hasAppleAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    @MainActor @discardableResult
    func requestAppleAccess() async -> Bool {
        if hasAppleAccess { return true }
        do {
            let granted = try await store.requestFullAccessToEvents()
            if !granted { status = "Calendar access denied — allow it in System Settings → Privacy & Security → Calendars." }
            revision += 1
            return granted
        } catch {
            status = "Calendar access failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Calendars we can write to, grouped by account (iCloud, Google, …).
    var writableCalendars: [EKCalendar] {
        guard hasAppleAccess else { return [] }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    /// The calendar marks go into: the one chosen in Settings, or a
    /// "LifeTracker" calendar created in the default account.
    @MainActor
    private func targetCalendar() throws -> EKCalendar {
        if !appleCalendarID.isEmpty, let cal = store.calendar(withIdentifier: appleCalendarID) {
            return cal
        }
        if let existing = store.calendars(for: .event).first(where: { $0.title == "LifeTracker" && $0.allowsContentModifications }) {
            appleCalendarID = existing.calendarIdentifier
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = "LifeTracker"
        cal.cgColor = Palette.platformColor("C4A27F").cgColor
        cal.source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .calDAV }
            ?? store.sources.first { $0.sourceType == .local }
        try store.saveCalendar(cal, commit: true)
        appleCalendarID = cal.calendarIdentifier
        return cal
    }

    // MARK: Push one mark

    /// Call after a mark is added or edited.
    /// Written into every event's notes so LifeTracker can still find and
    /// delete its own events when the saved identifier goes stale (which
    /// happens when the calendar resyncs, or the event moves account).
    static let tagPrefix = "LifeTracker-ID:"

    @MainActor
    func push(_ mark: CalendarMark) async {
        let title = displayTitle(for: mark)
        let notes = "Added from LifeTracker (\(mark.kind == .habit ? "one-off habit" : "event")).\n"
            + "\(Self.tagPrefix) \(mark.id.uuidString)"

        if appleEnabled, await requestAppleAccess() {
            do {
                let event = mark.appleEventID.flatMap { store.event(withIdentifier: $0) }
                    ?? EKEvent(eventStore: store)
                if event.calendar == nil { event.calendar = try targetCalendar() }
                event.title = title
                event.notes = notes
                event.isAllDay = true
                event.startDate = Calendar.current.startOfDay(for: mark.date)
                event.endDate = event.startDate
                try store.save(event, span: .thisEvent, commit: true)
                mark.appleEventID = event.eventIdentifier
            } catch {
                status = "Apple Calendar: \(error.localizedDescription)"
            }
        }

        if googleEnabled, AccountStore.shared.isGoogleSignedIn {
            do {
                mark.googleEventID = try await GoogleCalendarClient.upsert(existingID: mark.googleEventID,
                                                                          title: title, notes: notes, day: mark.date)
            } catch {
                status = "Google Calendar: \(error.localizedDescription)"
            }
        }
    }

    /// Call *before* deleting a mark locally (pass its ids). `markID` and `day`
    /// let it find the event by its LifeTracker tag when the stored identifier
    /// no longer resolves — without them a deleted item could linger in Apple
    /// Calendar forever.
    @MainActor
    func remove(appleID: String?, googleID: String?, markID: UUID? = nil, on day: Date? = nil) async {
        if hasAppleAccess {
            var removed = false
            if let appleID, let event = store.event(withIdentifier: appleID) {
                try? store.remove(event, span: .thisEvent, commit: true)
                removed = true
            }
            if !removed, let markID, let day {
                let calendar = Calendar.current
                let from = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: day)) ?? day
                let to = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: day)) ?? day
                let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
                for event in store.events(matching: predicate)
                where (event.notes ?? "").contains(markID.uuidString) {
                    try? store.remove(event, span: .thisEvent, commit: true)
                }
            }
            try? store.commit()
            revision += 1
        }
        if let googleID, AccountStore.shared.isGoogleSignedIn {
            try? await GoogleCalendarClient.delete(id: googleID)
        }
    }

    /// Used by "Reset all data": takes every event LifeTracker ever wrote out
    /// of Apple and Google Calendar, then removes the LifeTracker calendar
    /// itself if we created one. Call it *before* the database is wiped.
    @MainActor
    func removeEverything(_ marks: [CalendarMark]) async {
        for mark in marks {
            await remove(appleID: mark.appleEventID, googleID: mark.googleEventID,
                         markID: mark.id, on: mark.date)
        }

        guard hasAppleAccess else { return }

        // Sweep up anything whose id we lost — tagged events, and everything
        // sitting in the calendar we made. EventKit only allows a four-year
        // window per query, so walk it a year at a time.
        let calendar = Calendar.current
        var cursor = calendar.date(byAdding: .year, value: -3, to: .now) ?? .now
        let end = calendar.date(byAdding: .year, value: 3, to: .now) ?? .now
        while cursor < end {
            let next = min(calendar.date(byAdding: .year, value: 1, to: cursor) ?? end, end)
            let predicate = store.predicateForEvents(withStart: cursor, end: next, calendars: nil)
            for event in store.events(matching: predicate)
            where (event.notes ?? "").contains(Self.tagPrefix) || event.calendar.title == "LifeTracker" {
                try? store.remove(event, span: .thisEvent, commit: true)
            }
            cursor = next
        }
        try? store.commit()

        // Finally the calendar itself, if it's the one LifeTracker created.
        if let cal = store.calendar(withIdentifier: appleCalendarID),
           cal.title == "LifeTracker", cal.allowsContentModifications {
            try? store.removeCalendar(cal, commit: true)
            appleCalendarID = ""
        }
        revision += 1
    }

    /// Pushes every mark (used after turning sync on, or from "Sync now").
    @MainActor
    func syncAll(_ marks: [CalendarMark]) async {
        guard appleEnabled || googleEnabled else {
            status = "Turn on Apple or Google Calendar sync first."
            return
        }
        isSyncing = true
        status = "Syncing \(marks.count) item\(marks.count == 1 ? "" : "s")…"
        for m in marks { await push(m) }
        isSyncing = false
        if !status.hasPrefix("Apple Calendar:") && !status.hasPrefix("Google Calendar:") {
            status = "Synced \(marks.count) item\(marks.count == 1 ? "" : "s") · \(Date().formatted(date: .omitted, time: .shortened))"
        }
    }

    private func displayTitle(for mark: CalendarMark) -> String {
        if mark.kind == .habit { return (mark.completed ? "✓ " : "○ ") + mark.title }
        return mark.title
    }

    // MARK: Read Apple Calendar events (shown on our calendar)

    func externalEvents(from start: Date, to end: Date, excluding ownIDs: Set<String>) -> [ExternalEvent] {
        guard hasAppleAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !ownIDs.contains($0.eventIdentifier ?? "") && $0.calendar.title != "LifeTracker" }
            .map { e in
                ExternalEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                              title: e.title ?? "Untitled",
                              start: e.startDate,
                              isAllDay: e.isAllDay,
                              calendarTitle: e.calendar.title,
                              color: Color(cgColor: e.calendar.cgColor))
            }
            .sorted { $0.start < $1.start }
    }
}
