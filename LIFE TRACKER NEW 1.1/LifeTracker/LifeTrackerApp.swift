import SwiftUI
import SwiftData

@main
struct LifeTrackerApp: App {
    /// One shared store for the main window (and the Mac Settings window).
    init() {
        NotificationManager.shared.configure()
    }

    private let container: ModelContainer = {
        let schema = Schema([
            Habit.self,
            HabitCompletion.self,
            ScheduleItem.self,
            ScheduleCompletion.self,
            JournalEntry.self,
            TimetableCategory.self,
            TimetableSlot.self,
            TimetableImageAsset.self,
            TimetableBlock.self,
            CalendarMark.self,
            StudySubject.self,
            SyllabusTopic.self,
            StudyMaterial.self,
            StudyLink.self,
            StudyTodo.self,
            MoodBoardImage.self,
            UniPortal.self,
            AIConversation.self,
            AIMessage.self,
            AIChunk.self
        ])
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Could not open the LifeTracker store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Palette.accent)
                .modifier(AppearanceSync())
        }
        .modelContainer(container)
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 780)
        #endif

        #if os(macOS)
        Settings {
            SettingsGate()
                .tint(Palette.accent)
                .modifier(AppearanceSync())
                .modelContainer(container)
        }
        #endif
    }
}

/// Mac Settings window: only usable once signed in.
private struct SettingsGate: View {
    @ObservedObject private var accounts = AccountStore.shared
    var body: some View {
        if accounts.isLoggedIn {
            SettingsView()
        } else {
            VStack(spacing: 10) {
                Text("🧸").font(.system(size: 40))
                Text("Sign in to LifeTracker first").font(.mono(14, .bold))
                Text("Open the main window to sign in.").font(.caption).foregroundStyle(Palette.mutedText)
            }
            .frame(width: 420, height: 260)
            .background(Palette.surface)
        }
    }
}
