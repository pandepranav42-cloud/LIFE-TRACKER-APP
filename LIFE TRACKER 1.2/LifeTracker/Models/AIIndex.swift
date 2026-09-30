import Foundation
import SwiftData
import Compression
import NaturalLanguage
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Retrieval over your own course material (RAG)
//
// Everything here runs on the device. Files you upload to a subject are read,
// split into passages, and scored two ways when you ask a question:
//
//   • a keyword score (BM25) over tokens — works in any language, including
//     Korean and Chinese, and never fails;
//   • a meaning score from Apple's on-device NaturalLanguage embeddings, when
//     a model exists for the passage's language.
//
// The two are blended, the best passages are handed to Gemini, and the file
// they came from is shown under the answer. No embedding service is called and
// no file is uploaded anywhere for this.

// MARK: Stored passage

@Model
final class AIChunk {
    @Attribute(.unique) var id: UUID
    /// The material this came from, so chunks can be dropped when it is deleted.
    var materialID: UUID
    var subjectName: String
    var fileName: String
    /// "page 4", "slide 12" — appended to the file name when citing.
    var locator: String
    var text: String
    /// Lowercased word tokens, for the keyword score.
    var tokens: [String]
    /// Float32 sentence embedding, or nil when no model covered the language.
    var vector: Data?
    var indexedAt: Date

    init(materialID: UUID, subjectName: String, fileName: String,
         locator: String, text: String, tokens: [String], vector: Data?) {
        self.id = UUID()
        self.materialID = materialID
        self.subjectName = subjectName
        self.fileName = fileName
        self.locator = locator
        self.text = text
        self.tokens = tokens
        self.vector = vector
        self.indexedAt = .now
    }

    var citation: String {
        locator.isEmpty ? "\(fileName) · \(subjectName)" : "\(fileName) — \(locator)"
    }
}

/// A passage produced by extraction, before it becomes an `AIChunk`.
struct PendingChunk: Sendable {
    let locator: String
    let text: String
    let tokens: [String]
    let vector: Data?
}

// MARK: - The indexer

final class AIIndex: ObservableObject {
    static let shared = AIIndex()

    @Published private(set) var isIndexing = false
    @Published private(set) var progressText = ""
    @Published var lastError: String?

    private init() {}

    // MARK: Building the index

    /// Indexes any material that isn't in the index yet and drops passages
    /// whose file has been deleted. Safe to call often — it does nothing when
    /// everything is already current.
    @MainActor
    func refresh(context: ModelContext, force: Bool = false) async {
        guard !isIndexing else { return }
        isIndexing = true
        progressText = "Checking your material…"
        defer { isIndexing = false; progressText = "" }

        let materials = (try? context.fetch(FetchDescriptor<StudyMaterial>())) ?? []
        let chunks = (try? context.fetch(FetchDescriptor<AIChunk>())) ?? []

        // Forget passages from files that no longer exist.
        let liveIDs = Set(materials.map(\.id))
        for chunk in chunks where !liveIDs.contains(chunk.materialID) {
            context.delete(chunk)
        }
        if force {
            for chunk in chunks where liveIDs.contains(chunk.materialID) { context.delete(chunk) }
        }

        let indexed: Set<UUID> = force ? [] : Set(chunks.map(\.materialID))
        let pending = materials.filter { !indexed.contains($0.id) }
        guard !pending.isEmpty else {
            try? context.save()
            return
        }

        for (offset, material) in pending.enumerated() {
            progressText = "Reading \(material.fileName) (\(offset + 1) of \(pending.count))…"
            let data = material.data
            let ext = material.fileExtension
            let produced = await Task.detached(priority: .utility) {
                AIIndex.passages(from: data, fileExtension: ext)
            }.value

            guard !produced.isEmpty else { continue }
            let subject = material.subject?.name ?? "Unfiled"
            for piece in produced {
                context.insert(AIChunk(materialID: material.id,
                                       subjectName: subject,
                                       fileName: material.fileName,
                                       locator: piece.locator,
                                       text: piece.text,
                                       tokens: piece.tokens,
                                       vector: piece.vector))
            }
            try? context.save()
        }
        try? context.save()
    }

