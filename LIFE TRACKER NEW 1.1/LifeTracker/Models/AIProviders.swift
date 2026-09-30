import Foundation

// MARK: - Which AI answers
//
// Life AI is not tied to one company. Paste a key from Google, OpenAI,
// Anthropic or xAI — or point it at anything that speaks the OpenAI chat API
// (DeepSeek, Groq, Mistral, OpenRouter, Together, a local Ollama or LM Studio)
// — and the rest of the app behaves identically.
//
// Under the surface there are only three shapes of request, in AIWire.swift.
// Everything above this line speaks the neutral types at the bottom of this
// file, so adding a provider means naming it here, not rewriting the client.

enum AIWireFormat: String, Codable {
    /// Google: `:streamGenerateContent`, parts, functionCall / functionResponse.
    case gemini
    /// OpenAI chat completions — also xAI, DeepSeek, Groq, Ollama, LM Studio…
    case openAIChat
    /// Anthropic Messages: content blocks, tool_use / tool_result.
    case anthropicMessages
}

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case gemini
    case openAI
    case anthropic
    case xai
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini:    return "Google Gemini"
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .xai:       return "xAI Grok"
        case .custom:    return "Other (OpenAI-compatible)"
        }
    }

    /// Short name for the panel header.
    var shortTitle: String {
        switch self {
        case .gemini:    return "Gemini"
        case .openAI:    return "OpenAI"
        case .anthropic: return "Claude"
        case .xai:       return "Grok"
        case .custom:    return "Custom"
        }
    }

    var blurb: String {
        switch self {
        case .gemini:    return "Generous free tier, reads PDFs and images directly"
        case .openAI:    return "GPT models"
        case .anthropic: return "Claude models — strong at long documents and code"
        case .xai:       return "Grok models"
        case .custom:    return "DeepSeek, Groq, Mistral, OpenRouter, Ollama, LM Studio…"
        }
    }

    var wire: AIWireFormat {
        switch self {
        case .gemini:    return .gemini
        case .anthropic: return .anthropicMessages
        case .openAI, .xai, .custom: return .openAIChat
        }
    }

    /// Where the API lives. `custom` is whatever you type in Settings.
    var defaultBaseURL: String {
        switch self {
        case .gemini:    return "https://generativelanguage.googleapis.com/v1beta"
        case .openAI:    return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .xai:       return "https://api.x.ai/v1"
        case .custom:    return ""
        }
    }

    /// Where to go and get a key.
    var consoleURL: String {
        switch self {
        case .gemini:    return "https://aistudio.google.com/apikey"
        case .openAI:    return "https://platform.openai.com/api-keys"
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .xai:       return "https://console.x.ai"
        case .custom:    return ""
        }
    }

    var keyHint: String {
        switch self {
        case .gemini:    return "Starts with AIza… or AQ.…"
        case .openAI:    return "Starts with sk-…"
        case .anthropic: return "Starts with sk-ant-…"
        case .xai:       return "Starts with xai-…"
        case .custom:    return "Whatever your endpoint expects — leave blank for a local server"
        }
    }

    /// Keychain account name. Keys are stored per provider, so switching back
    /// and forth never loses one.
    var keychainKey: String {
        switch self {
        case .gemini:    return "ai.key.gemini"
        case .openAI:    return "ai.key.openai"
        case .anthropic: return "ai.key.anthropic"
        case .xai:       return "ai.key.xai"
        case .custom:    return "ai.key.custom"
        }
    }

    /// Used before a model list has been fetched — and as a fallback for
    /// endpoints with no `/models` route at all.
    var startingModels: [String] {
        switch self {
        case .gemini:    return GeminiModels.allowed
        case .openAI:    return ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o"]
        case .anthropic: return ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-1"]
        case .xai:       return ["grok-4-fast", "grok-4", "grok-3-mini"]
        case .custom:    return []
        }
    }

    /// Whether this provider can be sent raw image / PDF bytes. Where it can't,
    /// files still go in as text extracted on the device.
    var readsImages: Bool { self != .custom }
    var readsPDFs: Bool { self == .gemini || self == .anthropic }
}

// MARK: - The Gemini models Life AI offers
//
// Google's /models route answers with three dozen entries — every preview,
// every dated snapshot, every experiment. The picker only ever needs the two
// worth using day to day, so the list is stated here and everything Google
// sends back is matched against it.
//
// Flash is the one to answer with; Flash Lite is cheaper and quicker for
// short questions. To offer a different pair, change these two lines: the
// picker, the fallback list and the model that's chosen on a fresh install
// all read from here.
enum GeminiModels {
    static let flash = "gemini-2.5-flash"
    static let flashLite = "gemini-2.5-flash-lite"

    static var allowed: [String] { [flash, flashLite] }

    /// Google names one model several ways — `gemini-2.5-flash`,
    /// `gemini-2.5-flash-002`, `gemini-flash-latest`. Anything that resolves
    /// to one of the two above is folded onto it; everything else is dropped.
    static func canonical(_ rawName: String) -> String? {
        let name = rawName.replacingOccurrences(of: "models/", with: "").lowercased()
        // Lite first: "…flash-lite" contains "…flash" too.
        if name.contains("flash-lite") || name.contains("flash-8b") { return flashLite }
        if name.contains("flash") { return flash }
        return nil
    }

    /// What to show in the picker.
    static func title(for name: String) -> String {
        name == flashLite ? "2.5 Flash Lite" : "2.5 Flash"
    }

    static func detail(for name: String) -> String {
        name == flashLite
            ? "Quickest and cheapest — good for short questions."
            : "The everyday model: fast, and it reads images and PDFs."
    }
}

