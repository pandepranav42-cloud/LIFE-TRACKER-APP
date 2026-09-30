import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import QuickLook
#if os(macOS)
import AppKit
#endif

// MARK: - Study palette (warm "study space" look, light + dark)

enum StudyPalette {
    // The Study page now shares the app-wide theme tokens.
    static let callout   = Palette.callout
    static let brown     = Palette.accent
    static let clock     = Palette.tan
    static let cardFill  = Palette.elevated
    static let pageFill  = Palette.surface
    static let line      = Palette.hairline

    /// Warm swatches for subject covers.
    static let swatches = [
        "E8C9A8", // latte
        "D9B38C", // caramel
        "C9A27E", // mocha
        "E6B8B0", // rose
        "F0D9A8", // honey
        "B9C7A5", // matcha
        "A9BCCB", // dusty blue
        "C8B6D6", // lavender
        "D6A5A0", // berry
        "BFB2A3", // stone
    ]
    static let emojis = ["📘", "📗", "📙", "📕", "🧮", "🧪", "🎨", "🎬", "🎧", "💻",
                         "🌏", "📐", "🧠", "✍️", "🗂️", "🍪", "☕️", "🌷", "🐻", "💸"]

}

// MARK: - Study (main page)

struct StudyView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StudySubject.sortIndex) private var subjects: [StudySubject]
    @Query(sort: \StudyTodo.createdAt) private var todos: [StudyTodo]
    @Query(sort: \MoodBoardImage.addedAt) private var images: [MoodBoardImage]

    @AppStorage("userName") private var userName: String = "there"
    @AppStorage("studyTitle") private var studyTitle: String = "Study Space"
    @AppStorage("studyAvatar") private var studyAvatar: String = "🧸"

    @State private var openSubject: StudySubject?
    @State private var editorTarget: SubjectEditorTarget?
    @State private var importingMood = false
    @State private var importingCover = false
    @State private var pickingAvatar = false
    @State private var showPortal = false
    @State private var showGitHub = false
    @Environment(\.layoutWidth) private var width
    private var contentWidth: CGFloat { width - 2 * AppLayout.pagePadding(width) }
    private var compact: Bool { AppLayout.isCompact(width) }

    struct SubjectEditorTarget: Identifiable {
        let id = UUID()
        let subject: StudySubject?
    }

    private var cover: MoodBoardImage? { images.first { $0.isCover } }
    private var moodImages: [MoodBoardImage] { images.filter { !$0.isCover } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StudyBanner(cover: cover, height: compact ? 140 : 190,
                                onChange: { importingCover = true },
                                onReset: removeCover)
                        .fileImporter(isPresented: $importingCover, allowedContentTypes: [.image]) { result in
                            guard case .success(let url) = result, let data = readFile(url) else { return }
                            images.filter(\.isCover).forEach { context.delete($0) }
                            let cover = MoodBoardImage(data: data, isCover: true)
                            context.insert(cover)
                            try? context.save()
                            Task { await DriveSync.shared.backup(cover); try? context.save() }
                        }

                    VStack(alignment: .leading, spacing: compact ? 26 : 34) {
                        titleBlock
                        AffirmationCallout()

                        if contentWidth >= 960 { wideLayout } else { narrowLayout }

                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "-mood board",
                                          trailing: moodImages.isEmpty ? nil : "\(moodImages.count) image\(moodImages.count == 1 ? "" : "s")")
                            MoodBoard(images: moodImages, onAdd: { importingMood = true })
                            .fileImporter(isPresented: $importingMood, allowedContentTypes: [.image],
                                          allowsMultipleSelection: true) { result in
                                guard case .success(let urls) = result else { return }
                                var added: [MoodBoardImage] = []
                                for url in urls {
                                    if let data = readFile(url) {
                                        let img = MoodBoardImage(data: data)
                                        context.insert(img)
                                        added.append(img)
                                    }
                                }
                                try? context.save()
                                Task {
                                    for img in added { await DriveSync.shared.backup(img) }
                                    try? context.save()
                                }
                            }
                        }
                        .padding(.top, 8)

                        // The little bear signs off the page.
                        Text("🧸")
                            .font(.system(size: 56))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, -8)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, AppLayout.pagePadding(width))
                    .padding(.bottom, 48)
                }
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .background(StudyPalette.pageFill)
            .navigationTitle("Study")
            .blendedToolbar()
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Your university portals — whichever ones you added.
                    Button { showPortal = true } label: {
                        Label("University", systemImage: "graduationcap")
                    }
                    .help("Your university portals — attendance, marks, results and fees, inside the app")

                    // Push files and folders to GitHub without the terminal.
                    Button { showGitHub = true } label: {
                        Label("GitHub & Colab", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .help("GitHub and Colab: drop files or a folder and push them to a repository")

                    Button { editorTarget = .init(subject: nil) } label: {
                        Label("New Subject", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(item: $openSubject) { subject in
                SubjectDetailView(subject: subject)
            }
            .navigationDestination(isPresented: $showPortal) {
                UniversityView()
            }
            .navigationDestination(isPresented: $showGitHub) {
                GitHubView()
            }
        }
        .sheet(item: $editorTarget) { target in
            SubjectEditor(subject: target.subject, nextSortIndex: (subjects.map(\.sortIndex).max() ?? -1) + 1)
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { pickingAvatar = true } label: {
                Text(studyAvatar)
                    .font(.system(size: 54))
                    .frame(width: 88, height: 88)
                    .background(StudyPalette.cardFill, in: Circle())
                    .overlay(Circle().strokeBorder(StudyPalette.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .help("Change icon")
            .popover(isPresented: $pickingAvatar) {
                EmojiGrid(selection: $studyAvatar,
                          options: ["🧸", "🐻", "🍪", "☕️", "🌷", "📚", "✏️", "🌙", "🍓", "🐱", "🌿", "⭐️"],
                          onPick: { pickingAvatar = false })
                    .compactPopoverAdaptation()
            }
            .padding(.top, -44)

            HStack(alignment: .center, spacing: 12) {
                Rectangle().fill(Color.primary).frame(width: 3, height: 32)
                if !userName.isEmpty && userName != "there" {
                    Text("\(userName) –")
                        .font(.mono(compact ? 24 : 32, .bold))
                        .fixedSize()
                }
                TextField("Study Space", text: $studyTitle)
                    .textFieldStyle(.plain)
                    .font(.mono(compact ? 24 : 32, .bold))
            }
        }
    }

    // MARK: Layouts

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 24) {
                MiniCalendar()
                StudyStats(subjects: subjects)
            }
            .frame(width: 230)

            SubjectsGrid(subjects: subjects,
                         onOpen: { openSubject = $0 },
                         onEdit: { editorTarget = .init(subject: $0) },
                         onNew: { editorTarget = .init(subject: nil) })
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 24) {
                ClockCard()
                RemindersList(todos: todos.filter { $0.day == 0 })
            }
            .frame(width: 230)
        }
    }

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: 28) {
            SubjectsGrid(subjects: subjects,
                         onOpen: { openSubject = $0 },
                         onEdit: { editorTarget = .init(subject: $0) },
                         onNew: { editorTarget = .init(subject: nil) })
            let side = contentWidth < 520 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
                                          : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            side {
                VStack(alignment: .leading, spacing: 24) {
                    ClockCard()
                    StudyStats(subjects: subjects)
                }
                RemindersList(todos: todos.filter { $0.day == 0 })
            }
        }
    }

    // MARK: Actions

    private func removeCover() {
        images.filter(\.isCover).forEach { context.delete($0) }
        try? context.save()
    }

    private func readFile(_ url: URL) -> Data? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}

