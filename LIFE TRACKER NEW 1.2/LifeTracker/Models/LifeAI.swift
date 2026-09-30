import Foundation
import SwiftUI
import SwiftData

// MARK: - Life AI
//
// The assistant that lives in the floating panel. It talks to whichever AI
// provider you have given a key — Google, OpenAI, Anthropic, xAI, or anything
// that speaks the OpenAI chat API — straight from the device. There is no
// server in between, and nothing about you is stored anywhere but this Mac /
// iPad.
//
// What it can see is decided in one place, `AIContextBuilder` (AIContext.swift):
// habits, schedule, timetable, subjects and their material, calendar marks,
// progress and GitHub. **Journal is never included.** If you add a new page to
// the app, it stays invisible to Life AI until you add it there on purpose.

// MARK: Stored chat

@Model
final class AIConversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \AIMessage.conversation)
    var messages: [AIMessage] = []

    init(title: String = "New chat") {
        self.id = UUID()
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var ordered: [AIMessage] { messages.sorted { $0.createdAt < $1.createdAt } }
}

@Model
final class AIMessage {
    @Attribute(.unique) var id: UUID
    /// "user" or "model".
    var roleRaw: String
    var text: String
    var createdAt: Date
    /// Names of the material chunks that were quoted into this answer.
    var sources: [String]
    /// Short descriptions of anything the assistant changed in the app.
    var actions: [String]
    /// File names attached to this message, for the chips above it.
    /// Defaulted so a store written by an earlier build migrates cleanly.
    var attachmentNames: [String] = []
    var conversation: AIConversation?

    init(role: String, text: String, sources: [String] = [],
         actions: [String] = [], attachmentNames: [String] = []) {
        self.id = UUID()
        self.roleRaw = role
        self.text = text
        self.createdAt = .now
        self.sources = sources
        self.actions = actions
        self.attachmentNames = attachmentNames
    }

    var isUser: Bool { roleRaw == "user" }
}

// MARK: - Actions the assistant may take

/// One thing Life AI asked the app to do. The panel executes these on the main
/// actor with the live `ModelContext` and hands back a one-line result, which
/// goes to the model so it can tell you what happened in its own words.
struct AIAction {
    let name: String
    let args: [String: String]
}

/// Raised when the chosen model doesn't exist for this key, so the caller
/// knows to re-discover the list and retry rather than give up.
private struct UnknownModelError: Error {
    let message: String
}

// MARK: - The client

final class LifeAI: ObservableObject {
    static let shared = LifeAI()

