import Foundation
import Security
import Combine

// MARK: - Keychain Helper

struct KeychainStore {
    private static let service = "soloai.MeetingAgent.LLMKeys"

    static func set(_ value: String, forKey account: String) {
        let data = Data(value.utf8)
        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func get(forKey account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str.isEmpty ? nil : str
    }

    static func delete(forKey account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - LLM Settings

class LLMSettings: ObservableObject {

    static let shared = LLMSettings()

    // Per-feature provider selection (stored in UserDefaults)
    @Published var summaryProvider: LLMProviderType {
        didSet { UserDefaults.standard.set(summaryProvider.rawValue, forKey: "llm_summary_provider") }
    }
    @Published var formattingProvider: LLMProviderType {
        didSet { UserDefaults.standard.set(formattingProvider.rawValue, forKey: "llm_formatting_provider") }
    }

    // Ollama config (stored in UserDefaults — not sensitive)
    @Published var ollamaURL: String {
        didSet { UserDefaults.standard.set(ollamaURL, forKey: "llm_ollama_url") }
    }
    @Published var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "llm_ollama_model") }
    }

    init() {
        let storedSummary = UserDefaults.standard.string(forKey: "llm_summary_provider") ?? ""
        summaryProvider = LLMProviderType(rawValue: storedSummary) ?? .anthropic

        let storedFormatting = UserDefaults.standard.string(forKey: "llm_formatting_provider") ?? ""
        formattingProvider = LLMProviderType(rawValue: storedFormatting) ?? .ollama

        ollamaURL   = UserDefaults.standard.string(forKey: "llm_ollama_url")   ?? "http://localhost:11434"
        ollamaModel = UserDefaults.standard.string(forKey: "llm_ollama_model") ?? "llama3.2"
    }

    // MARK: - Keychain access

    func apiKey(for provider: LLMProviderType) -> String {
        KeychainStore.get(forKey: provider.rawValue) ?? ""
    }

    func setAPIKey(_ key: String, for provider: LLMProviderType) {
        if key.isEmpty {
            KeychainStore.delete(forKey: provider.rawValue)
        } else {
            KeychainStore.set(key, forKey: provider.rawValue)
        }
    }

    // MARK: - Provider factory shortcuts

    func summaryLLM() throws -> LLMProvider {
        try validated(provider: summaryProvider)
    }

    func formattingLLM() throws -> LLMProvider {
        try validated(provider: formattingProvider)
    }

    private func validated(provider: LLMProviderType) throws -> LLMProvider {
        if provider.requiresAPIKey {
            let key = apiKey(for: provider)
            guard !key.isEmpty else {
                throw LLMError.noAPIKey(provider.rawValue)
            }
        }
        return LLMProviderFactory.make(type: provider, settings: self)
    }
}