// MARK: - Banner

private struct StudyBanner: View {
    let cover: MoodBoardImage?
    var height: CGFloat = 190
    @Environment(\.colorScheme) private var colorScheme
    var onChange: () -> Void
    var onReset: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let cover, let img = PlatformImage(data: cover.data) {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    defaultCover
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay(Color.black.opacity(colorScheme == .dark ? 0.35 : 0))   // soften in dark mode
            .clipped()

            // Mac: appears on hover. iPad (no hover): always shown, subtly.
            if hovering || !Platform.isMac {
                HStack(spacing: 6) {
                    Button("Change cover", action: onChange)
                    if cover != nil { Button("Reset", action: onReset) }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .padding(12)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hovering = h } }
    }

    /// A soft, painterly default cover made from gradients and symbols.
    private var defaultCover: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "E9B9A7"), Color(hex: "D99A86"), Color(hex: "F2D9B8")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.45), .clear],
                           center: .init(x: 0.2, y: 0.3), startRadius: 10, endRadius: 320)
            RadialGradient(colors: [Color(hex: "B97A6A").opacity(0.35), .clear],
                           center: .init(x: 0.85, y: 0.8), startRadius: 10, endRadius: 280)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                decor("cup.and.saucer.fill", 70, x: w * 0.42, y: h * 0.58, o: 0.35)
                decor("book.closed.fill", 44, x: w * 0.14, y: h * 0.40, o: 0.25)
                decor("leaf.fill", 36, x: w * 0.80, y: h * 0.30, o: 0.30)
                decor("camera.macro", 48, x: w * 0.90, y: h * 0.70, o: 0.28)
                decor("sparkle", 18, x: w * 0.30, y: h * 0.22, o: 0.5)
                decor("sparkle", 12, x: w * 0.62, y: h * 0.18, o: 0.5)
                decor("pencil", 30, x: w * 0.66, y: h * 0.68, o: 0.25)
            }
        }
    }

    private func decor(_ name: String, _ size: CGFloat, x: CGFloat, y: CGFloat, o: Double) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .light))
            .foregroundStyle(Color.white.opacity(o))
            .position(x: x, y: y)
    }
}

// MARK: - Callouts

/// Auto-rotating daily affirmation — changes every day by itself.
private struct AffirmationCallout: View {
    private static let lines = [
        "I am hardworking and everything works out for me.",
        "Small steps every day add up to big results.",
        "I am capable of learning anything I set my mind to.",
        "I focus on progress, not perfection.",
        "My effort today is a gift to my future self.",
        "I learn a little more every single day.",
        "I am calm, focused and prepared.",
        "Mistakes help me grow; I keep going.",
        "I trust the work I've put in.",
        "I show up for myself, even on slow days.",
        "Every page I read makes me stronger.",
        "I have time for what matters.",
        "Curiosity leads me; discipline carries me.",
        "I am proud of how far I've come.",
    ]

    /// Your own affirmation. Empty = use the built-in one that changes daily.
    @AppStorage("customAffirmation") private var custom: String = ""
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let day = Calendar.current.ordinality(of: .day, in: .era, for: ctx.date) ?? 0
            let daily = Self.lines[day % Self.lines.count]
            let line = custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? daily : custom
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "heart.fill").foregroundStyle(StudyPalette.brown)
                if editing {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Write your own affirmation", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.mono(14))
                            .italic()
                            .focused($focused)
                            .onSubmit(save)
                        HStack(spacing: 8) {
                            Button("Save", action: save)
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                            Button("Cancel") { editing = false }
                                .buttonStyle(.bordered)
                                .keyboardShortcut(.cancelAction)
                            if !custom.isEmpty {
                                Button("Use daily affirmations") {
                                    custom = ""
                                    editing = false
                                }
                                .buttonStyle(.plain)
                                .font(.mono(11))
                                .foregroundStyle(Palette.mutedText)
                            }
                        }
                        .controlSize(.small)
                    }
                } else {
                    Text("**\(custom.isEmpty ? "Daily Affirmation" : "My Affirmation"):** \(line)")
                        .font(.mono(14))
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2) { startEditing(line) }
                    Spacer(minLength: 8)
                    Button { startEditing(line) } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.mutedText)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit affirmation")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(StudyPalette.callout, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.easeInOut(duration: 0.15), value: editing)
        }
    }

    private func startEditing(_ current: String) {
        draft = custom.isEmpty ? "" : current
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func save() {
        custom = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
    }
}

// MARK: - Subjects grid

