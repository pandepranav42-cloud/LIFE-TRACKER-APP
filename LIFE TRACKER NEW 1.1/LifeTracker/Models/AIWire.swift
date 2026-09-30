import Foundation

// MARK: - The three shapes of request
//
// Every provider Life AI talks to speaks one of three dialects:
//
//   Gemini             parts, functionCall / functionResponse
//   OpenAI chat        messages, tool_calls / role:"tool"   (also Grok, DeepSeek,
//                      Groq, Mistral, OpenRouter, Ollama, LM Studio…)
//   Anthropic Messages content blocks, tool_use / tool_result
//
// Each one below turns the neutral `AITurn` / `AIToolSpec` types from
// AIProviders.swift into its own JSON, and turns its own streamed events back
// into plain text and tool calls. Nothing above this file knows the difference.

protocol AIWire: AnyObject {
    /// Ask the endpoint which models the key may use.
    func modelsRequest(_ config: AIConfig) throws -> URLRequest
    func parseModels(_ data: Data) -> [AIModelInfo]

    /// One streaming chat request.
    func chatRequest(_ config: AIConfig, system: String,
                     turns: [AITurn], tools: [AIToolSpec]) throws -> URLRequest

    /// Feed one SSE line; returns whatever text it contributed.
    func consume(_ line: String) throws -> String

    /// Tool calls gathered so far in this stream.
    var calls: [AIToolCall] { get }

    /// Start a fresh stream.
    func reset()

    /// Pull the error message out of a non-2xx body.
    func errorMessage(from data: Data) -> String?
}

enum AIWireFactory {
    static func make(_ format: AIWireFormat) -> AIWire {
        switch format {
        case .gemini:            return GeminiWire()
        case .openAIChat:        return OpenAIWire()
        case .anthropicMessages: return AnthropicWire()
        }
    }
}

// MARK: Shared helpers

enum AIJSON {
    static func body(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Payload of an SSE `data:` line, or nil for anything else.
    static func sseData(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
              let data = payload.data(using: .utf8) else { return nil }
        return object(data)
    }

    /// Tool arguments arrive as JSON; the app wants plain strings.
    static func flatten(_ any: Any?) -> [String: String] {
        var out: [String: String] = [:]
        guard let dictionary = any as? [String: Any] else { return out }
        for (key, value) in dictionary {
            switch value {
            case let text as String: out[key] = text
            // Numbers must be matched before Bool: JSONSerialization hands back
            // NSNumber, and `NSNumber(1) as? Bool` succeeds — so 1 would arrive
            // as "true" if the Bool case came first.
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                out[key] = number.stringValue
            case let flag as Bool: out[key] = flag ? "true" : "false"
            default:
                if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                   let text = String(data: data, encoding: .utf8) { out[key] = text }
            }
        }
        return out
    }

    static func flatten(jsonString: String) -> [String: String] {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return flatten(object)
    }

    /// `{"error": {"message": …}}`, `{"error": "…"}` or `{"message": …}`.
    static func errorText(_ data: Data) -> String? {
        guard let root = object(data) else {
            let raw = String(data: data.prefix(400), encoding: .utf8) ?? ""
            return raw.isEmpty ? nil : raw
        }
        if let error = root["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            if let type = error["type"] as? String { return type }
        }
        if let error = root["error"] as? String { return error }
        if let message = root["message"] as? String { return message }
        return nil
    }

    static func request(_ url: URL, method: String = "GET", headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw NSError(domain: "LifeAI", code: 0, userInfo: [NSLocalizedDescriptionKey:
                "\"\(string)\" isn't a valid address."])
        }
        return url
    }
}

// MARK: - Google Gemini

final class GeminiWire: AIWire {
    private(set) var calls: [AIToolCall] = []
    func reset() { calls = [] }
    func errorMessage(from data: Data) -> String? { AIJSON.errorText(data) }

    func modelsRequest(_ config: AIConfig) throws -> URLRequest {
        let url = try AIJSON.url("\(config.baseURL)/models?pageSize=200&key=\(config.apiKey)")
        return AIJSON.request(url, headers: ["x-goog-api-key": config.apiKey])
    }

