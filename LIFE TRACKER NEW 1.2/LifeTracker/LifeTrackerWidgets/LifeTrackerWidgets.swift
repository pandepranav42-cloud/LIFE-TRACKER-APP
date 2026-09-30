import WidgetKit
import SwiftUI
#if os(macOS)
import AppKit
typealias WidgetImage = NSImage
#else
import UIKit
typealias WidgetImage = UIImage
#endif

// MARK: - Bundle

@main
struct LifeTrackerWidgets: WidgetBundle {
    var body: some Widget {
        QuoteWidget()
        TimetableWidget()
        HabitsMonthWidget()
    }
}

// MARK: - Theme (matches the app: cream, latte, cocoa)

struct WTheme {
    let scheme: ColorScheme
    var bgTop: Color    { scheme == .dark ? Color(hex: "241F1B") : Color(hex: "FFFBF3") }
    var bgBottom: Color { scheme == .dark ? Color(hex: "1A1714") : Color(hex: "F6EDDD") }
    var card: Color     { scheme == .dark ? Color(hex: "2E281F") : Color(hex: "F7EFDC") }
    var accent: Color   { scheme == .dark ? Color(hex: "D8B48E") : Color(hex: "8A6446") }
    var muted: Color    { scheme == .dark ? Color(hex: "A8957F") : Color(hex: "9A8573") }
    var empty: Color    { scheme == .dark ? Color(hex: "2A241E") : Color(hex: "EFE5D3") }

    var background: some View {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

extension Font {
    static func wMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Image {
    /// Keep photos in full colour when the widget is shown clear / tinted.
    @ViewBuilder
    func keepFullColorWhenTinted() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            self.widgetAccentedRenderingMode(.fullColor)
        } else {
            self
        }
    }
}

/// Small section label used at the top of every widget ("-quote", "-habits").
struct WLabel: View {
    let text: String
    let icon: String
    let theme: WTheme
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.wMono(10, .bold)).italic()
        }
        .foregroundStyle(theme.accent)
        .widgetAccentable()
    }
}

// MARK: - 1. Quote widget

struct QuoteEntry: TimelineEntry {
    let date: Date
    let quote: QuoteBank.Quote
}

struct QuoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuoteEntry {
        QuoteEntry(date: .now, quote: QuoteBank.quote(at: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (QuoteEntry) -> Void) {
        completion(placeholder(in: context))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuoteEntry>) -> Void) {
        // Same rotation as the app's Today page: a new quote every 30 minutes.
        let step = TimeInterval(QuoteBank.rotationMinutes * 60)
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / step) * step)
        let entries = (0..<24).map { i -> QuoteEntry in
            let d = start.addingTimeInterval(Double(i) * step)
            return QuoteEntry(date: d, quote: QuoteBank.quote(at: d.addingTimeInterval(1)))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct QuoteWidgetView: View {
    let entry: QuoteEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let t = WTheme(scheme: scheme)
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 10) {
            WLabel(text: "-quote", icon: "heart.fill", theme: t)
            Spacer(minLength: 0)
            Text(entry.quote.text)
                .font(.wMono(fontSize, .medium))
                .italic()
                .lineSpacing(2)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.primary)
            Text(entry.quote.author.uppercased())
                .font(.wMono(9, .bold))
                .tracking(0.8)
                .foregroundStyle(t.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { t.background }
    }

    private var fontSize: CGFloat {
        switch family {
        case .systemSmall: return 12
        case .systemMedium: return 14
        default: return 18
        }
    }
}

struct QuoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LifeTrackerQuote", provider: QuoteProvider()) { entry in
            QuoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Quote")
        .description("A new quote every 30 minutes, same as your Today page.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Shared snapshot provider

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let timetableImage: WidgetImage?
}