private struct SubjectsGrid: View {
    let subjects: [StudySubject]
    var onOpen: (StudySubject) -> Void
    var onEdit: (StudySubject) -> Void
    var onNew: () -> Void
    @Environment(\.modelContext) private var context

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "-classes",
                          trailing: subjects.isEmpty ? nil : "\(subjects.count) subject\(subjects.count == 1 ? "" : "s")")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(subjects) { s in
                    SubjectCard(subject: s)
                        .onTapGesture { onOpen(s) }
                        .contextMenu {
                            Button("Open") { onOpen(s) }
                            Button("Edit…") { onEdit(s) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                context.delete(s)
                                try? context.save()
                            }
                        }
                }
                Button(action: onNew) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("New subject")
                    }
                    .font(.mono(13))
                    .foregroundStyle(Palette.mutedText)
                    .frame(maxWidth: .infinity, minHeight: subjects.isEmpty ? 150 : 56)
                    .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(StudyPalette.line, style: StrokeStyle(lineWidth: 1, dash: subjects.isEmpty ? [4, 4] : [])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SubjectCard: View {
    let subject: StudySubject
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(hex: subject.colorHex), Color(hex: subject.colorHex).opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(subject.emoji).font(.system(size: 40))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            }
            .frame(height: 92)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Text(subject.emoji).font(.system(size: 13))
                    Text(subject.name)
                        .font(.mono(13))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    LinearBar(value: subject.syllabusProgress, height: 3, tint: StudyPalette.brown)
                    Text(meta)
                        .font(.mono(10))
                        .foregroundStyle(Palette.mutedText)
                        .fixedSize()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudyPalette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudyPalette.line))
        .shadow(color: .black.opacity(hovering ? 0.10 : 0.03), radius: hovering ? 10 : 3, y: hovering ? 4 : 1)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }

    private var meta: String {
        let files = subject.materials.count
        let links = subject.links.count
        var text = "\(Int((subject.syllabusProgress * 100).rounded()))% · \(files) file\(files == 1 ? "" : "s")"
        if links > 0 { text += " · \(links) link\(links == 1 ? "" : "s")" }
        return text
    }
}

// MARK: - Side widgets

private struct ClockCard: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 4) {
                Text(ctx.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(.system(size: 50, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(ctx.date.formatted(.dateTime.month(.wide).day().year()))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(StudyPalette.clock, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

private struct MiniCalendar: View {
    @State private var monthOffset = 0
    private let cal = Calendar.current

    private var month: Date {
        cal.date(byAdding: .month, value: monthOffset, to: .now) ?? .now
    }
    private var cells: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let lead = cal.component(.weekday, from: first) - 1   // Sunday first
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        var out: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<count { out.append(cal.date(byAdding: .day, value: d, to: first)) }
        while out.count % 7 != 0 { out.append(nil) }
        return out
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { monthOffset -= 1 } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(.plain)
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                Spacer()
                Button { monthOffset += 1 } label: { Image(systemName: "arrow.right") }
                    .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(StudyPalette.clock, in: Capsule())

            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.mutedText)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let today = cal.isDateInToday(date)
                        Text("\(cal.component(.day, from: date))")
                            .font(.system(size: 11, weight: today ? .bold : .regular))
                            .foregroundStyle(today ? Color.white : StudyPalette.brown)
                            .frame(width: 24, height: 24)
                            .background(today ? StudyPalette.clock : Color.clear, in: Circle())
                    } else {
                        Color.clear.frame(width: 24, height: 24)
                    }
                }
            }
        }
        .padding(14)
        .background(StudyPalette.callout.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(count: 2) { monthOffset = 0 }
        .help("Double-click to jump back to this month")
    }
}

private struct StudyStats: View {
    let subjects: [StudySubject]

    var body: some View {
        let topics = subjects.reduce(0) { $0 + $1.topics.count }
        let done = subjects.reduce(0) { $0 + $1.topics.filter(\.isDone).count }
        let files = subjects.reduce(0) { $0 + $1.materials.count }
        VStack(alignment: .leading, spacing: 10) {
            SideHeader("overview")
            statRow("book.closed", "Subjects", "\(subjects.count)")
            statRow("checklist", "Topics done", "\(done)/\(topics)")
            statRow("doc.on.doc", "Materials", "\(files)")
            LinearBar(value: topics == 0 ? 0 : Double(done) / Double(topics), height: 4, tint: StudyPalette.brown)
                .padding(.top, 4)
        }
    }

    private func statRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 18).foregroundStyle(StudyPalette.brown)
            Text(label).font(.mono(12))
            Spacer()
            Text(value).font(.mono(12, .semibold)).monospacedDigit()
        }
    }
}

private struct SideHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text("-\(text)")
            .font(.mono(13, .bold)).italic()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(StudyPalette.callout, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct RemindersList: View {
    let todos: [StudyTodo]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SideHeader("reminders")
            TodoList(todos: todos, day: 0, placeholder: "Add reminder")
        }
    }
}

// MARK: - Checklist building blocks

struct StudyCheckbox: View {
    let isOn: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isOn ? StudyPalette.brown : Color.primary.opacity(0.45), lineWidth: 1.3)
                .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? StudyPalette.brown : .clear))
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

private struct TodoList: View {
    @Environment(\.modelContext) private var context
    let todos: [StudyTodo]
    let day: Int
    var placeholder: String = "To-do"
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(todos) { t in
                TodoRow(todo: t)
            }
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.mutedText)
                    .frame(width: 16)
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.mono(13))
                    .onSubmit(add)
            }
        }
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        context.insert(StudyTodo(title: t, day: day))
        try? context.save()
        draft = ""
    }
}

private struct TodoRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var todo: StudyTodo
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                todo.isDone.toggle()
                try? context.save()
            } label: {
                CheckCircle(isOn: todo.isDone, tint: StudyPalette.brown, size: 19)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(todo.isDone ? "Mark as not done" : "Mark as done")

            TextField("To-do", text: $todo.title)
                .textFieldStyle(.plain)
                .font(.mono(13))
                .strikethrough(todo.isDone, color: Palette.mutedText)
                .foregroundStyle(todo.isDone ? Palette.mutedText : .primary)
                .onSubmit { try? context.save() }

            Button(role: .destructive) {
                context.delete(todo)
                try? context.save()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? Color(hex: "C0453F") : Palette.mutedText.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this reminder")
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(todo.isDone ? "Mark as not done" : "Mark as done") {
                todo.isDone.toggle(); try? context.save()
            }
            Button("Delete", role: .destructive) {
                context.delete(todo); try? context.save()
            }
        }
    }
}

// MARK: - Mood board

private struct MoodBoard: View {
    @Environment(\.modelContext) private var context
    let images: [MoodBoardImage]
    var onAdd: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)], spacing: 18) {
            ForEach(images) { img in
                MoodTile(image: img) {
                    let driveID = img.driveFileID
                    context.delete(img)
                    try? context.save()
                    if let driveID {
                        Task { @MainActor in await DriveSync.shared.remove(driveFileID: driveID) }
                    }
                }
            }
            Button(action: onAdd) {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 22))
                    Text("Add image").font(.mono(12))
                }
                .foregroundStyle(Palette.mutedText)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudyPalette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MoodTile: View {
    let image: MoodBoardImage
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = PlatformImage(data: image.data) {
                    Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 19))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(hovering ? 0.65 : 0.4))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Delete this picture")
            }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Remove", role: .destructive, action: onDelete)
            }
    }
}