// MARK: - Everything needed to make one call

struct AIConfig {
    let provider: AIProvider
    let baseURL: String
    let apiKey: String
    let model: String

    var hasKey: Bool { !apiKey.isEmpty }
    /// A local server usually needs no key at all.
    var isLocal: Bool {
        baseURL.contains("localhost") || baseURL.contains("127.0.0.1") || baseURL.contains("0.0.0.0")
    }
    var isUsable: Bool { !baseURL.isEmpty && (hasKey || isLocal) }
}

// MARK: - Where keys and settings live

enum AIProviderStore {
    private static let customBaseKey = "lifeAI.customBaseURL"
    private static let customNameKey = "lifeAI.customName"
    /// Keys written by builds before Life AI had more than one provider.
    private static let legacyGeminiKey = "gemini.apiKey"

    /// Every Keychain account holding a key — used by export so all of them
    /// travel together when you tick "include logins".
    static var allKeychainKeys: [String] {
        AIProvider.allCases.map(\.keychainKey) + [legacyGeminiKey]
    }

    static func key(for provider: AIProvider) -> String {
        let stored = (Keychain.get(provider.keychainKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        // A Gemini key saved by an earlier build still counts.
        if provider == .gemini {
            return (Keychain.get(legacyGeminiKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func setKey(_ value: String, for provider: AIProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed.isEmpty ? nil : trimmed, for: provider.keychainKey)
        if provider == .gemini, trimmed.isEmpty { Keychain.set(nil, for: legacyGeminiKey) }
    }

    static func hasKey(_ provider: AIProvider) -> Bool { !key(for: provider).isEmpty }

    /// Base URL for a custom endpoint, trimmed of a trailing slash.
    static var customBaseURL: String {
        get {
            (UserDefaults.standard.string(forKey: customBaseKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            var cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            while cleaned.hasSuffix("/") { cleaned.removeLast() }
            UserDefaults.standard.set(cleaned, forKey: customBaseKey)
        }
    }

    /// What to call the custom endpoint in the interface.
    static var customName: String {
        get {
            let stored = (UserDefaults.standard.string(forKey: customNameKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? "Custom" : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: customNameKey) }
    }

    static func baseURL(for provider: AIProvider) -> String {
        provider == .custom ? customBaseURL : provider.defaultBaseURL
    }

    static func config(for provider: AIProvider, model: String) -> AIConfig {
        AIConfig(provider: provider,
                 baseURL: baseURL(for: provider),
                 apiKey: key(for: provider),
                 model: model)
    }

    /// Masked for display — never shows the whole thing.
    static func masked(_ provider: AIProvider) -> String {
        let key = key(for: provider)
        guard key.count > 10 else { return key.isEmpty ? "" : "••••••" }
        return key.prefix(6) + "…" + key.suffix(4)
    }
}

// MARK: - Neutral types every provider is translated into

struct AIModelInfo: Identifiable, Hashable {
    let name: String
    let displayName: String
    let detail: String

    var id: String { name }

    /// "Gemini 2.5 Flash" → "2.5 Flash"; "claude-sonnet-4-5" → "sonnet-4-5".
    var shortTitle: String {
        let title = displayName.isEmpty ? name : displayName
        return title
            .replacingOccurrences(of: "Gemini ", with: "")
            .replacingOccurrences(of: "gemini-", with: "")
            .replacingOccurrences(of: "claude-", with: "")
    }
}

struct AIToolCall {
    /// The provider's own id for this call, echoed back with the result.
    let id: String
    let name: String
    let args: [String: String]
}

struct AIToolResult {
    let id: String
    let name: String
    let content: String
}

enum AITurnKind {
    case user, assistant, toolResults
}

/// One entry in the conversation, in a form every wire can encode.
struct AITurn {
    var kind: AITurnKind
    var text: String = ""
    var files: [AIAttachment] = []
    var calls: [AIToolCall] = []
    var results: [AIToolResult] = []

    static func user(_ text: String, files: [AIAttachment] = []) -> AITurn {
        AITurn(kind: .user, text: text, files: files)
    }
    static func assistant(_ text: String, calls: [AIToolCall] = []) -> AITurn {
        AITurn(kind: .assistant, text: text, calls: calls)
    }
    static func results(_ results: [AIToolResult]) -> AITurn {
        AITurn(kind: .toolResults, results: results)
    }
}

/// One thing the assistant may ask the app to do. Declared once; each wire
/// translates it into its own JSON schema dialect.
struct AIToolSpec {
    struct Field {
        let name: String
        let type: String        // "string" or "boolean"
        let description: String
        let required: Bool

        static func string(_ name: String, _ description: String, required: Bool = false) -> Field {
            Field(name: name, type: "string", description: description, required: required)
        }
        static func bool(_ name: String, _ description: String, required: Bool = false) -> Field {
            Field(name: name, type: "boolean", description: description, required: required)
        }
    }
    let name: String
    let description: String
    let fields: [Field]

    var requiredNames: [String] { fields.filter(\.required).map(\.name) }

    /// The JSON-Schema object every provider wants, give or take a case
    /// convention (Gemini shouts its type names; the others don't).
    func schema(uppercaseTypes: Bool) -> [String: Any] {
        var properties: [String: Any] = [:]
        for field in fields {
            properties[field.name] = [
                "type": uppercaseTypes ? field.type.uppercased() : field.type,
                "description": field.description
            ]
        }
        var out: [String: Any] = [
            "type": uppercaseTypes ? "OBJECT" : "object",
            "properties": properties
        ]
        if !requiredNames.isEmpty { out["required"] = requiredNames }
        return out
    }
}