    /// A Gemini key baked into the build, so a fresh install has something to
    /// talk to before you have typed anything into Settings.
    ///
    /// It is deliberately **not** written in this file any more. A key sitting
    /// in source goes wherever the source goes: GitHub's push protection
    /// refuses the file outright ("Secret detected in content"), and anyone
    /// who downloads a release can read it straight out of the binary.
    ///
    /// Two places are checked instead, both of them outside version control:
    ///
    ///  1. `GeminiAPIKey` in the built Info.plist. Put it in a local
    ///     `Secrets.xcconfig` (git ignores that name) as
    ///     `INFOPLIST_KEY_GeminiAPIKey = AQ.…` and set it as the project's
    ///     configuration file, or just type it into the target's Info tab.
    ///  2. `Secrets.plist` in the app bundle, with one `GeminiAPIKey` string
    ///     in it. Drop the file next to Info.plist and add it to the target.
    ///
    /// With neither of them the app simply starts with no key, and Settings →
    /// Life AI asks for one. A key typed there lives in the Keychain, never
    /// leaves the device, and always wins over this.
    static var bundledAPIKey: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "GeminiAPIKey") as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // An xcconfig that isn't there leaves the placeholder behind.
            if !trimmed.isEmpty, !trimmed.hasPrefix("$(") { return trimmed }
        }
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let value = plist["GeminiAPIKey"] as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static let providerKey = "lifeAI.provider"
    private static let modelKeyPrefix = "lifeAI.model."

    @Published private(set) var isStreaming = false
    @Published var lastError: String?
    /// Text produced so far for the answer being streamed.
    @Published var partial: String = ""
    /// What it is doing right now ("Reading your material…", "Adding a reminder…").
    @Published var activity: String = ""

    /// Which company answers. Each keeps its own key and its own chosen model.
    @Published var provider: AIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            modelName = Self.savedModel(for: provider)
            models = []
        }
    }

    /// Models the current key can actually use, straight from the provider.
    @Published private(set) var models: [AIModelInfo] = []
    @Published private(set) var isLoadingModels = false

    /// The model in use, remembered per provider.
    @Published var modelName: String {
        didSet {
            UserDefaults.standard.set(modelName, forKey: Self.modelKeyPrefix + provider.rawValue)
        }
    }

    /// The turn in flight. The panel assigns it so Stop can actually stop it.
    var task: Task<Void, Never>?

    private init() {
        let savedProvider = AIProvider(rawValue: UserDefaults.standard.string(forKey: Self.providerKey) ?? "")
        let chosen = savedProvider ?? .gemini
        provider = chosen
        modelName = Self.savedModel(for: chosen)
        // First launch: seed the Keychain from the bundled key so there is
        // nothing to set up. Anything you type in Settings wins from then on.
        if !AIProviderStore.hasKey(.gemini), !Self.bundledAPIKey.isEmpty {
            AIProviderStore.setKey(Self.bundledAPIKey, for: .gemini)
        }
    }

    private static func savedModel(for provider: AIProvider) -> String {
        let saved = UserDefaults.standard.string(forKey: modelKeyPrefix + provider.rawValue) ?? ""
        // Life AI now offers exactly two Gemini models. A name an older build
        // remembered — `gemini-flash-latest`, `gemini-pro-latest`, a dated
        // snapshot — is folded onto the nearest of the two rather than being
        // handed to Google, which would answer 404 on a retired one.
        if provider == .gemini {
            if saved.isEmpty { return GeminiModels.flash }
            return GeminiModels.canonical(saved) ?? GeminiModels.flash
        }
        if !saved.isEmpty { return saved }
        return provider.startingModels.first ?? ""
    }

    // MARK: Configuration

    var config: AIConfig { AIProviderStore.config(for: provider, model: modelName) }
    var isConfigured: Bool { config.isUsable }
    var apiKey: String { AIProviderStore.key(for: provider) }
    var maskedKey: String { AIProviderStore.masked(provider) }

    /// A friendly name for the current provider — the custom endpoint uses
    /// whatever you called it.
    var providerTitle: String {
        provider == .custom ? AIProviderStore.customName : provider.shortTitle
    }

    /// Providers with a key saved, for the quick-switch menu.
    var configuredProviders: [AIProvider] {
        AIProvider.allCases.filter {
            AIProviderStore.hasKey($0) || ($0 == .custom && !AIProviderStore.customBaseURL.isEmpty)
        }
    }

    @MainActor
    func setKey(_ value: String, for provider: AIProvider) {
        AIProviderStore.setKey(value, for: provider)
        if provider == self.provider { models = [] }
        objectWillChange.send()
    }

    private var wire: AIWire { AIWireFactory.make(provider.wire) }

    // MARK: Model discovery
    //
    // Model names come and go — a name that has been retired produces a flat
    // 404. So nothing here is hard-coded as the truth: the app asks the key
    // what it can use and offers exactly that.

    private func fetchModels() async throws -> [AIModelInfo] {
        let config = self.config
        guard config.isUsable else {
            throw NSError(domain: "LifeAI", code: 0, userInfo: [NSLocalizedDescriptionKey:
                provider == .custom
                    ? "Set the address of your endpoint in Settings → Life AI."
                    : "No \(provider.shortTitle) key saved yet."])
        }
        let wire = self.wire
        let request = try wire.modelsRequest(config)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NSError(domain: "LifeAI", code: code, userInfo: [NSLocalizedDescriptionKey:
                Self.readableError(wire.errorMessage(from: data), code: code, provider: provider)])
        }
        return Self.rank(wire.parseModels(data))
    }

    /// Cheapest models first, newest before oldest, so the default is sensible.
    private static func rank(_ models: [AIModelInfo]) -> [AIModelInfo] {
        models.sorted { a, b in sortKey(a.name) < sortKey(b.name) }
    }

    private static func sortKey(_ name: String) -> String {
        let lowered = name.lowercased()
        let family: String
        if lowered.contains("flash-lite") || lowered.contains("haiku") || lowered.contains("mini")
            || lowered.contains("small") { family = "1" }
        else if lowered.contains("flash") || lowered.contains("sonnet")
                    || lowered.contains("fast") { family = "0" }
        else if lowered.contains("pro") || lowered.contains("opus") { family = "2" }
        else { family = "3" }
        // "latest" aliases outlive numbered names, so float them up.
        let stability = lowered.contains("latest") ? "0" : "1"
        return family + stability + name
    }

    @MainActor
    private func adopt(_ found: [AIModelInfo]) {
        guard !found.isEmpty else { return }
        models = found
        // If the remembered model no longer exists, move to the best one that does.
        if !found.contains(where: { $0.name == modelName }) {
            modelName = found[0].name
        }
    }

    /// Loads the model list if it hasn't been loaded for this provider yet.
    @MainActor
    func loadModelsIfNeeded() async {
        guard models.isEmpty, isConfigured, !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let found = try await fetchModels()
            adopt(found)
        } catch {
            // Keep the starting guess; the first request retries on its own.
        }
    }

    @MainActor
    func reloadModels() async -> String? {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let found = try await fetchModels()
            adopt(found)
            if found.isEmpty && modelName.isEmpty {
                return "That endpoint listed no models. Type a model name in Settings."
            }
            return found.isEmpty ? "No chat models were listed for this key." : nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Proves the key works, and fills the model list while it's at it.
    @MainActor
    func verifyKey() async -> String? { await reloadModels() }

    // MARK: Sending

    @MainActor
    func cancel() {
        task?.cancel()
        task = nil
        isStreaming = false
        activity = ""
    }

    /// Runs one turn: streams text into `partial`, calls `perform` for any
    /// action the assistant asks for, and returns the finished answer.
    @MainActor
    func send(history: [(role: String, text: String)],
              prompt: String,
              attachments: [AIAttachment] = [],
              systemPrompt: String,
              retrieve: @escaping @MainActor (String) -> (text: String, sources: [String]),
              perform: @escaping @MainActor (AIAction) -> String) async -> (text: String, sources: [String], actions: [String]) {

        guard isConfigured else {
            return (provider == .custom
                    ? "Set the address of your endpoint in Settings → Life AI."
                    : "I need a \(provider.shortTitle) key before I can answer. Settings → Life AI.",
                    [], [])
        }

        isStreaming = true
        partial = ""
        activity = ""
        lastError = nil
        defer { isStreaming = false; activity = "" }

        await loadModelsIfNeeded()

        var turns: [AITurn] = history.map {
            $0.role == "user" ? .user($0.text) : .assistant($0.text)
        }
        turns.append(.user(prompt, files: attachments))

        var collectedSources: [String] = []
        var performed: [String] = []
        var answer = ""

        // Up to three rounds: it may search, then act, then answer.
        for round in 0..<3 {
            let result: (text: String, calls: [AIToolCall])
            do {
                result = try await streamWithRecovery(turns: turns, systemPrompt: systemPrompt)
            } catch is CancellationError {
                return (answer.isEmpty ? "Stopped." : answer, collectedSources, performed)
            } catch {
                lastError = error.localizedDescription
                let note = answer.isEmpty ? "" : answer + "\n\n"
                return (note + "⚠️ \(error.localizedDescription)", collectedSources, performed)
            }

            if !result.text.isEmpty {
                answer = answer.isEmpty ? result.text : answer + "\n\n" + result.text
            }
            guard !result.calls.isEmpty, round < 2 else { break }

            turns.append(.assistant(result.text, calls: result.calls))

            var results: [AIToolResult] = []
            for call in result.calls {
                if call.name == "search_material" {
                    activity = "Reading your material…"
                    let query = call.args["query"] ?? prompt
                    let found = retrieve(query)
                    collectedSources.append(contentsOf: found.sources)
                    results.append(AIToolResult(id: call.id, name: call.name, content: found.text))
                } else {
                    activity = "Updating your \(Self.activityNoun(call.name))…"
                    let outcome = perform(AIAction(name: call.name, args: call.args))
                    performed.append(outcome)
                    results.append(AIToolResult(id: call.id, name: call.name, content: outcome))
                }
            }
            turns.append(.results(results))
            partial = answer
            activity = ""
        }

        collectedSources = Array(NSOrderedSet(array: collectedSources).compactMap { $0 as? String })
        return (answer.isEmpty ? "(no answer)" : answer, collectedSources, performed)
    }

    /// Streams once; if the model name turns out to be unknown, re-discovers
    /// the list, switches to one that exists, and tries again — so a model the
    /// provider renamed never becomes a dead end.
    @MainActor
    private func streamWithRecovery(turns: [AITurn],
                                    systemPrompt: String) async throws -> (text: String, calls: [AIToolCall]) {
        do {
            return try await stream(turns: turns, systemPrompt: systemPrompt)
        } catch let error as UnknownModelError {
            let before = modelName
            activity = "Finding a model this key can use…"
            let found = (try? await fetchModels()) ?? []
            adopt(found)
            activity = ""
            guard !found.isEmpty else {
                throw NSError(domain: "LifeAI", code: 404, userInfo: [NSLocalizedDescriptionKey:
                    "\(error.message)\n\nThe key also returned no model list, so the key or the address may be the problem. Settings → Life AI → Test."])
            }
            if modelName == before, let first = found.first { modelName = first.name }
            guard modelName != before else {
                throw NSError(domain: "LifeAI", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: error.message])
            }
            partial = ""
            return try await stream(turns: turns, systemPrompt: systemPrompt)
        }
    }

    // MARK: One streamed request

    @MainActor
    private func stream(turns: [AITurn],
                        systemPrompt: String) async throws -> (text: String, calls: [AIToolCall]) {
        let config = self.config
        guard !config.model.isEmpty else {
            throw NSError(domain: "LifeAI", code: 0, userInfo: [NSLocalizedDescriptionKey:
                "No model chosen. Settings → Life AI → Model."])
        }
        let wire = self.wire
        wire.reset()

        let request = try wire.chatRequest(config, system: systemPrompt,
                                           turns: turns, tools: Self.tools)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // Error responses are plain JSON, not SSE — collect and report.
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 8192 { break } }
            let message = Self.readableError(wire.errorMessage(from: data), code: code, provider: config.provider)
            if code == 404 || Self.looksLikeUnknownModel(message) {
                throw UnknownModelError(message: message)
            }
            throw NSError(domain: "LifeAI", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }

        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let piece = try wire.consume(line)
            if !piece.isEmpty {
                text += piece
                partial += piece
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), wire.calls)
    }

    /// Some providers answer 400, not 404, for a model that doesn't exist.
    private static func looksLikeUnknownModel(_ message: String) -> Bool {
        let lowered = message.lowercased()
        guard lowered.contains("model") else { return false }
        return lowered.contains("not found") || lowered.contains("does not exist")
            || lowered.contains("unknown") || lowered.contains("invalid model")
            || lowered.contains("no such")
    }

    private static func activityNoun(_ tool: String) -> String {
        switch tool {
        case "add_reminder":       return "reminders"
        case "add_schedule_block": return "schedule"
        case "add_calendar_mark":  return "calendar"
        case "add_habit":          return "habits"
        case "add_syllabus_topic": return "syllabus"
        case "add_subject_note":   return "notes"
        default:                   return "app"
        }
    }

    /// The provider's own wording, plus a line about what to do — never a
    /// guess that hides what actually went wrong.
    private static func readableError(_ message: String?, code: Int, provider: AIProvider) -> String {
        let detail = message ?? "\(provider.shortTitle) returned \(code)."
        switch code {
        case 400:
            let lowered = detail.lowercased()
            if lowered.contains("api key") || lowered.contains("api_key") {
                return "\(detail)\n\nCheck the key in Settings → Life AI."
            }
            return detail
        case 401:
            return "\(detail)\n\nThat key was rejected. Settings → Life AI → Change."
        case 403:
            return "\(detail)\n\nThe key may be restricted, or the API may not be enabled for its account."
        case 404:
            return "\(detail)\n\nPicking a different model from the ⋯ menu usually fixes this."
        case 429:
            return "\(detail)\n\nYou're being rate-limited — wait a minute, or switch to a smaller model."
        case 500...599:
            return "\(detail)\n\nThat's the provider's end, not yours. Try again shortly."
        default:
            return detail
        }
    }

    // MARK: Tools
    //
    // Declared once, in neutral form. Each wire translates them into its own
    // dialect, so the assistant can act on the app whichever provider answers.

    static let tools: [AIToolSpec] = [
        AIToolSpec(name: "search_material",
                   description: "Search the user's own uploaded course material (PDFs, PowerPoints, Word files, syllabus topics and saved links) for passages relevant to a question. Use this whenever the question is about their specific subjects, lectures, syllabus or notes rather than general knowledge. Do NOT use it for a file attached to the current message — that is already in front of you.",
                   fields: [
                    .string("query", "What to look for, in the language the material is likely written in.", required: true)
                   ]),

        AIToolSpec(name: "add_reminder",
                   description: "Add a study reminder to the Study page. Use for anything the user should do that is not tied to a clock time.",
                   fields: [
                    .string("title", "Short reminder text, e.g. 'Finish CV lab report'.", required: true)
                   ]),

        AIToolSpec(name: "add_schedule_block",
                   description: "Add a timed block to the Schedule page for a recurring part of the day.",
                   fields: [
                    .string("title", "What the block is for.", required: true),
                    .string("start", "Start time as HH:MM in 24-hour form.", required: true),
                    .string("end", "End time as HH:MM in 24-hour form.", required: true),
                    .bool("reminder", "Whether to notify the user before it starts.")
                   ]),

        AIToolSpec(name: "add_calendar_mark",
                   description: "Mark a specific date on the Calendar page — an exam, a deadline, a submission, a holiday.",
                   fields: [
                    .string("date", "The date as YYYY-MM-DD.", required: true),
                    .string("title", "What is happening that day.", required: true),
                    .string("kind", "'event' for something informational, 'habit' for a one-off task to tick off that day.")
                   ]),

        AIToolSpec(name: "add_habit",
                   description: "Add a habit to track daily or on chosen days.",
                   fields: [
                    .string("name", "The habit, e.g. 'Revise DSA for 30 minutes'.", required: true),
                    .string("frequency", "One of: daily, weekdays, weekends.")
                   ]),

        AIToolSpec(name: "add_syllabus_topic",
                   description: "Add a topic to a subject's syllabus checklist.",
                   fields: [
                    .string("subject", "The subject name exactly as it appears in the app.", required: true),
                    .string("title", "The topic to add.", required: true)
                   ]),

        AIToolSpec(name: "add_subject_note",
                   description: "Append text to a subject's Notes. Use when the user asks you to save a summary, explanation or set of notes into a subject. Only use it when they ask — they can also save any answer themselves with the button under it.",
                   fields: [
                    .string("subject", "The subject name exactly as it appears in the app.", required: true),
                    .string("heading", "A short title for this note."),
                    .string("body", "The note itself, in Markdown.", required: true)
                   ])
    ]

    // MARK: Personality

    /// The standing instructions. `snapshot` is the app-data digest built by
    /// `AIContextBuilder` — it changes every time you send a message.
    static func systemPrompt(snapshot: String, spoken: Bool = false) -> String {
        let voiceRule = spoken ? """

        • This answer will be READ ALOUD, so write it to be heard: short \
        sentences, no Markdown headings, no bullet lists, no tables, no code \
        blocks unless he asked for code. Two or three sentences unless he asked \
        for more. Say numbers and dates the way a person would say them.
        """ : ""

        return """
        You are Life AI, the assistant built into LifeTracker — a study and life \
        tracking app made by Pranav Ashok Pande, a student at D Y Patil \
        International University. You are talking to him inside the app.

        You are a full general-purpose assistant first: write and debug code in \
        any language, explain concepts, translate, draft text, do maths, answer \
        ordinary questions. Do all of that as well as you possibly can, with no \
        reference to the app unless it is relevant.

        On top of that, you can see his tracked data (below), read files he \
        attaches, search his own course material, and change things in the app \
        through the tools you have been given.

        How to behave:
        • Be concise and direct. No preamble, no "Great question!", no restating \
          what he asked. Give the answer, then stop.
        • Use his real data whenever it makes the answer better. Name actual \
          subjects, habits and deadlines rather than speaking generally.
        • When a file is attached to the message, work from that file. When he \
          asks about his subjects, lectures or syllabus in general, call \
          search_material first and answer from what comes back. Say plainly when \
          the material does not cover something rather than filling the gap.
        • Summarising a document: lead with what it is in one line, then the \
          substance as short sections, then anything that looks examinable. Keep \
          the document's own terminology and its language.
        • When he asks you to plan, remind, schedule or mark something, use the \
          tools — do not just describe what he should add. One tool call per \
          item, then confirm briefly in one line.
        • Never invent a number about his progress. Everything factual about him \
          comes from the snapshot below, an attached file, or search_material.
        • Format with Markdown. Fenced code blocks with a language tag for code. \
          Keep lists short.
        • Match his language: reply in English, Korean or Chinese depending on how \
          he writes, or in the language of the document he attached.
        • His Journal is private and deliberately not shown to you. If he asks \
          about it, say so — do not guess at its contents.\(voiceRule)

        Today is \(Self.longDate(.now)).

        ────────────────────────────────────
        HIS DATA RIGHT NOW
        ────────────────────────────────────
        \(snapshot)
        """
    }

    static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f.string(from: date)
    }
}
