import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Attaching files to a question
//
// Any file can go into the chat. How it travels depends on what it is:
//
//   • Anything we can read on the device — PDF, Word, PowerPoint, text, code,
//     CSV, JSON — is turned into plain text here and sent as text. That keeps
//     the request small and works for large documents.
//   • Images, and PDFs with no extractable text (a scan, or slides exported as
//     pictures), are sent as bytes for Gemini to look at itself.
//   • Anything else says so honestly rather than pretending it was read.

struct AIAttachment: Identifiable, Equatable {
    let id = UUID()
    var name: String
    /// Text pulled out on the device, when that was possible.
    var text: String?
    /// Raw bytes, for files Gemini reads itself.
    var data: Data?
    var mimeType: String?
    var byteCount: Int
    /// One line for the chip: "24 pages read", "sent as an image"…
    var note: String
    /// Set when this came from a file already in a subject.
    var materialID: UUID?

    static func == (a: AIAttachment, b: AIAttachment) -> Bool { a.id == b.id }

    /// Gemini's inline limit is generous but the whole request must stay
    /// sensible; past this a file is summarised from its text instead.
    static let maxInlineBytes = 8 * 1024 * 1024
    /// Roughly 40k characters is plenty of context for one document.
    static let maxTextCharacters = 40_000

    /// Decides how one file should travel, doing the reading on the device.
    static func make(name: String, fileExtension: String, data: Data, materialID: UUID? = nil) -> AIAttachment {
        let ext = fileExtension.lowercased()
        let extracted = AIIndex.plainText(from: data, fileExtension: ext)

        if extracted.count >= 200 {
            let trimmed = extracted.count > maxTextCharacters
                ? String(extracted.prefix(maxTextCharacters)) + "\n\n[…truncated — the file is longer than this]"
                : extracted
            let words = trimmed.split(whereSeparator: \.isWhitespace).count
            return AIAttachment(name: name, text: trimmed, data: nil, mimeType: nil,
                                byteCount: data.count,
                                note: "\(words) words read on device",
                                materialID: materialID)
        }

        if let mime = inlineMime(for: ext), data.count <= maxInlineBytes {
            return AIAttachment(name: name, text: nil, data: data, mimeType: mime,
                                byteCount: data.count,
                                note: ext == "pdf" ? "sent as a PDF to read" : "sent as an image to look at",
                                materialID: materialID)
        }

        if !extracted.isEmpty {
            return AIAttachment(name: name, text: extracted, data: nil, mimeType: nil,
                                byteCount: data.count,
                                note: "only a little text could be read",
                                materialID: materialID)
        }

        let why = data.count > maxInlineBytes
            ? "too large to send (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))"
            : "this file type can't be read"
        return AIAttachment(name: name, text: nil, data: nil, mimeType: nil,
                            byteCount: data.count, note: why, materialID: materialID)
    }

    /// Reads a file already in a subject. Extraction (a long PDF, a big deck)
    /// happens off the main thread so the window never freezes; only the few
    /// properties it needs are read on the main actor first.
    @MainActor
    static func make(from material: StudyMaterial) async -> AIAttachment {
        let name = MaterialFiles.displayName(material)
        let ext = material.fileExtension
        let data = material.data
        let id = material.id
        return await Task.detached(priority: .userInitiated) {
            AIAttachment.make(name: name, fileExtension: ext, data: data, materialID: id)
        }.value
    }

    /// Reads a file off disk (the file importer, or a drop), again off the
    /// main thread once the bytes are in hand.
    static func make(url: URL) async -> AIAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let name = url.lastPathComponent
        let ext = url.pathExtension
        return await Task.detached(priority: .userInitiated) {
            AIAttachment.make(name: name, fileExtension: ext, data: data)
        }.value
    }

    /// File types Gemini can look at directly.
    private static func inlineMime(for ext: String) -> String? {
        switch ext {
        case "png":            return "image/png"
        case "jpg", "jpeg":    return "image/jpeg"
        case "webp":           return "image/webp"
        case "heic":           return "image/heic"
        case "heif":           return "image/heif"
        case "gif":            return "image/gif"
        case "bmp":            return "image/bmp"
        case "tif", "tiff":    return "image/tiff"
        case "pdf":            return "application/pdf"
        default:               return nil
        }
    }

    var icon: String {
        if mimeType?.hasPrefix("image/") == true { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if text != nil { return "doc.text" }
        return "questionmark.folder"
    }

    var wasRead: Bool { text != nil || data != nil }
}

// MARK: - Asking Life AI from anywhere in the app
//
// Study, a subject, the GitHub console — any page can hand a question to the
// floating panel without knowing anything about it. The panel picks the
// request up, opens itself and sends.

final class LifeAIBridge: ObservableObject {
    static let shared = LifeAIBridge()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        var prompt: String
        var attachments: [AIAttachment]
        static func == (a: Request, b: Request) -> Bool { a.id == b.id }
    }

    /// Set by a page, consumed by the panel.
    @Published var pending: Request?

    private init() {}

    @MainActor
    func ask(_ prompt: String, attachments: [AIAttachment] = []) {
        pending = Request(prompt: prompt, attachments: attachments)
    }

    /// "Summarise with AI" on a file in a subject.
    @MainActor
    func summarise(_ material: StudyMaterial) async {
        let subject = material.subject?.name
        let file = await AIAttachment.make(from: material)
        let context = subject.map { " It belongs to my subject \"\($0)\"." } ?? ""
        ask("""
            Summarise this file for me.\(context) Lead with one line on what it is, \
            then the substance in short sections, then anything that looks examinable. \
            Keep the document's own terms and its language.
            """,
            attachments: [file])
    }

    /// "Explain with AI" — a slower read of the same file.
    @MainActor
    func explain(_ material: StudyMaterial) async {
        let file = await AIAttachment.make(from: material)
        ask("""
            Walk me through this file as if teaching it. Explain the ideas in order, \
            define the terms it assumes I know, and end with three questions I should \
            be able to answer if I understood it.
            """,
            attachments: [file])
    }

    /// "Quiz me on this file".
    @MainActor
    func quiz(_ material: StudyMaterial) async {
        let file = await AIAttachment.make(from: material)
        ask("""
            Make me a practice test from this file: eight questions, mixed difficulty, \
            in the file's own language. Number them, leave space, and put the answers \
            at the end under a heading so I can cover them.
            """,
            attachments: [file])
    }
}

// MARK: - Saving an answer into a subject

enum AINotes {
    /// Appends text to a subject's Notes under a dated heading, so saved
    /// answers pile up in order instead of overwriting each other.
    @MainActor
    static func append(_ body: String, heading: String, to subject: StudySubject, context: ModelContext) {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        let stamp = formatter.string(from: .now)
        let title = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = """
        ## \(title.isEmpty ? "From Life AI" : title)
        _\(stamp) · Life AI_

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        if subject.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subject.notes = block
        } else {
            subject.notes += "\n\n---\n\n" + block
        }
        try? context.save()
    }

    /// A short heading guessed from the text: its first heading, or its first
    /// line, trimmed to something that fits.
    static func suggestedHeading(for text: String) -> String {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let cleaned = line
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { continue }
            return String(cleaned.prefix(60))
        }
        return "From Life AI"
    }
}