// MARK: - Emoji grid

private struct EmojiGrid: View {
    @Binding var selection: String
    let options: [String]
    var onPick: () -> Void = {}

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), spacing: 6) {
            ForEach(options, id: \.self) { e in
                Button {
                    selection = e
                    onPick()
                } label: {
                    Text(e).font(.system(size: 22))
                        .frame(width: 34, height: 34)
                        .background(selection == e ? StudyPalette.callout : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
    }
}

// MARK: - Subject editor

struct SubjectEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let subject: StudySubject?
    var nextSortIndex: Int = 0

    @State private var name = ""
    @State private var emoji = "📘"
    @State private var colorHex = StudyPalette.swatches[0]
    @State private var teacher = ""
    @State private var time = ""
    @State private var section = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(subject == nil ? "New Subject" : "Edit Subject").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            Divider().overlay(Palette.hairline)

            Form {
                Section {
                    FormTextField("Name", text: $name, prompt: "e.g. Typography and Layout")
                    FormTextField("Teacher", text: $teacher, prompt: "e.g. Ms. Santos")
                    FormTextField("Time", text: $time, prompt: "e.g. 8:00 AM – 9:00 AM")
                    FormTextField("Section", text: $section, prompt: "e.g. 2B12")
                }
                Section("Icon") {
                    EmojiGrid(selection: $emoji, options: StudyPalette.emojis)
                }
                Section("Cover color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 10)], spacing: 10) {
                        ForEach(StudyPalette.swatches, id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle().fill(Color(hex: hex))
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().strokeBorder(hex == colorHex ? Color.primary : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .themedForm()
        }
        .sheetFrame(width: 500, height: 560)
        .onAppear {
            if let subject {
                name = subject.name; emoji = subject.emoji; colorHex = subject.colorHex
                teacher = subject.teacher; time = subject.time; section = subject.section
            } else {
                colorHex = StudyPalette.swatches.randomElement() ?? colorHex
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let s = subject ?? {
            let new = StudySubject(name: n, sortIndex: nextSortIndex)
            context.insert(new)
            return new
        }()
        s.name = n
        s.emoji = emoji
        s.colorHex = colorHex
        s.teacher = teacher.trimmingCharacters(in: .whitespaces)
        s.time = time.trimmingCharacters(in: .whitespaces)
        s.section = section.trimmingCharacters(in: .whitespaces)
        try? context.save()
        dismiss()
    }
}

// MARK: - Subject detail (Syllabus · Materials · Notes)

struct SubjectDetailView: View {
    @Environment(\.layoutWidth) private var width
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var subject: StudySubject

    enum Tab: String, CaseIterable, Identifiable {
        case syllabus = "Syllabus", materials = "Materials", links = "Links", notes = "Notes"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .syllabus
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cover
                VStack(alignment: .leading, spacing: 24) {
                    header
                    Picker("", selection: $tab) {
                        Text("Syllabus  \(subject.topics.count)").tag(Tab.syllabus)
                        Text("Files  \(subject.materials.count)").tag(Tab.materials)
                        Text("Links  \(subject.links.count)").tag(Tab.links)
                        Text("Notes").tag(Tab.notes)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 520)
                    .padding(.top, 4)

                    switch tab {
                    case .syllabus: SyllabusSection(subject: subject)
                    case .materials: MaterialsSection(subject: subject)
                    case .links: LinksSection(subject: subject)
                    case .notes: NotesSection(subject: subject)
                    }
                }
                .padding(.horizontal, AppLayout.pagePadding(width))
                .padding(.bottom, 44)
            }
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(StudyPalette.pageFill)
        .navigationTitle(subject.name)
        .blendedToolbar()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .sheet(isPresented: $editing) { SubjectEditor(subject: subject) }
        .confirmationDialog("Delete \(subject.name)?", isPresented: $confirmDelete) {
            Button("Delete subject and its materials", role: .destructive) {
                let doomed = subject
                let ctx = context
                dismiss()
                // Delete after the page has closed so nothing renders a deleted object.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    ctx.delete(doomed)
                    try? ctx.save()
                }
            }
        } message: {
            Text("Its syllabus, notes and uploaded files will be removed too.")
        }
        .onDisappear { try? context.save() }
    }

    private var cover: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: subject.colorHex), Color(hex: subject.colorHex).opacity(0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "sparkle")
                .font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
                .offset(x: 260, y: -30)
            Image(systemName: "book.closed.fill")
                .font(.system(size: 60, weight: .light)).foregroundStyle(.white.opacity(0.25))
                .offset(x: -240, y: 10)
        }
        .frame(height: 150)
        .clipped()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subject.emoji)
                .font(.system(size: 52))
                .frame(width: 84, height: 84)
                .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(StudyPalette.line))
                .padding(.top, -42)
            Text(subject.name).font(.mono(AppLayout.isCompact(width) ? 22 : 28, .bold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips }
                VStack(alignment: .leading, spacing: 6) { chips }
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        Group {
                if !subject.teacher.isEmpty { chip("person", subject.teacher) }
                if !subject.time.isEmpty { chip("clock", subject.time) }
                if !subject.section.isEmpty { chip("number", subject.section) }
                if subject.teacher.isEmpty && subject.time.isEmpty && subject.section.isEmpty {
                    Button("Add teacher, time and section…") { editing = true }
                        .buttonStyle(.plain).font(.mono(12)).foregroundStyle(Palette.mutedText)
                }
        }
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.mono(12))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(StudyPalette.callout, in: Capsule())
    }
}

// MARK: Syllabus

private struct SyllabusSection: View {
    @Environment(\.modelContext) private var context
    let subject: StudySubject
    @State private var draft = ""