    func parseModels(_ data: Data) -> [AIModelInfo] {
        guard let root = AIJSON.object(data),
              let models = root["models"] as? [[String: Any]] else { return [] }
        var out: [AIModelInfo] = []
        for model in models {
            guard let raw = model["name"] as? String else { continue }
            let name = raw.replacingOccurrences(of: "models/", with: "")
            let methods = (model["supportedGenerationMethods"] as? [String]) ?? []
            guard methods.contains("generateContent") || methods.contains("streamGenerateContent") else { continue }
            guard name.contains("gemini") else { continue }
            let lowered = name.lowercased()
            let unwanted = ["embedding", "aqa", "image-generation", "-tts", "-live-", "native-audio"]
            guard !unwanted.contains(where: { lowered.contains($0) }) else { continue }
            out.append(AIModelInfo(name: name,
                                   displayName: (model["displayName"] as? String) ?? name,
                                   detail: (model["description"] as? String) ?? ""))
        }
        return out
    }

    func chatRequest(_ config: AIConfig, system: String,
                     turns: [AITurn], tools: [AIToolSpec]) throws -> URLRequest {
        let url = try AIJSON.url(
            "\(config.baseURL)/models/\(config.model):streamGenerateContent?alt=sse&key=\(config.apiKey)")
        var request = AIJSON.request(url, method: "POST", headers: [
            "Content-Type": "application/json",
            "x-goog-api-key": config.apiKey
        ])
        request.timeoutInterval = 180

        var contents: [[String: Any]] = []
        for turn in turns {
            switch turn.kind {
            case .user:
                var parts: [[String: Any]] = []
                for file in turn.files { parts.append(contentsOf: Self.parts(for: file, config: config)) }
                if !turn.text.isEmpty { parts.append(["text": turn.text]) }
                if parts.isEmpty { parts = [["text": " "]] }
                contents.append(["role": "user", "parts": parts])
            case .assistant:
                var parts: [[String: Any]] = []
                if !turn.text.isEmpty { parts.append(["text": turn.text]) }
                for call in turn.calls {
                    parts.append(["functionCall": ["name": call.name, "args": call.args]])
                }
                if parts.isEmpty { parts = [["text": " "]] }
                contents.append(["role": "model", "parts": parts])
            case .toolResults:
                let parts = turn.results.map { result -> [String: Any] in
                    ["functionResponse": ["name": result.name, "response": ["result": result.content]]]
                }
                contents.append(["role": "user", "parts": parts])
            }
        }

        var body: [String: Any] = [
            "contents": contents,
            "systemInstruction": ["parts": [["text": system]]],
            "generationConfig": ["temperature": 0.7, "maxOutputTokens": 8192]
        ]
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map { spec -> [String: Any] in
                ["name": spec.name,
                 "description": spec.description,
                 "parameters": spec.schema(uppercaseTypes: true)]
            }]]
        }
        request.httpBody = try AIJSON.body(body)
        return request
    }

    private static func parts(for file: AIAttachment, config: AIConfig) -> [[String: Any]] {
        if let text = file.text, !text.isEmpty {
            return [["text": "--- Attached file: \(file.name) ---\n\(text)\n--- end of \(file.name) ---"]]
        }
        if let data = file.data, let mime = file.mimeType {
            return [["inlineData": ["mimeType": mime, "data": data.base64EncodedString()]]]
        }
        return [["text": "(\(file.name) was attached but could not be read: \(file.note))"]]
    }

    func consume(_ line: String) throws -> String {
        guard let root = AIJSON.sseData(line) else { return "" }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            throw NSError(domain: "LifeAI", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return "" }

        var text = ""
        for part in parts {
            if let piece = part["text"] as? String { text += piece }
            if let call = part["functionCall"] as? [String: Any],
               let name = call["name"] as? String {
                // Gemini gives no id; the name is enough to match the response.
                calls.append(AIToolCall(id: name, name: name, args: AIJSON.flatten(call["args"])))
            }
        }
        return text
    }
}

// MARK: - OpenAI chat completions (and everything that copies it)

final class OpenAIWire: AIWire {
    private(set) var calls: [AIToolCall] = []
    /// Tool calls stream in fragments, keyed by their index in the response.
    private var building: [Int: (id: String, name: String, arguments: String)] = [:]

    func reset() { calls = []; building = [:] }
    func errorMessage(from data: Data) -> String? { AIJSON.errorText(data) }

    private func headers(_ config: AIConfig) -> [String: String] {
        var out = ["Content-Type": "application/json"]
        if config.hasKey { out["Authorization"] = "Bearer \(config.apiKey)" }
        return out
    }

    func modelsRequest(_ config: AIConfig) throws -> URLRequest {
        AIJSON.request(try AIJSON.url("\(config.baseURL)/models"), headers: headers(config))
    }

