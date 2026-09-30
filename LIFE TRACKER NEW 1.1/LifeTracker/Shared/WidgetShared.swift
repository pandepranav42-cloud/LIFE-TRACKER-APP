import Foundation

/// Data the app hands to its widgets through the shared App Group container.
/// Compiled into BOTH the app and the widget extension.
enum SharedStore {
    static let appGroup = "group.com.pranavpande.LifeTracker"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
    static var snapshotURL: URL? { containerURL?.appendingPathComponent("widget-snapshot.json") }
    static var timetableImageURL: URL? { containerURL?.appendingPathComponent("timetable.jpg") }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

struct WidgetSnapshot: Codable {
    struct Day: Codable, Hashable {
        var day: Int            // 1…31
        var date: Date
        var done: Int
        var due: Int
        var isToday: Bool
        var isFuture: Bool
        /// 0…1, nil when nothing was due.
        var rate: Double? { due == 0 ? nil : Double(done) / Double(due) }
    }
    struct Block: Codable, Hashable {
        var title: String
        var start: String       // "HH:mm"
        var end: String
        var colorHex: String
    }

    var generatedAt: Date
    var userName: String
    var monthStart: Date
    /// Weekday of the 1st (1 = Sunday … 7 = Saturday) for laying out the grid.
    var firstWeekday: Int
    var days: [Day]
    var todayDone: Int
    var todayTotal: Int
    var monthDone: Int
    var monthDue: Int
    var perfectDays: Int
    var activeDays: Int
    var todayBlocks: [Block]
    var hasTimetableImage: Bool

    var monthRate: Double? { monthDue == 0 ? nil : Double(monthDone) / Double(monthDue) }
}