    /// Drops every passage from one file — called when material is deleted.
    @MainActor
    static func forget(materialID: UUID, context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<AIChunk>())) ?? []
        for chunk in all where chunk.materialID == materialID { context.delete(chunk) }
    }

    // MARK: Searching

    struct Hit {
        let chunk: AIChunk
        let score: Double
    }

    /// Best passages for a question, blended keyword + meaning.
    @MainActor
    func search(_ query: String, context: ModelContext, limit: Int = 6) -> [Hit] {
        let chunks = (try? context.fetch(FetchDescriptor<AIChunk>())) ?? []
        guard !chunks.isEmpty else { return [] }

        let queryTokens = AIIndex.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        // --- keyword score (BM25) ---
        let k1 = 1.5, b = 0.75
        let count = Double(chunks.count)
        let averageLength = chunks.reduce(0.0) { $0 + Double($1.tokens.count) } / count

        var documentFrequency: [String: Int] = [:]
        for chunk in chunks {
            for token in Set(chunk.tokens) where queryTokens.contains(token) {
                documentFrequency[token, default: 0] += 1
            }
        }

        var lexical = [Double](repeating: 0, count: chunks.count)
        for (index, chunk) in chunks.enumerated() {
            var counts: [String: Int] = [:]
            for token in chunk.tokens { counts[token, default: 0] += 1 }
            let length = Double(chunk.tokens.count)
            var score = 0.0
            for token in queryTokens {
                guard let frequency = counts[token], frequency > 0 else { continue }
                let n = Double(documentFrequency[token] ?? 0)
                let idf = log(1 + (count - n + 0.5) / (n + 0.5))
                let tf = Double(frequency)
                score += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * length / max(averageLength, 1)))
            }
            lexical[index] = score
        }
        let bestLexical = lexical.max() ?? 0

        // --- meaning score ---
        let queryVector = AIIndex.embed(query)
        var semantic = [Double](repeating: 0, count: chunks.count)
        if let queryVector {
            for (index, chunk) in chunks.enumerated() {
                guard let stored = chunk.vector else { continue }
                semantic[index] = AIIndex.cosine(queryVector, AIIndex.floats(stored))
            }
        }

        let hasVectors = semantic.contains { $0 > 0 }
        var hits: [Hit] = []
        for (index, chunk) in chunks.enumerated() {
            let lex = bestLexical > 0 ? lexical[index] / bestLexical : 0
            let score = hasVectors ? (0.55 * lex + 0.45 * max(0, semantic[index])) : lex
            if score > 0.02 { hits.append(Hit(chunk: chunk, score: score)) }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// The block of text handed to the model, plus the citations to show.
    @MainActor
    func retrieve(_ query: String, context: ModelContext) -> (text: String, sources: [String]) {
        let hits = search(query, context: context)
        guard !hits.isEmpty else {
            return ("Nothing in the uploaded material matched that. Say so plainly and answer from general knowledge instead, making clear it is not from his files.", [])
        }
        var budget = 7000
        var parts: [String] = []
        var sources: [String] = []
        for hit in hits {
            let body = hit.chunk.text
            guard budget - body.count > 0 else { break }
            budget -= body.count
            parts.append("[\(hit.chunk.citation)]\n\(body)")
            if !sources.contains(hit.chunk.citation) { sources.append(hit.chunk.citation) }
        }
        return (parts.joined(separator: "\n\n---\n\n"), sources)
    }

    // MARK: - Extraction (runs off the main thread)

    static func passages(from data: Data, fileExtension: String) -> [PendingChunk] {
        let pages = extractPages(from: data, fileExtension: fileExtension)
        var out: [PendingChunk] = []
        for (locator, body) in pages {
            for piece in chunk(body) {
                let tokens = tokenize(piece)
                guard tokens.count >= 4 else { continue }
                out.append(PendingChunk(locator: locator,
                                        text: piece,
                                        tokens: tokens,
                                        vector: embed(piece).map { bytes($0) }))
            }
        }
        // A very large book would otherwise dominate the whole index.
        return Array(out.prefix(400))
    }

    /// Everything readable in a file, as one block of text with page and slide
    /// markers kept in. Used when a file is attached to a question, where the
    /// whole document goes to the model rather than the best-matching passages.
    static func plainText(from data: Data, fileExtension: String) -> String {
        let pages = extractPages(from: data, fileExtension: fileExtension)
        guard !pages.isEmpty else { return "" }
        if pages.count == 1 && pages[0].0.isEmpty { return pages[0].1 }
        return pages.map { locator, body in
            locator.isEmpty ? body : "[\(locator)]\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// Text per page / slide / section, with a label for citing.
    private static func extractPages(from data: Data, fileExtension: String) -> [(String, String)] {
        switch fileExtension.lowercased() {
        case "pdf":
            #if canImport(PDFKit)
            guard let document = PDFDocument(data: data) else { return [] }
            var pages: [(String, String)] = []
            for index in 0..<document.pageCount {
                let text = document.page(at: index)?.string ?? ""
                let cleaned = tidy(text)
                if cleaned.count > 40 { pages.append(("page \(index + 1)", cleaned)) }
            }
            return pages
            #else
            return []
            #endif

        case "txt", "md", "markdown", "csv", "json", "rtf", "log":
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let cleaned = tidy(text)
            return cleaned.isEmpty ? [] : [("", cleaned)]

        case "docx":
            guard let xml = Zip.entry(named: "word/document.xml", in: data),
                  let text = String(data: xml, encoding: .utf8) else { return [] }
            let body = tidy(stripXML(text, paragraphTag: "w:p"))
            return body.isEmpty ? [] : [("", body)]

        case "pptx":
            var slides: [(String, String)] = []
            for entry in Zip.entries(matching: { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }, in: data)
                .sorted(by: { slideNumber($0.0) < slideNumber($1.0) }) {
                guard let text = String(data: entry.1, encoding: .utf8) else { continue }
                let body = tidy(stripXML(text, paragraphTag: "a:p"))
                if body.count > 20 { slides.append(("slide \(slideNumber(entry.0))", body)) }
            }
            return slides

        case "pages", "key", "numbers":
            // Apple iWork files are a package with no plain XML body to read.
            return []

        default:
            // Give anything else one honest attempt as UTF-8 text.
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            let cleaned = tidy(text)
            return cleaned.count > 60 ? [("", cleaned)] : []
        }
    }

    private static func slideNumber(_ path: String) -> Int {
        let digits = path.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        return Int(digits.last ?? "") ?? 0
    }

    /// Turns Office XML into text: paragraph tags become newlines, the rest goes.
    private static func stripXML(_ xml: String, paragraphTag: String) -> String {
        var text = xml.replacingOccurrences(of: "</\(paragraphTag)>", with: "\n")
        text = text.replacingOccurrences(of: "<w:br/>", with: "\n")
        text = text.replacingOccurrences(of: "<a:br/>", with: "\n")
        // Drop every remaining tag.
        var out = ""
        out.reserveCapacity(text.count / 2)
        var insideTag = false
        for character in text {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; continue }
            if !insideTag { out.append(character) }
        }
        return out
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func tidy(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\u{0}", with: "")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Chunking

    /// ~900 characters per passage, split on sentence ends, with a little
    /// overlap so an answer never falls between two chunks.
    private static func chunk(_ text: String, target: Int = 900, overlap: Int = 120) -> [String] {
        guard text.count > target else { return text.isEmpty ? [] : [text] }
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let piece = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            return true
        }
        if sentences.isEmpty { sentences = [text] }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            if current.count + sentence.count + 1 > target, !current.isEmpty {
                chunks.append(current)
                current = String(current.suffix(overlap)) + " "
            }
            current += sentence + " "
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count > 40 { chunks.append(tail) }
        return chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: Tokens

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = text[range].lowercased()
            if token.count >= 2 || token.unicodeScalars.contains(where: { $0.value > 0x2E80 }) {
                tokens.append(token)
            }
            return true
        }
        return tokens
    }

    // MARK: Embeddings

    /// A sentence vector from Apple's on-device model, if one covers the
    /// language. Long passages are averaged over their word vectors.
    static func embed(_ text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let language = recognizer.dominantLanguage ?? .english

        if let sentence = NLEmbedding.sentenceEmbedding(for: language),
           let vector = sentence.vector(for: String(trimmed.prefix(700))) {
            return normalise(vector)
        }
        guard let words = NLEmbedding.wordEmbedding(for: language) else { return nil }
        var sum: [Double] = []
        var used = 0
        for token in tokenize(trimmed).prefix(160) {
            guard let vector = words.vector(for: token) else { continue }
            if sum.isEmpty { sum = vector }
            else { for index in 0..<min(sum.count, vector.count) { sum[index] += vector[index] } }
            used += 1
        }
        guard used > 0 else { return nil }
        return normalise(sum.map { $0 / Double(used) })
    }

    private static func normalise(_ vector: [Double]) -> [Double] {
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return vector }
        return vector.map { $0 / length }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        // Both sides are stored normalised, so the dot product is the cosine.
        var total = 0.0
        for index in 0..<a.count { total += a[index] * b[index] }
        return total
    }

    static func bytes(_ vector: [Double]) -> Data {
        var floats = vector.map { Float($0) }
        return Data(bytes: &floats, count: floats.count * MemoryLayout<Float>.size)
    }

    static func floats(_ data: Data) -> [Double] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [Double] in
            let buffer = raw.bindMemory(to: Float.self)
            return (0..<count).map { Double(buffer[$0]) }
        }
    }
}

