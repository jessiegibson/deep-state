import Foundation

// MARK: - Provider Type Enum

enum LLMProviderType: String, CaseIterable, Identifiable, Codable {
    case anthropic = "Anthropic"
    case openAI    = "OpenAI"
    case gemini    = "Gemini"
    case ollama    = "Ollama (Local)"
    case kimi      = "KIMI (Moonshot)"

    var id: String { rawValue }
    var requiresAPIKey: Bool { self != .ollama }
    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-..."
        case .openAI:    return "sk-..."
        case .gemini:    return "AIza..."
        case .ollama:    return "(no key needed)"
        case .kimi:      return "sk-..."
        }
    }
}

// MARK: - LLM Provider Protocol

protocol LLMProvider {
    var displayName: String { get }
    func complete(systemPrompt: String, userContent: String) async throws -> String
}

// MARK: - Anthropic (Claude)

class AnthropicProvider: LLMProvider {
    let displayName = "Anthropic"
    private let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    func complete(systemPrompt: String, userContent: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 2048,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userContent]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTPStatus(response, data: data, provider: "Anthropic")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String else {
            throw LLMError.parseError("Anthropic: unexpected response format")
        }
        return text
    }
}

// MARK: - OpenAI

class OpenAIProvider: LLMProvider {
    let displayName = "OpenAI"
    private let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    func complete(systemPrompt: String, userContent: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")

        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": 2048
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTPStatus(response, data: data, provider: "OpenAI")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.parseError("OpenAI: unexpected response format")
        }
        return text
    }
}

// MARK: - Gemini

class GeminiProvider: LLMProvider {
    let displayName = "Gemini"
    private let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    func complete(systemPrompt: String, userContent: String) async throws -> String {
        let model = "gemini-2.0-flash"
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        let url = URL(string: urlString)!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        // Gemini uses system_instruction + user parts
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [["parts": [["text": userContent]]]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTPStatus(response, data: data, provider: "Gemini")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw LLMError.parseError("Gemini: unexpected response format")
        }
        return text
    }
}

// MARK: - Ollama (Local)

class OllamaProvider: LLMProvider {
    let displayName = "Ollama"
    private let baseURL: String
    private let model: String

    init(baseURL: String = "http://localhost:11434", model: String = "llama3.2") {
        self.baseURL = baseURL
        self.model = model
    }

    func complete(systemPrompt: String, userContent: String) async throws -> String {
        let url = URL(string: "\(baseURL)/api/chat")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTPStatus(response, data: data, provider: "Ollama")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.parseError("Ollama: unexpected response format")
        }
        return text
    }
}

// MARK: - KIMI (Moonshot AI)

class KIMIProvider: LLMProvider {
    let displayName = "KIMI"
    private let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    func complete(systemPrompt: String, userContent: String) async throws -> String {
        let url = URL(string: "https://api.moonshot.cn/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")

        let body: [String: Any] = [
            "model": "moonshot-v1-8k",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": 2048
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTPStatus(response, data: data, provider: "KIMI")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.parseError("KIMI: unexpected response format")
        }
        return text
    }
}

// MARK: - Provider Factory

struct LLMProviderFactory {
    static func make(type: LLMProviderType, settings: LLMSettings) -> LLMProvider {
        switch type {
        case .anthropic:
            return AnthropicProvider(apiKey: settings.apiKey(for: .anthropic))
        case .openAI:
            return OpenAIProvider(apiKey: settings.apiKey(for: .openAI))
        case .gemini:
            return GeminiProvider(apiKey: settings.apiKey(for: .gemini))
        case .ollama:
            return OllamaProvider(baseURL: settings.ollamaURL, model: settings.ollamaModel)
        case .kimi:
            return KIMIProvider(apiKey: settings.apiKey(for: .kimi))
        }
    }
}

// MARK: - Error Types

enum LLMError: LocalizedError {
    case httpError(Int, String)
    case parseError(String)
    case noAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .parseError(let msg):           return "Parse error: \(msg)"
        case .noAPIKey(let provider):        return "No API key set for \(provider)"
        }
    }
}

// MARK: - Shared HTTP helper

private func checkHTTPStatus(_ response: URLResponse, data: Data, provider: String) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
        throw LLMError.httpError(http.statusCode, "\(provider): \(body)")
    }
}
