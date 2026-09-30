import Foundation
import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Export / import everything in LifeTracker as ONE file (.lifetracker):
/// habits and their ticks, schedule, timetable (including the picture),
/// calendar marks, journal, study subjects with syllabus, notes, links and
/// every uploaded file (PDF, slides, code, images, video…), the mood board,
/// reminders and your app settings.
///
/// File layout — files are streamed one at a time, so even a few GB of study
/// material never has to sit in memory all at once:
///
///   "LTBK1\n"                    magic
///   <blob><blob>…                the raw bytes of every attached file
///   <manifest JSON>              everything else, with offsets into the blobs
///   <8-byte manifest offset><8-byte manifest length>     footer
enum Transfer {
    static let fileExtension = "lifetracker"
    private static let magic = Data("LTBK1\n".utf8)

    // MARK: - Manifest types

    struct Blob: Codable {
        var id: UUID
        var offset: UInt64
        var length: UInt64
    }

    struct Manifest: Codable {
        var version = 1
        var exportedAt = Date()
        var appVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        var deviceName: String = Transfer.deviceName
        var settings: [String: String] = [:]
        /// Saved logins — present only when the export included them.
        var secrets: [String: String]?
        var blobs: [Blob] = []

        var habits: [HabitDTO] = []
        var schedule: [ScheduleDTO] = []
        var timetableCategories: [CategoryDTO] = []
        var timetableSlots: [SlotDTO] = []
        var timetableBlocks: [BlockDTO] = []
        var timetableImage: AssetDTO?
        var marks: [MarkDTO] = []
        var journal: [JournalDTO] = []
        var subjects: [SubjectDTO] = []
        var todos: [TodoDTO] = []
        var moodImages: [AssetDTO] = []
        var portals: [PortalDTO] = []

        var summary: String {
            let files = subjects.reduce(0) { $0 + $1.materials.count } + moodImages.count + (timetableImage == nil ? 0 : 1)
            return "\(habits.count) habits · \(subjects.count) subjects · \(files) files · \(journal.count) journal entries"
        }
    }

    struct HabitDTO: Codable {
        var name: String, iconName: String, frequencyRaw: String
        var customWeekdays: [Int], startDate: Date, isPaused: Bool
        var sortIndex: Int, createdAt: Date, pauseLog: [Date]?
        var completions: [CompletionDTO]
    }
    struct CompletionDTO: Codable { var date: Date; var completedAt: Date? }
    struct ScheduleDTO: Codable {
        var title: String, startTime: Date, endTime: Date, category: String, notes: String
        var reminderEnabled: Bool, reminderLeadMinutes: Int?, sortIndex: Int, colorHex: String
        var completions: [ScheduleDoneDTO]
    }
    struct ScheduleDoneDTO: Codable { var date: Date; var completedAt: Date; var title: String; var colorHex: String }
    struct CategoryDTO: Codable { var id: UUID; var name: String; var colorHex: String; var sortIndex: Int }
    struct SlotDTO: Codable { var id: UUID; var startTime: String; var endTime: String }
    struct BlockDTO: Codable { var day: Int; var startTime: String; var endTime: String; var title: String; var categoryID: UUID? }
    struct AssetDTO: Codable { var id: UUID; var addedAt: Date; var isCover: Bool; var driveFileID: String? }
    struct MarkDTO: Codable {
        var id: UUID, date: Date, title: String, colorHex: String, kindRaw: String
        var completed: Bool, completedAt: Date?
    }
    struct JournalDTO: Codable {
        var date: Date, title: String, text: String, mood: Int, energy: Int
        var savedAt: Date?, colorHex: String?
    }
    struct SubjectDTO: Codable {
        var id: UUID, name: String, emoji: String, colorHex: String
        var teacher: String, time: String, section: String, notes: String
        var sortIndex: Int, createdAt: Date
        var topics: [TopicDTO], materials: [MaterialDTO], links: [LinkDTO]
    }
    struct TopicDTO: Codable { var title: String; var isDone: Bool; var sortIndex: Int; var createdAt: Date }
    struct MaterialDTO: Codable {
        var id: UUID, fileName: String, fileExtension: String, byteCount: Int, addedAt: Date
        /// Carried across so the other device doesn't upload a second copy to Drive.
        var driveFileID: String?
    }
    struct LinkDTO: Codable { var id: UUID; var urlString: String; var title: String; var note: String; var addedAt: Date }
    struct TodoDTO: Codable { var title: String; var day: Int; var isDone: Bool; var createdAt: Date }
    struct PortalDTO: Codable {
        var id: UUID, name: String, urlString: String, colorHex: String
        var iconName: String, sortIndex: Int, addedAt: Date
    }

    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    /// Settings carried across with the data.
    private static let settingKeys = ["userName", "studyTitle", "studyAvatar", "customAffirmation",
                                      "appearance", "progressRange", "notificationsEnabled",
                                      "sync.drive.enabled", "journal.lockEnabled",
                                      "portal.homeURL", "portal.name", "github.lastRepo"]