// MARK: - Just enough ZIP to read .docx and .pptx
//
// Office files are ZIP archives of XML. There is no zip reader in the system
// frameworks, so this walks the central directory itself and inflates entries
// with the Compression framework. Store (0) and Deflate (8) are handled, which
// is everything Word and PowerPoint produce.

enum Zip {

    static func entry(named name: String, in data: Data) -> Data? {
        entries(matching: { $0 == name }, in: data).first?.1
    }

    static func entries(matching predicate: (String) -> Bool, in data: Data) -> [(String, Data)] {
        guard let directory = centralDirectoryStart(in: data) else { return [] }
        var out: [(String, Data)] = []
        var cursor = directory

        while cursor + 46 <= data.count, read32(data, cursor) == 0x02014b50 {
            let method = Int(read16(data, cursor + 10))
            let compressedSize = Int(read32(data, cursor + 20))
            let uncompressedSize = Int(read32(data, cursor + 24))
            let nameLength = Int(read16(data, cursor + 28))
            let extraLength = Int(read16(data, cursor + 30))
            let commentLength = Int(read16(data, cursor + 32))
            let localOffset = Int(read32(data, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) ?? ""

            if predicate(name), compressedSize > 0, uncompressedSize > 0,
               localOffset + 30 <= data.count, read32(data, localOffset) == 0x04034b50 {
                let localNameLength = Int(read16(data, localOffset + 26))
                let localExtraLength = Int(read16(data, localOffset + 28))
                let start = localOffset + 30 + localNameLength + localExtraLength
                let end = start + compressedSize
                if end <= data.count {
                    let payload = data.subdata(in: start..<end)
                    if method == 0 {
                        out.append((name, payload))
                    } else if method == 8, let inflated = inflate(payload, expecting: uncompressedSize) {
                        out.append((name, inflated))
                    }
                }
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return out
    }

    /// Finds the End Of Central Directory record, searching back from the end.
    private static func centralDirectoryStart(in data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let window = min(data.count, 66_000)
        var index = data.count - minimum
        let floor = data.count - window
        while index >= floor && index >= 0 {
            if read32(data, index) == 0x06054b50 {
                let offset = Int(read32(data, index + 16))
                return offset < data.count ? offset : nil
            }
            index -= 1
        }
        return nil
    }

    private static func inflate(_ data: Data, expecting size: Int) -> Data? {
        // Deflate can expand pathological input; allow headroom but stay bounded.
        let capacity = max(size, 1) + 64 * 1024
        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, capacity,
                                                 sourceBase, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