struct SnapshotProvider: TimelineProvider {
    var loadImage = false

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: nil, timetableImage: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app reloads widgets whenever you change something; also refresh
        // just after midnight so "today" rolls over.
        let cal = Calendar.current
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [current()], policy: .after(midnight.addingTimeInterval(60))))
    }

    private func current() -> SnapshotEntry {
        var image: WidgetImage?
        if loadImage, let url = SharedStore.timetableImageURL, FileManager.default.fileExists(atPath: url.path) {
            image = WidgetImage(contentsOfFile: url.path)
        }
        return SnapshotEntry(date: .now, snapshot: SharedStore.read(), timetableImage: image)
    }
}

struct EmptyWidgetMessage: View {
    let icon: String
    let text: String
    let theme: WTheme
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(theme.accent)
                .widgetAccentable()
            Text(text)
                .font(.wMono(10))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 2. Timetable widget

struct TimetableWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let t = WTheme(scheme: scheme)
        Group {
            if let img = entry.timetableImage {
                // Your timetable picture, edge to edge.
                ZStack(alignment: .topLeading) {
                    Image(platformImage: img)
                        .resizable()
                        .keepFullColorWhenTinted()
                        .aspectRatio(contentMode: family == .systemSmall ? .fill : .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: family == .systemSmall ? 0 : 12, style: .continuous))
                        .padding(family == .systemSmall ? 0 : 8)
                    if family != .systemSmall {
                        WLabel(text: "-timetable", icon: "square.grid.3x3", theme: t)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
            } else if let s = entry.snapshot, !s.todayBlocks.isEmpty {
                todayList(s, t).padding(14)
            } else {
                EmptyWidgetMessage(icon: "square.grid.3x3",
                                   text: entry.snapshot == nil
                                       ? "Open LifeTracker once to set up this widget."
                                       : "Upload your timetable picture in LifeTracker → Timetable.",
                                   theme: t)
                    .padding(14)
            }
        }
        .containerBackground(for: .widget) { t.background }
    }