    /// Keychain items that travel with the archive when you ask for them:
    /// your GitHub token and every saved portal login. They are *not* included
    /// unless you tick the box, because anyone holding the file could then
    /// sign in as you.
    private static var secretKeys: [String] {
        ["github.token"] + PortalKeys.allKeychainKeys + AIProviderStore.allKeychainKeys
    }

    // MARK: - Export

    @MainActor
    static func export(context: ModelContext, to url: URL, includeLogins: Bool = true,
                       progress: @escaping (String) -> Void) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: magic)

        var manifest = Manifest()
        var offset = UInt64(magic.count)

        /// Streams one attached file into the archive.
        func writeBlob(id: UUID, data: Data) throws {
            try handle.write(contentsOf: data)
            manifest.blobs.append(Blob(id: id, offset: offset, length: UInt64(data.count)))
            offset += UInt64(data.count)
        }

        // --- Study subjects (+ their files)
        let subjects = (try? context.fetch(FetchDescriptor<StudySubject>())) ?? []
        for s in subjects.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            progress("Packing “\(s.name)”…")
            var materials: [MaterialDTO] = []
            for m in s.materials.sorted(by: { $0.addedAt < $1.addedAt }) {
                try writeBlob(id: m.id, data: m.data)
                materials.append(MaterialDTO(id: m.id, fileName: m.fileName, fileExtension: m.fileExtension,
                                             byteCount: m.byteCount, addedAt: m.addedAt,
                                             driveFileID: m.driveFileID))
            }
            manifest.subjects.append(SubjectDTO(
                id: s.id, name: s.name, emoji: s.emoji, colorHex: s.colorHex,
                teacher: s.teacher, time: s.time, section: s.section, notes: s.notes,
                sortIndex: s.sortIndex, createdAt: s.createdAt,
                topics: s.sortedTopics.map { TopicDTO(title: $0.title, isDone: $0.isDone, sortIndex: $0.sortIndex, createdAt: $0.createdAt) },
                materials: materials,
                links: s.links.map { LinkDTO(id: $0.id, urlString: $0.urlString, title: $0.title, note: $0.note, addedAt: $0.addedAt) }))
        }

        // --- Mood board + Study cover
        progress("Packing pictures…")
        for img in (try? context.fetch(FetchDescriptor<MoodBoardImage>())) ?? [] {
            try writeBlob(id: img.id, data: img.data)
            manifest.moodImages.append(AssetDTO(id: img.id, addedAt: img.addedAt, isCover: img.isCover,
                                                driveFileID: img.driveFileID))
        }

        // --- Timetable picture
        if let asset = ((try? context.fetch(FetchDescriptor<TimetableImageAsset>())) ?? []).first {
            try writeBlob(id: asset.id, data: asset.imageData)
            manifest.timetableImage = AssetDTO(id: asset.id, addedAt: .now, isCover: false,
                                               driveFileID: asset.driveFileID)
        }

        // --- Everything else
        progress("Packing habits, schedule and journal…")
        for h in (try? context.fetch(FetchDescriptor<Habit>())) ?? [] {
            manifest.habits.append(HabitDTO(
                name: h.name, iconName: h.iconName, frequencyRaw: h.frequencyRaw,
                customWeekdays: h.customWeekdays, startDate: h.startDate, isPaused: h.isPaused,
                sortIndex: h.sortIndex, createdAt: h.createdAt, pauseLog: h.pauseLog,
                completions: h.completions.map { CompletionDTO(date: $0.date, completedAt: $0.completedAt) }))
        }
        for i in (try? context.fetch(FetchDescriptor<ScheduleItem>())) ?? [] {
            manifest.schedule.append(ScheduleDTO(
                title: i.title, startTime: i.startTime, endTime: i.endTime, category: i.category,
                notes: i.notes, reminderEnabled: i.reminderEnabled, reminderLeadMinutes: i.reminderLeadMinutes,
                sortIndex: i.sortIndex, colorHex: i.colorHex,
                completions: i.completions.map { ScheduleDoneDTO(date: $0.date, completedAt: $0.completedAt, title: $0.title, colorHex: $0.colorHex) }))
        }
        for c in (try? context.fetch(FetchDescriptor<TimetableCategory>())) ?? [] {
            manifest.timetableCategories.append(CategoryDTO(id: c.id, name: c.name, colorHex: c.colorHex, sortIndex: c.sortIndex))
        }
        for s in (try? context.fetch(FetchDescriptor<TimetableSlot>())) ?? [] {
            manifest.timetableSlots.append(SlotDTO(id: s.id, startTime: s.startTime, endTime: s.endTime))
        }
        for b in (try? context.fetch(FetchDescriptor<TimetableBlock>())) ?? [] {
            manifest.timetableBlocks.append(BlockDTO(day: b.day, startTime: b.startTime, endTime: b.endTime,
                                                     title: b.title, categoryID: b.categoryID))
        }
        for m in (try? context.fetch(FetchDescriptor<CalendarMark>())) ?? [] {
            manifest.marks.append(MarkDTO(id: m.id, date: m.date, title: m.title, colorHex: m.colorHex,
                                          kindRaw: m.kindRaw, completed: m.completed, completedAt: m.completedAt))
        }
        for j in (try? context.fetch(FetchDescriptor<JournalEntry>())) ?? [] {
            manifest.journal.append(JournalDTO(date: j.date, title: j.title, text: j.text, mood: j.mood,
                                               energy: j.energy, savedAt: j.savedAt, colorHex: j.colorHex))
        }
        for t in (try? context.fetch(FetchDescriptor<StudyTodo>())) ?? [] {
            manifest.todos.append(TodoDTO(title: t.title, day: t.day, isDone: t.isDone, createdAt: t.createdAt))
        }
        for portal in (try? context.fetch(FetchDescriptor<UniPortal>())) ?? [] {
            manifest.portals.append(PortalDTO(id: portal.id, name: portal.name, urlString: portal.urlString,
                                              colorHex: portal.colorHex, iconName: portal.iconName,
                                              sortIndex: portal.sortIndex, addedAt: portal.addedAt))
        }
        for key in settingKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                manifest.settings[key] = String(describing: value)
            }
        }
        if includeLogins {
            var secrets: [String: String] = [:]
            for key in secretKeys {
                if let value = Keychain.get(key), !value.isEmpty { secrets[key] = value }
            }
            if !secrets.isEmpty { manifest.secrets = secrets }
        }

        // --- Manifest + footer
        progress("Finishing…")
        let manifestData = try JSONEncoder().encode(manifest)
        try handle.write(contentsOf: manifestData)
        var footer = Data()
        withUnsafeBytes(of: offset.littleEndian) { footer.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(manifestData.count).littleEndian) { footer.append(contentsOf: $0) }
        try handle.write(contentsOf: footer)
    }

    // MARK: - Read a manifest (used to preview a file before importing)

    static func readManifest(at url: URL) throws -> Manifest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: magic.count), head == magic else {
            throw TransferError.notALifeTrackerFile
        }
        let size = try handle.seekToEnd()
        guard size > 16 else { throw TransferError.damaged }
        try handle.seek(toOffset: size - 16)
        guard let footer = try handle.read(upToCount: 16), footer.count == 16 else { throw TransferError.damaged }
        let offset = footer.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        let length = footer.suffix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: Int(length)) else { throw TransferError.damaged }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - Import

    /// Importing always restores the file exactly: this device is cleared
    /// first, then everything in the archive is put back. No merge option —
    /// the point of an export is that the other device ends up identical.
    @MainActor
    static func importArchive(at url: URL, context: ModelContext,
                              progress: @escaping (String) -> Void) throws -> Manifest {
        let manifest = try readManifest(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let blobs = Dictionary(manifest.blobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func blob(_ id: UUID) -> Data? {
            guard let b = blobs[id] else { return nil }
            do {
                try handle.seek(toOffset: b.offset)
                return try handle.read(upToCount: Int(b.length))
            } catch { return nil }
        }
        func deleteAll<T: PersistentModel>(_ type: T.Type) {
            for item in (try? context.fetch(FetchDescriptor<T>())) ?? [] { context.delete(item) }
        }

        do {
            progress("Clearing this device…")
            deleteAll(HabitCompletion.self); deleteAll(Habit.self)
            deleteAll(ScheduleCompletion.self); deleteAll(ScheduleItem.self)
            deleteAll(TimetableCategory.self); deleteAll(TimetableSlot.self)
            deleteAll(TimetableBlock.self); deleteAll(TimetableImageAsset.self)
            deleteAll(CalendarMark.self); deleteAll(JournalEntry.self)
            deleteAll(SyllabusTopic.self); deleteAll(StudyMaterial.self)
            deleteAll(StudyLink.self); deleteAll(StudySubject.self)
            deleteAll(StudyTodo.self); deleteAll(MoodBoardImage.self)
            deleteAll(UniPortal.self)
            PortalBackup.forgetAll()
            try? context.save()
        }

        // What's already here (so "Add" doesn't duplicate anything).
        let existingSubjects = Set((try? context.fetch(FetchDescriptor<StudySubject>()))?.map(\.id) ?? [])
        let existingMarks = Set((try? context.fetch(FetchDescriptor<CalendarMark>()))?.map(\.id) ?? [])
        let existingHabits = Set(((try? context.fetch(FetchDescriptor<Habit>())) ?? []).map { "\($0.name)|\($0.createdAt.timeIntervalSince1970)" })
        let existingSchedule = Set(((try? context.fetch(FetchDescriptor<ScheduleItem>())) ?? []).map { "\($0.title)|\($0.startTime.timeIntervalSince1970)" })
        let existingJournal = Set(((try? context.fetch(FetchDescriptor<JournalEntry>())) ?? []).map(\.date))
        let existingTodos = Set(((try? context.fetch(FetchDescriptor<StudyTodo>())) ?? []).map { "\($0.title)|\($0.day)" })
        let existingCats = Set((try? context.fetch(FetchDescriptor<TimetableCategory>()))?.map(\.id) ?? [])
        let existingSlots = Set((try? context.fetch(FetchDescriptor<TimetableSlot>()))?.map(\.id) ?? [])
        let existingBlocks = Set(((try? context.fetch(FetchDescriptor<TimetableBlock>())) ?? []).map { "\($0.day)|\($0.startTime)|\($0.endTime)" })
        let existingImages = Set((try? context.fetch(FetchDescriptor<MoodBoardImage>()))?.map(\.id) ?? [])
        let existingPortals = Set((try? context.fetch(FetchDescriptor<UniPortal>()))?.map(\.id) ?? [])

        // --- Subjects, syllabus, files, links
        for s in manifest.subjects where !existingSubjects.contains(s.id) {
            progress("Restoring “\(s.name)”…")
            let subject = StudySubject(name: s.name, emoji: s.emoji, colorHex: s.colorHex,
                                       teacher: s.teacher, time: s.time, section: s.section, sortIndex: s.sortIndex)
            subject.id = s.id
            subject.notes = s.notes
            subject.createdAt = s.createdAt
            context.insert(subject)
            for t in s.topics {
                let topic = SyllabusTopic(title: t.title, sortIndex: t.sortIndex, subject: subject)
                topic.isDone = t.isDone
                topic.createdAt = t.createdAt
                context.insert(topic)
            }
            for m in s.materials {
                guard let data = blob(m.id) else { continue }
                let material = StudyMaterial(fileName: m.fileName, fileExtension: m.fileExtension,
                                             data: data, subject: subject)
                material.id = m.id
                material.addedAt = m.addedAt
                material.driveFileID = m.driveFileID      // already in Drive — don't upload again
                context.insert(material)
            }
            for l in s.links {
                guard let u = URL(string: l.urlString) else { continue }
                let link = StudyLink(url: u, title: l.title, subject: subject)
                link.id = l.id
                link.note = l.note
                link.addedAt = l.addedAt
                context.insert(link)
            }
            try? context.save()
        }

        // --- Habits
        progress("Restoring habits…")
        for h in manifest.habits where !existingHabits.contains("\(h.name)|\(h.createdAt.timeIntervalSince1970)") {
            let habit = Habit(name: h.name, iconName: h.iconName,
                              frequency: HabitFrequency(rawValue: h.frequencyRaw) ?? .daily,
                              customWeekdays: h.customWeekdays, startDate: h.startDate, sortIndex: h.sortIndex)
            habit.isPaused = h.isPaused
            habit.createdAt = h.createdAt
            habit.pauseLog = h.pauseLog
            context.insert(habit)
            for c in h.completions {
                context.insert(HabitCompletion(date: c.date, habit: habit, completedAt: c.completedAt))
            }
        }

        // --- Schedule
        for i in manifest.schedule where !existingSchedule.contains("\(i.title)|\(i.startTime.timeIntervalSince1970)") {
            let item = ScheduleItem(title: i.title, startTime: i.startTime, endTime: i.endTime,
                                    category: i.category, notes: i.notes,
                                    reminderEnabled: i.reminderEnabled, sortIndex: i.sortIndex, colorHex: i.colorHex)
            item.reminderLeadMinutes = i.reminderLeadMinutes
            context.insert(item)
            for c in i.completions {
                let done = ScheduleCompletion(item: item, date: c.date, completedAt: c.completedAt)
                done.title = c.title
                done.colorHex = c.colorHex
                context.insert(done)
            }
        }

        // --- Timetable
        progress("Restoring timetable…")
        for c in manifest.timetableCategories where !existingCats.contains(c.id) {
            let cat = TimetableCategory(name: c.name, colorHex: c.colorHex, sortIndex: c.sortIndex)
            cat.id = c.id
            context.insert(cat)
        }
        for s in manifest.timetableSlots where !existingSlots.contains(s.id) {
            let slot = TimetableSlot(startTime: s.startTime, endTime: s.endTime)
            slot.id = s.id
            context.insert(slot)
        }
        for b in manifest.timetableBlocks where !existingBlocks.contains("\(b.day)|\(b.startTime)|\(b.endTime)") {
            context.insert(TimetableBlock(day: b.day, startTime: b.startTime, endTime: b.endTime,
                                          title: b.title, categoryID: b.categoryID))
        }
        if let asset = manifest.timetableImage, let data = blob(asset.id),
           ((try? context.fetch(FetchDescriptor<TimetableImageAsset>())) ?? []).isEmpty {
            let image = TimetableImageAsset(imageData: data)
            image.id = asset.id
            image.driveFileID = asset.driveFileID
            context.insert(image)
        }

        // --- Calendar, journal, reminders, pictures
        progress("Restoring calendar, journal and pictures…")
        for m in manifest.marks where !existingMarks.contains(m.id) {
            let mark = CalendarMark(date: m.date, title: m.title, colorHex: m.colorHex,
                                    kind: CalendarMarkKind(rawValue: m.kindRaw) ?? .event, completed: m.completed)
            mark.id = m.id
            mark.completedAt = m.completedAt
            context.insert(mark)
        }
        for j in manifest.journal where !existingJournal.contains(j.date) {
            context.insert(JournalEntry(date: j.date, title: j.title, text: j.text, mood: j.mood,
                                        energy: j.energy, savedAt: j.savedAt, colorHex: j.colorHex))
        }
        for t in manifest.todos where !existingTodos.contains("\(t.title)|\(t.day)") {
            let todo = StudyTodo(title: t.title, day: t.day)
            todo.isDone = t.isDone
            todo.createdAt = t.createdAt
            context.insert(todo)
        }
        for p in manifest.portals where !existingPortals.contains(p.id) {
            let portal = UniPortal(name: p.name, urlString: p.urlString, colorHex: p.colorHex,
                                   iconName: p.iconName, sortIndex: p.sortIndex)
            portal.id = p.id
            portal.addedAt = p.addedAt
            context.insert(portal)
        }
        // Keep the restore-proof copy in step with what was just imported.
        PortalBackup.save((try? context.fetch(FetchDescriptor<UniPortal>())) ?? [])
        for img in manifest.moodImages where !existingImages.contains(img.id) {
            guard let data = blob(img.id) else { continue }
            let image = MoodBoardImage(data: data, isCover: img.isCover)
            image.id = img.id
            image.addedAt = img.addedAt
            image.driveFileID = img.driveFileID
            context.insert(image)
        }

        // --- Settings (only where this device has nothing yet, unless replacing)
        for (key, value) in manifest.secrets ?? [:] {
            Keychain.set(value, for: key)
        }
        if (manifest.secrets ?? [:]).keys.contains(where: { $0.hasPrefix("portal.accounts") }) {
            // The Keychain items landed, but the index of which hosts have
            // logins lives in UserDefaults — rebuild it from the keys, or this
            // device's own next export would omit every one of them.
            PortalKeys.rememberHosts((manifest.secrets ?? [:]).keys
                .filter { $0.hasPrefix("portal.accounts.") }
                .map { String($0.dropFirst("portal.accounts.".count)) })
            PortalKeys.shared.reload()
        }

        for (key, value) in manifest.settings {
            let defaults = UserDefaults.standard
            if value == "true" || value == "false" {
                defaults.set(value == "true", forKey: key)
            } else if let number = Int(value) {
                defaults.set(number, forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }

        try context.save()
        progress("Done")
        return manifest
    }

    /// Suggested file name: "LifeTracker 2026-09-23.lifetracker"
    static func suggestedFileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "LifeTracker \(f.string(from: .now)).\(fileExtension)"
    }
}

enum TransferError: LocalizedError {
    case notALifeTrackerFile, damaged
    var errorDescription: String? {
        switch self {
        case .notALifeTrackerFile: return "That isn't a LifeTracker backup file."
        case .damaged: return "This backup file looks damaged or incomplete."
        }
    }
}