    var body: some View {
        let topics = subject.sortedTopics
        let done = topics.filter(\.isDone).count
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                LinearBar(value: subject.syllabusProgress, height: 6, tint: StudyPalette.brown)
                Text("\(done) of \(topics.count) topics · \(Int((subject.syllabusProgress * 100).rounded()))%")
                    .font(.mono(12)).foregroundStyle(Palette.mutedText).fixedSize()
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(topics.enumerated()), id: \.element.id) { i, t in
                    TopicRow(topic: t, number: i + 1)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "plus").foregroundStyle(Palette.mutedText).frame(width: 18)
                TextField("Add a topic or chapter and press Return", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.mono(13))
                    .onSubmit { add(draft); draft = "" }
                Spacer()
                Button("Paste list") { pasteList() }
                    .controlSize(.small)
                    .help("Add one topic per line from the clipboard — handy for copying a syllabus.")
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(StudyPalette.callout.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func add(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: #"^([-•*]|\d+[.)])\s*"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        var next = (subject.topics.map(\.sortIndex).max() ?? -1) + 1
        for line in lines {
            let t = SyllabusTopic(title: line, sortIndex: next, subject: subject)
            context.insert(t)
            next += 1
        }
        try? context.save()
    }

    private func pasteList() {
        if let s = Platform.pastedString() { add(s) }
    }
}

private struct TopicRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var topic: SyllabusTopic
    let number: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                topic.isDone.toggle()
                try? context.save()
            } label: { CheckCircle(isOn: topic.isDone, tint: StudyPalette.brown, size: 20) }
            .buttonStyle(.plain)

            Text(String(format: "%02d", number))
                .font(.mono(11)).foregroundStyle(Palette.mutedText)

            TextField("Topic", text: $topic.title)
                .textFieldStyle(.plain)
                .font(.mono(14))
                .strikethrough(topic.isDone, color: Palette.mutedText)
                .foregroundStyle(topic.isDone ? Palette.mutedText : .primary)
                .onSubmit { try? context.save() }

            Button(role: .destructive) {
                context.delete(topic)
                try? context.save()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Color(hex: "C0453F") : Palette.mutedText.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this topic")
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(hovering ? Palette.subtleFill : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(topic.isDone ? "Mark as not done" : "Mark as done") {
                topic.isDone.toggle(); try? context.save()
            }
            Button("Delete", role: .destructive) {
                context.delete(topic); try? context.save()
            }
        }
    }
}

// MARK: Materials

enum MaterialKind: String, CaseIterable, Identifiable {
    case all = "All", pdf = "PDF", slides = "Slides", docs = "Documents", sheets = "Sheets",
         code = "Code", images = "Images", videos = "Videos", audio = "Audio",
         archives = "Archives", other = "Other"
    var id: String { rawValue }

    static let codeExtensions: Set<String> = [
        "py", "ipynb", "c", "h", "cpp", "cc", "cxx", "hpp", "cs", "java", "kt", "kts", "swift",
        "m", "mm", "js", "mjs", "cjs", "ts", "tsx", "jsx", "html", "htm", "css", "scss", "sass",
        "json", "xml", "yaml", "yml", "toml", "ini", "sql", "r", "rmd", "go", "rs", "rb", "php",
        "pl", "lua", "dart", "scala", "sh", "bash", "zsh", "ps1", "bat", "asm", "s", "v", "vhd",
        "sv", "hs", "ml", "ex", "exs", "erl", "clj", "jl", "f90", "f", "tex", "bib", "vue",
        "svelte", "gradle", "makefile", "cmake", "dockerfile", "env", "cfg", "conf", "log", "csv_code"
    ]

    static func of(_ ext: String) -> MaterialKind {
        let e = ext.lowercased()
        switch e {
        case "pdf": return .pdf
        case "ppt", "pptx", "pps", "ppsx", "key", "odp": return .slides
        case "doc", "docx", "pages", "rtf", "txt", "md", "markdown", "odt", "epub": return .docs
        case "xls", "xlsx", "xlsm", "numbers", "csv", "tsv", "ods": return .sheets
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp", "svg", "raw", "psd", "ai": return .images
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "3gp": return .videos
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "aif", "opus": return .audio
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso": return .archives
        default:
            return codeExtensions.contains(e) ? .code : .other
        }
    }
    var color: Color {
        switch self {
        case .pdf: return Color(hex: "D9534F")
        case .slides: return Color(hex: "E07B39")
        case .docs: return Color(hex: "3B6FD8")
        case .sheets: return Color(hex: "2E9E5B")
        case .code: return Color(hex: "7A5CC6")
        case .images: return Color(hex: "C2567A")
        case .videos: return Color(hex: "D2453F")
        case .audio: return Color(hex: "2B9AA8")
        case .archives: return Color(hex: "9A7B4F")
        default: return Color(hex: "8C8C8C")
        }
    }
    var icon: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .slides: return "rectangle.on.rectangle.angled"
        case .docs: return "doc.text"
        case .sheets: return "tablecells"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "waveform"
        case .archives: return "doc.zipper"
        default: return "doc"
        }
    }

    /// Friendly language name for code files ("Python", "C", …).
    static func language(_ ext: String) -> String? {
        let names: [String: String] = [
            "py": "Python", "ipynb": "Jupyter", "c": "C", "h": "C header", "cpp": "C++", "cc": "C++",
            "cxx": "C++", "hpp": "C++ header", "cs": "C#", "java": "Java", "kt": "Kotlin", "swift": "Swift",
            "m": "Objective-C", "js": "JavaScript", "ts": "TypeScript", "tsx": "TSX", "jsx": "JSX",
            "html": "HTML", "htm": "HTML", "css": "CSS", "json": "JSON", "xml": "XML", "yaml": "YAML",
            "yml": "YAML", "sql": "SQL", "r": "R", "go": "Go", "rs": "Rust", "rb": "Ruby", "php": "PHP",
            "sh": "Shell", "bash": "Shell", "dart": "Dart", "scala": "Scala", "lua": "Lua", "tex": "LaTeX",
            "asm": "Assembly", "hs": "Haskell", "jl": "Julia", "vue": "Vue", "pl": "Perl", "ps1": "PowerShell"
        ]
        return names[ext.lowercased()]
    }
}

enum MaterialFiles {
    /// Any file at all — documents, code, images, videos, audio, archives…
    /// (folders and app bundles are packages, so `.item` + `.content` covers files).
    static let allowedTypes: [UTType] = [.item, .content, .data, .sourceCode, .movie, .audio, .image, .archive]