    func parseModels(_ data: Data) -> [AIModelInfo] {
        guard let root = AIJSON.object(data) else { return [] }
        let rows = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        var out: [AIModelInfo] = []
        for row in rows {
            guard let id = (row["id"] as? String) ?? (row["name"] as? String) else { continue }
            let lowered = id.lowercased()
            // Drop everything that isn't a chat model.
            let unwanted = ["embedding", "whisper", "tts", "dall-e", "moderation",
                            "audio", "realtime", "image", "transcribe", "rerank", "search"]
            guard !unwanted.contains(where: { lowered.contains($0) }) else { continue }
            out.append(AIModelInfo(name: id,
                                   displayName: (row["display_name"] as? String) ?? id,
                                   detail: (row["description"] as? String) ?? ""))
        }
        return out
    }

    func chatRequest(_ config: AIConfig, system: String,
                     turns: [AITurn], tools: [AIToolSpec]) throws -> URLRequest {
        var request = AIJSON.request(try AIJSON.url("\(config.baseURL)/chat/completions"),
                                     method: "POST", headers: headers(config))
        request.timeoutInterval = 180

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            switch turn.kind {
            case .user:
                if turn.files.isEmpty {
                    messages.append(["role": "user", "content": turn.text])
                } else {
                    var content: [[String: Any]] = []
                    for file in turn.files {
                        if let text = file.text, !text.isEmpty {
                            content.append(["type": "text",
                                            "text": "--- Attached file: \(file.name) ---\n\(text)\n--- end of \(file.name) ---"])
                        } else if let data = file.data, let mime = file.mimeType, mime.hasPrefix("image/") {
                            content.append(["type": "image_url",
                                            "image_url": ["url": "data:\(mime);base64,\(data.base64EncodedString())"]])
                        } else {
                            content.append(["type": "text",
                                            "text": "(\(file.name) was attached but this provider can't read it: \(file.note))"])
                        }
                    }
                    content.append(["type": "text", "text": turn.text])
                    messages.append(["role": "user", "content": content])
                }
            case .assistant:
                var message: [String: Any] = ["role": "assistant"]
                message["content"] = turn.text.isEmpty ? NSNull() : turn.text
                if !turn.calls.isEmpty {
                    message["tool_calls"] = turn.calls.map { call -> [String: Any] in
                        let arguments = (try? JSONSerialization.data(withJSONObject: call.args, options: []))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        return ["id": call.id, "type": "function",
                                "function": ["name": call.name, "arguments": arguments]]
                    }
                }
                messages.append(message)
            case .toolResults:
                for result in turn.results {
                    messages.append(["role": "tool",
                                     "tool_call_id": result.id,
                                     "content": result.content])
                }
            }
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true,
            "temperature": 0.7
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { spec -> [String: Any] in
                ["type": "function",
                 "function": ["name": spec.name,
                              "description": spec.description,
                              "parameters": spec.schema(uppercaseTypes: false)]]
            }
        }
        request.httpBody = try AIJSON.body(body)
        return request
    }

    func consume(_ line: String) throws -> String {
        guard let root = AIJSON.sseData(line) else {
            // `data: [DONE]` ends the stream; finish any half-built tool call.
            if line.contains("[DONE]") { flush() }
            return ""
        }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            throw NSError(domain: "LifeAI", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let choices = root["choices"] as? [[String: Any]], let choice = choices.first else { return "" }
        let delta = (choice["delta"] as? [String: Any]) ?? [:]

        if let fragments = delta["tool_calls"] as? [[String: Any]] {
            for fragment in fragments {
                let index = (fragment["index"] as? Int) ?? 0
                var entry = building[index] ?? (id: "", name: "", arguments: "")
                if let id = fragment["id"] as? String, !id.isEmpty { entry.id = id }
                if let function = fragment["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                    if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                }
                building[index] = entry
            }
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty { flush() }

        return (delta["content"] as? String) ?? ""
    }

    /// Turns the accumulated fragments into finished calls.
    private func flush() {
        for (_, entry) in building.sorted(by: { $0.key < $1.key }) {
            guard !entry.name.isEmpty else { continue }
            calls.append(AIToolCall(id: entry.id.isEmpty ? entry.name : entry.id,
                                    name: entry.name,
                                    args: AIJSON.flatten(jsonString: entry.arguments)))
        }
        building = [:]
    }
}

// MARK: - Anthropic Messages

final class AnthropicWire: AIWire {
    private(set) var calls: [AIToolCall] = []
    private var building: [Int: (id: String, name: String, json: String)] = [:]

    private static let version = "2023-06-01"

    func reset() { calls = []; building = [:] }
    func errorMessage(from data: Data) -> String? { AIJSON.errorText(data) }

    private func headers(_ config: AIConfig) -> [String: String] {
        var out = ["Content-Type": "application/json",
                   "anthropic-version": Self.version]
        if config.hasKey { out["x-api-key"] = config.apiKey }
        return out
    }

    func modelsRequest(_ config: AIConfig) throws -> URLRequest {
        AIJSON.request(try AIJSON.url("\(config.baseURL)/models?limit=100"), headers: headers(config))
    }

    func parseModels(_ data: Data) -> [AIModelInfo] {
        guard let root = AIJSON.object(data),
              let rows = root["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return AIModelInfo(name: id,
                               displayName: (row["display_name"] as? String) ?? id,
                               detail: "")
        }
    }

    func chatRequest(_ config: AIConfig, system: String,
                     turns: [AITurn], tools: [AIToolSpec]) throws -> URLRequest {
        var request = AIJSON.request(try AIJSON.url("\(config.baseURL)/messages"),
                                     method: "POST", headers: headers(config))
        request.timeoutInterval = 180

        var messages: [[String: Any]] = []
        for turn in turns {
            switch turn.kind {
            case .user:
                var content: [[String: Any]] = []
                for file in turn.files {
                    if let text = file.text, !text.isEmpty {
                        content.append(["type": "text",
                                        "text": "--- Attached file: \(file.name) ---\n\(text)\n--- end of \(file.name) ---"])
                    } else if let data = file.data, let mime = file.mimeType {
                        let encoded = data.base64EncodedString()
                        if mime == "application/pdf" {
                            content.append(["type": "document",
                                            "source": ["type": "base64", "media_type": mime, "data": encoded]])
                        } else if mime.hasPrefix("image/") {
                            content.append(["type": "image",
                                            "source": ["type": "base64", "media_type": mime, "data": encoded]])
                        }
                    } else {
                        content.append(["type": "text",
                                        "text": "(\(file.name) was attached but could not be read: \(file.note))"])
                    }
                }
                content.append(["type": "text", "text": turn.text.isEmpty ? " " : turn.text])
                messages.append(["role": "user", "content": content])

            case .assistant:
                var content: [[String: Any]] = []
                if !turn.text.isEmpty { content.append(["type": "text", "text": turn.text]) }
                for call in turn.calls {
                    content.append(["type": "tool_use", "id": call.id,
                                    "name": call.name, "input": call.args])
                }
                if content.isEmpty { content = [["type": "text", "text": " "]] }
                messages.append(["role": "assistant", "content": content])

            case .toolResults:
                let content = turn.results.map { result -> [String: Any] in
                    ["type": "tool_result", "tool_use_id": result.id, "content": result.content]
                }
                messages.append(["role": "user", "content": content])
            }
        }

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": 8192,
            "stream": true,
            "system": system,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { spec -> [String: Any] in
                ["name": spec.name,
                 "description": spec.description,
                 "input_schema": spec.schema(uppercaseTypes: false)]
            }
        }
        request.httpBody = try AIJSON.body(body)
        return request
    }

    func consume(_ line: String) throws -> String {
        // Anthropic sends `event:` lines too; only the data carries content.
        guard let root = AIJSON.sseData(line) else { return "" }
        let type = (root["type"] as? String) ?? ""

        switch type {
        case "error":
            let message = (root["error"] as? [String: Any])?["message"] as? String
            throw NSError(domain: "LifeAI", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: message ?? "The provider reported an error."])

        case "content_block_start":
            let index = (root["index"] as? Int) ?? 0
            guard let block = root["content_block"] as? [String: Any],
                  (block["type"] as? String) == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String else { return "" }
            building[index] = (id: id, name: name, json: "")
            return ""

        case "content_block_delta":
            let index = (root["index"] as? Int) ?? 0
            guard let delta = root["delta"] as? [String: Any] else { return "" }
            if let text = delta["text"] as? String { return text }
            if let partial = delta["partial_json"] as? String, var entry = building[index] {
                entry.json += partial
                building[index] = entry
            }
            return ""

        case "content_block_stop":
            let index = (root["index"] as? Int) ?? 0
            if let entry = building.removeValue(forKey: index), !entry.name.isEmpty {
                calls.append(AIToolCall(id: entry.id, name: entry.name,
                                        args: AIJSON.flatten(jsonString: entry.json.isEmpty ? "{}" : entry.json)))
            }
            return ""

        default:
            return ""
        }
    }
}