    private func todayList(_ s: WidgetSnapshot, _ t: WTheme) -> some View {
        let max = family == .systemLarge ? 9 : (family == .systemMedium ? 4 : 3)
        return VStack(alignment: .leading, spacing: 6) {
            WLabel(text: "-today", icon: "square.grid.3x3", theme: t)
            ForEach(Array(s.todayBlocks.prefix(max).enumerated()), id: \.offset) { _, b in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: b.colorHex)).frame(width: 3)
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.title).font(.wMono(11, .semibold)).lineLimit(1)
                        Text("\(b.start)–\(b.end)").font(.wMono(9)).foregroundStyle(t.muted)
                    }
                }
                .frame(height: 26)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension Image {
    init(platformImage: WidgetImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

struct TimetableWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LifeTrackerTimetable", provider: SnapshotProvider(loadImage: true)) { entry in
            TimetableWidgetView(entry: entry)
        }
        .configurationDisplayName("Timetable")
        .description("Your timetable picture — or today's blocks if you use the grid.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - 3. Habits this month

struct HabitsMonthView: View {
    let entry: SnapshotEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let t = WTheme(scheme: scheme)
        Group {
            if let s = entry.snapshot {
                switch family {
                case .systemSmall: small(s, t)
                case .systemMedium: medium(s, t)
                default: large(s, t)
                }
            } else {
                EmptyWidgetMessage(icon: "checklist", text: "Open LifeTracker once to set up this widget.", theme: t)
            }
        }
        .containerBackground(for: .widget) { t.background }
    }

    // Small: today's ring + month %
    private func small(_ s: WidgetSnapshot, _ t: WTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WLabel(text: "-habits", icon: "checklist", theme: t)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                ZStack {
                    Circle().stroke(t.empty, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: s.todayTotal == 0 ? 0 : CGFloat(s.todayDone) / CGFloat(s.todayTotal))
                        .stroke(t.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .widgetAccentable()
                    VStack(spacing: 0) {
                        Text("\(s.todayDone)/\(s.todayTotal)").font(.wMono(15, .bold))
                        Text("today").font(.wMono(8)).foregroundStyle(t.muted)
                    }
                }
                .frame(width: 74, height: 74)
                Spacer()
            }
            Spacer(minLength: 0)
            Text("\(monthName(s)) · \(percent(s.monthRate))")
                .font(.wMono(10, .semibold))
                .foregroundStyle(t.muted)
                .frame(maxWidth: .infinity)
        }
    }

    // Medium: stats + month grid
    private func medium(_ s: WidgetSnapshot, _ t: WTheme) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                WLabel(text: "-habits", icon: "checklist", theme: t)
                Text(monthName(s)).font(.wMono(15, .bold))
                Spacer(minLength: 0)
                Text(percent(s.monthRate)).font(.wMono(26, .bold)).widgetAccentable()
                Text("of habits done").font(.wMono(9)).foregroundStyle(t.muted)
                Spacer(minLength: 0)
                Text("\(s.perfectDays) perfect · \(s.activeDays) active")
                    .font(.wMono(9)).foregroundStyle(t.muted).lineLimit(1).minimumScaleFactor(0.7)
            }
            grid(s, t, cell: 12, spacing: 3, showNumbers: false)
        }
    }

    // Large: full month grid with day numbers
    private func large(_ s: WidgetSnapshot, _ t: WTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    WLabel(text: "-habits this month", icon: "checklist", theme: t)
                    Text(monthName(s)).font(.wMono(18, .bold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(percent(s.monthRate)).font(.wMono(24, .bold)).widgetAccentable()
                    Text("\(s.monthDone) of \(s.monthDue) done").font(.wMono(9)).foregroundStyle(t.muted)
                }
            }
            grid(s, t, cell: 30, spacing: 5, showNumbers: true)
                .frame(maxWidth: .infinity)
            HStack {
                stat("\(s.todayDone)/\(s.todayTotal)", "today", t)
                Spacer()
                stat("\(s.perfectDays)", "perfect days", t)
                Spacer()
                stat("\(s.activeDays)", "active days", t)
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ t: WTheme) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.wMono(14, .bold))
            Text(label).font(.wMono(8)).foregroundStyle(t.muted)
        }
    }

    private func grid(_ s: WidgetSnapshot, _ t: WTheme, cell: CGFloat, spacing: CGFloat, showNumbers: Bool) -> some View {
        let lead = Array(repeating: WidgetSnapshot.Day?.none, count: max(0, s.firstWeekday - 1))
        let cells: [WidgetSnapshot.Day?] = lead + s.days.map { Optional($0) }
        let rows = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        return VStack(spacing: spacing) {
            if showNumbers {
                HStack(spacing: spacing) {
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, l in
                        Text(l).font(.wMono(8, .semibold)).foregroundStyle(t.muted).frame(width: cell)
                    }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { i in
                        if i < row.count, let d = row[i] {
                            dayCell(d, t, size: cell, showNumber: showNumbers)
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ d: WidgetSnapshot.Day, _ t: WTheme, size: CGFloat, showNumber: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        let filled = !d.isFuture && (d.rate ?? 0) > 0
        ZStack {
            if filled {
                shape.fill(t.accent.opacity(0.25 + 0.75 * (d.rate ?? 0)))
                    .widgetAccentable()
            } else {
                shape.fill(d.isFuture ? Color.clear : t.empty)
                shape.strokeBorder(d.isFuture ? t.empty : Color.clear, lineWidth: 1)
            }
            if d.isToday {
                shape.strokeBorder(t.accent, lineWidth: 1.5)
            }
            if showNumber {
                Text("\(d.day)")
                    .font(.wMono(9, d.isToday ? .bold : .regular))
                    .foregroundStyle(filled && (d.rate ?? 0) > 0.6 && renderingMode == .fullColor ? Color.white : t.muted)
            }
        }
        .frame(width: size, height: size)
    }

    private func monthName(_ s: WidgetSnapshot) -> String {
        s.monthStart.formatted(.dateTime.month(.wide))
    }
    private func percent(_ r: Double?) -> String {
        r.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}

struct HabitsMonthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LifeTrackerHabitsMonth", provider: SnapshotProvider()) { entry in
            HabitsMonthView(entry: entry)
        }
        .configurationDisplayName("Habits this month")
        .description("How consistent you've been this month, day by day.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