    /// Writes the stored bytes to a temp file so Quick Look / other apps can open it.
    static func fileURL(for m: StudyMaterial) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeTrackerStudy", isDirectory: true)
            .appendingPathComponent(m.id.uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(displayName(m))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            if existing != m.byteCount { try m.data.write(to: url, options: .atomic) }
            return url
        } catch {
            return nil
        }
    }

    static func displayName(_ m: StudyMaterial) -> String {
        m.fileExtension.isEmpty ? m.fileName : "\(m.fileName).\(m.fileExtension)"
    }

    /// Hands the file to the system share sheet — AirDrop, WhatsApp, Messages,
    /// Mail, Save to Files… The bytes are written to a temp copy first, so the
    /// other app receives a real file with its proper name and extension.
    @MainActor
    static func share(_ m: StudyMaterial) {
        guard let url = fileURL(for: m) else { return }
        ShareTools.share([url])
    }

    @MainActor
    static func share(_ materials: [StudyMaterial]) {
        let urls = materials.compactMap { fileURL(for: $0) }
        ShareTools.share(urls)
    }

    @MainActor
    static func importFiles(_ urls: [URL], into subject: StudySubject, context: ModelContext) {
        var added: [StudyMaterial] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let m = StudyMaterial(fileName: url.deletingPathExtension().lastPathComponent,
                                  fileExtension: url.pathExtension,
                                  data: data,
                                  subject: subject)
            context.insert(m)
            added.append(m)
        }
        try? context.save()
        // Back up to Google Drive in the background (no-op if Drive isn't connected).
        Task { @MainActor in
            for m in added { await DriveSync.shared.backup(m) }
            try? context.save()
        }
    }

    #if os(macOS)
    static func saveCopy(_ m: StudyMaterial) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = displayName(m)
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? m.data.write(to: url, options: .atomic)
        }
    }
    #endif
}

private struct MaterialsSection: View {
    @Environment(\.modelContext) private var context
    let subject: StudySubject
    @State private var importing = false
    @State private var filter: MaterialKind = .all
    @State private var previewURL: URL?
    @State private var dropTargeted = false
    @State private var renaming: StudyMaterial?
    @State private var deleting: StudyMaterial?

