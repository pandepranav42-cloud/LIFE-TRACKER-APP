import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case today, habits, schedule, timetable, study, calendar, progress, journal, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Today"
        case .habits: "Habits"
        case .schedule: "Schedule"
        case .timetable: "Timetable"
        case .study: "Study"
        case .calendar: "Calendar"
        case .progress: "Progress"
        case .journal: "Journal"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .today: "sun.max"
        case .habits: "checklist"
        case .schedule: "clock"
        case .timetable: "square.grid.3x3"
        case .study: "books.vertical"
        case .calendar: "calendar"
        case .progress: "chart.bar"
        case .journal: "book.closed"
        case .settings: "gear"
        }
    }
}

struct ContentView: View {
    @State private var selection: AppSection? = .today
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            // Publish the live detail width so every page can adapt to Mac
            // window resizing and iPad full screen / Split View / Slide Over.
            GeometryReader { geo in
                page(for: selection ?? .today)
                    // Without a fresh identity per section, a page that has
                    // pushed something (Study → a subject, JUNO, GitHub) keeps
                    // that pushed screen on top when you pick another item in
                    // the sidebar — the sidebar moves, the detail doesn't.
                    .id(selection ?? .today)
                    .environment(\.layoutWidth, geo.size.width)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(Palette.surface.ignoresSafeArea())
            .blendedToolbar()
            .macMinSize(width: 560, height: 460)
        }
        .navigationSplitViewStyle(.balanced)
        .blendedToolbar()
    }

    @ViewBuilder
    private func page(for section: AppSection) -> some View {
        switch section {
        case .today:     TodayView()
        case .habits:    HabitsView()
        case .schedule:  ScheduleView()
        case .timetable: TimetableView()
        case .study:     StudyView()
        case .calendar:  CalendarPageView()
        case .progress:  ProgressPageView()
        case .journal:   JournalView()
        case .settings:  SettingsView()
        }
    }
}

struct SidebarView: View {
    @Binding var selection: AppSection?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach([AppSection.today, .habits, .schedule, .timetable, .study, .calendar, .progress, .journal]) { s in
                    NavigationLink(value: s) {
                        row(s)
                    }
                }
            } header: {
                Text("-life")
                    .font(.mono(12, .bold))
                    .italic()
                    .foregroundStyle(Palette.accent)
            }
            Section {
                NavigationLink(value: AppSection.settings) {
                    row(.settings)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Palette.sidebar.ignoresSafeArea())
        .blendedToolbar()
        .navigationTitle("Life")
    }

    /// One sidebar row. The icon is drawn in the label's own colour rather
    /// than the system accent — a sidebar full of blue glyphs fought with the
    /// app's warm palette. On the selected row it turns white, because the
    /// selection pill behind it is filled.
    private func row(_ section: AppSection) -> some View {
        Label {
            Text(section.title)
        } icon: {
            Image(systemName: section.icon)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selection == section ? Color.white : Color.primary)
        }
    }
}