    private var materials: [StudyMaterial] {
        subject.materials
            .filter { filter == .all || MaterialKind.of($0.fileExtension) == filter }
            .sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if subject.materials.isEmpty {
                dropZone
            } else {
                HStack {
                    Picker("", selection: $filter) {
                        ForEach(MaterialKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if materials.count > 1 {
                        Button {
                            MaterialFiles.share(materials)
                        } label: {
                            Label("Share All", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .help("Send every file shown here at once")
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)], spacing: 14) {
                    ForEach(materials) { m in
                        MaterialCard(material: m) { deleting = m }
                            .onTapGesture(count: 2) { open(m) }
                            .onTapGesture { previewURL = MaterialFiles.fileURL(for: m) }
                            .contextMenu {
                                Button("Quick Look") { previewURL = MaterialFiles.fileURL(for: m) }
                                #if os(macOS)
                                Button("Open") { open(m) }
                                Button("Save a Copy…") { MaterialFiles.saveCopy(m) }
                                #endif
                                // Grouped: a #if block is flattened into the
                                // builder, and macOS would otherwise be at 12
                                // children here, past ViewBuilder's limit.
                                Group {
                                    Divider()
                                    Button {
                                        Task { await LifeAIBridge.shared.summarise(m) }
                                    } label: {
                                        Label("Summarise with Life AI", systemImage: "sparkles")
                                    }
                                    Button {
                                        Task { await LifeAIBridge.shared.explain(m) }
                                    } label: {
                                        Label("Explain this to me", systemImage: "text.book.closed")
                                    }
                                    Button {
                                        Task { await LifeAIBridge.shared.quiz(m) }
                                    } label: {
                                        Label("Quiz me on it", systemImage: "questionmark.circle")
                                    }
                                }
                                Divider()
                                Button {
                                    MaterialFiles.share(m)
                                } label: {
                                    Label("Share…", systemImage: "square.and.arrow.up")
                                }
                                Button("Rename…") { renaming = m }
                                Divider()
                                Button("Delete…", role: .destructive) { deleting = m }
                            }
                    }
                }
                if materials.isEmpty {
                    Text("No \(filter.rawValue.lowercased()) files yet.")
                        .font(.mono(12)).foregroundStyle(Palette.mutedText)
                }
                Text(Platform.isMac
                     ? "Click to preview · double-click to open · ✦ asks Life AI to summarise, explain or quiz you · ↑ shares · drag files here to add more"
                     : "Tap to preview · ✦ asks Life AI about the file · ↑ shares · press and hold for more · drag files here to add more")
                    .font(.mono(11)).foregroundStyle(Palette.mutedText)

                addRow
            }
        }
        .padding(dropTargeted ? 10 : 0)
        .background(dropTargeted ? StudyPalette.callout : .clear, in: RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            MaterialFiles.importFiles(files, into: subject, context: context)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: MaterialFiles.allowedTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                MaterialFiles.importFiles(urls, into: subject, context: context)
            }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $renaming) { m in RenameMaterialSheet(material: m) }
        .confirmationDialog(deleting.map { "Delete “\(MaterialFiles.displayName($0))”?" } ?? "Delete this file?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible,
                            presenting: deleting) { m in
            if m.driveFileID != nil {
                Button("Delete here and in Drive", role: .destructive) { delete(m, alsoFromDrive: true) }
                Button("Delete here only") { delete(m, alsoFromDrive: false) }
            } else {
                Button("Delete", role: .destructive) { delete(m, alsoFromDrive: false) }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { m in
            Text(m.driveFileID != nil
                 ? "This file is backed up to Google Drive. Deleting it there moves it to Drive's Bin, where you can still get it back for 30 days."
                 : "This file isn't in Drive, so it will only be removed from LifeTracker.")
        }
    }

    private func delete(_ m: StudyMaterial, alsoFromDrive: Bool) {
        let driveID = m.driveFileID
        // Drop the passages Life AI indexed from this file too, so it can't
        // quote a document you've deleted.
        AIIndex.forget(materialID: m.id, context: context)
        context.delete(m)
        try? context.save()
        deleting = nil
        if alsoFromDrive, let driveID {
            Task { @MainActor in await DriveSync.shared.remove(driveFileID: driveID) }
        }
    }

    /// Sits under the files, so your material stays at the top of the page.
    private var addRow: some View {
        Button { importing = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus").foregroundStyle(Palette.mutedText).frame(width: 18)
                Text("Add files — PDF, slides, Word, code, images… or drop them here")
                    .font(.mono(13)).foregroundStyle(Palette.mutedText)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10).padding(.horizontal, 10)
            .background(StudyPalette.callout.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dropZone: some View {
        Button { importing = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 30, weight: .light))
                Text("Add your study material").font(.mono(14, .semibold))
                Text("Any file: PDF, slides, Word, code (Python, C, Java…), images, videos, audio, zips… drop them here or click to choose")
                    .font(.mono(11)).multilineTextAlignment(.center)
                    .foregroundStyle(Palette.mutedText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 50)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(StudyPalette.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Mac: open in the file's default app (Preview, PowerPoint, Word…).
    /// iPad: open the full-screen Quick Look viewer (with its own share button).
    private func open(_ m: StudyMaterial) {
        guard let url = MaterialFiles.fileURL(for: m) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        previewURL = url
        #endif
    }
}

private struct MaterialCard: View {
    let material: StudyMaterial
    var onDelete: () -> Void = {}
    @State private var hovering = false

    private func badge(_ kind: MaterialKind) -> String {
        if kind == .code, let lang = MaterialKind.language(material.fileExtension) { return lang }
        return material.fileExtension.isEmpty ? "FILE" : material.fileExtension.uppercased()
    }

    /// Small inline preview: picture thumbnail, or the first lines of a code / text file.
    @ViewBuilder
    private func preview(_ kind: MaterialKind) -> some View {
        switch kind {
        case .images:
            if material.byteCount < 25_000_000, let img = PlatformImage(data: material.data) {
                Color.clear
                    .frame(height: 96)
                    .overlay { Image(platformImage: img).resizable().aspectRatio(contentMode: .fill) }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .code:
            let text = String(decoding: material.data.prefix(1500), as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n")
            Text(lines)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Palette.mutedText)
                .lineLimit(6)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                .padding(8)
                .background(Palette.subtleFill, in: RoundedRectangle(cornerRadius: 6))
        default:
            EmptyView()
        }
    }

    var body: some View {
        let kind = MaterialKind.of(material.fileExtension)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: kind.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(kind.color)
                    .frame(width: 40, height: 40)
                    .background(kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Text(badge(kind))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(kind.color, in: Capsule())
                    .lineLimit(1)
            }
            preview(kind)
            Text(material.fileName)
                .font(.mono(12, .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            HStack(spacing: 6) {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(material.byteCount), countStyle: .file)) · \(material.addedAt.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(.mono(10))
                    .foregroundStyle(Palette.mutedText)
                Spacer(minLength: 0)
                if material.driveFileID != nil {
                    Image(systemName: "checkmark.icloud")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                        .help("Backed up to Google Drive")
                }
                Menu {
                    Button {
                        Task { await LifeAIBridge.shared.summarise(material) }
                    } label: {
                        Label("Summarise it", systemImage: "text.alignleft")
                    }
                    Button {
                        Task { await LifeAIBridge.shared.explain(material) }
                    } label: {
                        Label("Explain it to me", systemImage: "text.book.closed")
                    }
                    Button {
                        Task { await LifeAIBridge.shared.quiz(material) }
                    } label: {
                        Label("Quiz me on it", systemImage: "questionmark.circle")
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hovering ? Palette.accent : Palette.mutedText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Ask Life AI about this file")

                Button {
                    MaterialFiles.share(material)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hovering ? kind.color : Palette.mutedText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Share — AirDrop, WhatsApp, Mail, Save to Files…")

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hovering ? Color(hex: "C0453F") : Palette.mutedText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this file")
            }
        }
        .padding(14)
        .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovering ? kind.color.opacity(0.5) : StudyPalette.line))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: 8, y: 3)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .help(MaterialFiles.displayName(material))
    }
}

private struct RenameMaterialSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let material: StudyMaterial
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename file").font(.headline)
            HStack(spacing: 4) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if !material.fileExtension.isEmpty {
                    Text(".\(material.fileExtension)").foregroundStyle(Palette.mutedText)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .sheetFrame(width: 380, height: 170)
        .onAppear { name = material.fileName }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        material.fileName = n
        try? context.save()
        dismiss()
    }
}

// MARK: Notes

private struct NotesSection: View {
    @Environment(\.modelContext) private var context
    @Bindable var subject: StudySubject

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $subject.notes)
                .font(.mono(14))
                .scrollContentBackground(.hidden)
                .padding(14)
                .frame(minHeight: 360)
                .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudyPalette.line))
            Text("Saved automatically.")
                .font(.mono(11)).foregroundStyle(Palette.mutedText)
        }
        .onChange(of: subject.notes) { _, _ in try? context.save() }
    }
}


// MARK: Links (YouTube videos & websites)

private struct LinksSection: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    let subject: StudySubject

    @State private var draftURL = ""
    @State private var draftTitle = ""
    @State private var adding = false
    @State private var error: String?
    @State private var filter: Filter = .all
    @State private var dropTargeted = false
    @State private var renaming: StudyLink?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", videos = "Videos", drive = "Files", other = "Other"
        var id: String { rawValue }
    }

    private var links: [StudyLink] {
        subject.links
            .filter {
                switch filter {
                case .all: return true
                case .videos: return $0.kind == .video
                case .drive: return $0.kind == .drive
                case .other: return $0.kind != .video && $0.kind != .drive
                }
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if subject.links.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "link").font(.system(size: 28, weight: .light))
                    Text("Save any link for this subject").font(.mono(14, .semibold))
                    Text("YouTube, Google Drive, Docs, GitHub, a PDF on the web, a Notion page, an email — paste it below or drag it in from your browser.")
                        .font(.mono(11)).multilineTextAlignment(.center)
                        .foregroundStyle(Palette.mutedText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(StudyPalette.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            } else {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)], spacing: 14) {
                    ForEach(links) { link in
                        LinkCard(link: link) { delete(link) }
                            .onTapGesture { if let u = link.url { openURL(u) } }
                            .contextMenu {
                                Button("Open") { if let u = link.url { openURL(u) } }
                                Button("Copy link") { Platform.copy(link.urlString) }
                                Button("Rename…") { renaming = link }
                                Divider()
                                Button("Delete", role: .destructive) { delete(link) }
                            }
                    }
                }
                if links.isEmpty {
                    Text("No \(filter.rawValue.lowercased()) yet.")
                        .font(.mono(12)).foregroundStyle(Palette.mutedText)
                }
                Text(Platform.isMac ? "Click to open · right-click for more" : "Tap to open · press and hold for more")
                    .font(.mono(11)).foregroundStyle(Palette.mutedText)
            }

            addBar
        }
        .padding(dropTargeted ? 10 : 0)
        .background(dropTargeted ? StudyPalette.callout : .clear, in: RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { for u in urls { await add(u, title: "") } }
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $renaming) { link in RenameLinkSheet(link: link) }
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { urlField; titleField.frame(maxWidth: 220); addButton }
                VStack(spacing: 8) { urlField; HStack(spacing: 8) { titleField; addButton } }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(StudyPalette.callout.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var urlField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(Palette.mutedText)
            TextField("Paste any link — YouTube, Drive, Docs, a website…", text: $draftURL)
                .textFieldStyle(.plain)
                .font(.mono(13))
                .onSubmit(submit)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Button {
                if let s = Platform.pastedString() { draftURL = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            } label: { Image(systemName: "doc.on.clipboard") }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.mutedText)
            .help("Paste from clipboard")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudyPalette.line))
    }

    private var titleField: some View {
        TextField("Title (optional)", text: $draftTitle)
            .textFieldStyle(.plain)
            .font(.mono(13))
            .onSubmit(submit)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudyPalette.line))
    }

    private var addButton: some View {
        Button(action: submit) {
            if adding { ProgressView().controlSize(.small) } else { Label("Add", systemImage: "plus") }
        }
        .buttonStyle(.borderedProminent)
        .tint(StudyPalette.brown)
        .disabled(draftURL.trimmingCharacters(in: .whitespaces).isEmpty || adding)
    }

    private func submit() {
        guard let url = Self.normalize(draftURL) else {
            error = "That doesn't look like a link. Paste a full address, e.g. https://drive.google.com/… , example.com, or mailto:name@mail.com"
            return
        }
        error = nil
        let title = draftTitle
        Task {
            await add(url, title: title)
            draftURL = ""
            draftTitle = ""
        }
    }

    @MainActor
    private func add(_ url: URL, title: String) async {
        adding = true
        defer { adding = false }
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = await LinkMetadata.title(for: url) ?? (url.host ?? url.absoluteString) }
        context.insert(StudyLink(url: url, title: name, subject: subject))
        try? context.save()
    }

    private func delete(_ link: StudyLink) {
        context.delete(link)
        try? context.save()
    }

    /// Accepts anything that can be opened: full URLs of any scheme
    /// (https, ftp, mailto:, notion://, zoom://, file://…), bare hosts like
    /// "example.com", intranet names, IP addresses and "localhost:3000".
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // People often paste "Link: https://… " or a link wrapped in <>/quotes.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        if let found = firstURLLike(in: s) { s = found }
        guard !s.isEmpty else { return nil }

        let hasScheme = s.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
        if !hasScheme { s = "https://" + s }
        // Encode spaces and other characters URL(string:) would choke on.
        let encoded = s.addingPercentEncoding(withAllowedCharacters: .urlAllowedForLinks) ?? s
        guard let url = URL(string: encoded), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        // Web links need something host-like; app links (notion://, mailto:) don't.
        if ["http", "https", "ftp", "ftps"].contains(scheme.lowercased()) {
            guard let host = url.host, !host.isEmpty else { return nil }
        }
        return url
    }

    /// Pulls the link out of a pasted sentence, if there is one.
    private static func firstURLLike(in text: String) -> String? {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return String(text[range])
        }
        return text.split(separator: " ").first(where: { $0.contains(".") || $0.contains("://") }).map(String.init)
    }
}

/// Fetches a readable title: YouTube's oEmbed for videos, the page <title> otherwise.
enum LinkMetadata {
    static func title(for url: URL) async -> String? {
        do {
            if isYouTube(url) {
                var comps = URLComponents(string: "https://www.youtube.com/oembed")!
                comps.queryItems = [.init(name: "url", value: url.absoluteString), .init(name: "format", value: "json")]
                let (data, _) = try await URLSession.shared.data(from: comps.url!)
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["title"] as? String
            }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("Mozilla/5.0 (Macintosh) LifeTracker", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            let html = String(decoding: data.prefix(200_000), as: UTF8.self)
            guard let r = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let raw = html[r]
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        } catch {
            return nil
        }
    }

    private static func isYouTube(_ url: URL) -> Bool {
        let h = url.host?.lowercased() ?? ""
        return h.contains("youtube.com") || h.hasSuffix("youtu.be")
    }
}

private struct LinkCard: View {
    let link: StudyLink
    var onDelete: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let id = link.youTubeID {
                // Video thumbnail with a play badge
                ZStack {
                    Rectangle().fill(Palette.subtleFill)
                    AsyncImage(url: URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "play.rectangle").font(.system(size: 26, weight: .light))
                                .foregroundStyle(Palette.mutedText)
                        }
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 32)
                        .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    let kind = link.kind
                    if kind == .video {
                        Image(systemName: kind.icon).foregroundStyle(Color(hex: kind.colorHex))
                    } else if let host = link.url?.host, !host.isEmpty {
                        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(host)")) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: kind.icon).foregroundStyle(Color(hex: kind.colorHex))
                            }
                        }
                        .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: kind.icon).foregroundStyle(Color(hex: kind.colorHex))
                    }
                    Text(link.isYouTube ? "YouTube" : (link.url?.host?.replacingOccurrences(of: "www.", with: "") ?? kind.title))
                        .font(.mono(10))
                        .foregroundStyle(Palette.mutedText)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? StudyPalette.brown : Palette.mutedText)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(link.title)
                        .font(.mono(12, .medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    Button {
                        Platform.copy(link.urlString)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.mutedText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy this link")
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(hovering ? Color(hex: "C0453F") : Palette.mutedText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete this link")
                }
            }
            .padding(12)
        }
        .background(StudyPalette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(hovering ? StudyPalette.brown.opacity(0.5) : StudyPalette.line))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: 8, y: 3)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .help(link.urlString)
    }
}

private struct RenameLinkSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let link: StudyLink
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename link").font(.headline)
            TextField("Title", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text(link.urlString).font(.caption).foregroundStyle(Palette.mutedText).lineLimit(1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .sheetFrame(width: 400, height: 190)
        .onAppear { name = link.title }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        link.title = n
        try? context.save()
        dismiss()
    }
}
