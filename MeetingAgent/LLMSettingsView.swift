import SwiftUI

// MARK: - LLM Settings View
// Displayed as a sheet from the gear icon in the main header.

struct LLMSettingsView: View {
    @ObservedObject var settings: LLMSettings
    @Environment(\.dismiss) private var dismiss

    // Local editable state for API keys (to avoid writing to Keychain on every keystroke)
    @State private var keyDraft: [LLMProviderType: String] = [:]
    @State private var savedFeedback: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("LLM SETTINGS")
                    .font(NBDesign.headlineFont)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .padding(8)
                .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
            }
            .padding(NBDesign.padding)
            .background(NBDesign.surface)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))

            ScrollView {
                VStack(alignment: .leading, spacing: NBDesign.padding) {

                    // Per-feature provider selection
                    providerSection(
                        label: "SUMMARY PROVIDER",
                        binding: $settings.summaryProvider
                    )
                    providerSection(
                        label: "FORMATTING PROVIDER",
                        binding: $settings.formattingProvider
                    )

                    // API keys for providers that need them
                    VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                        Text("API KEYS")
                            .font(NBDesign.captionFont)
                            .foregroundStyle(.secondary)

                        ForEach(LLMProviderType.allCases.filter { $0.requiresAPIKey }) { provider in
                            apiKeyRow(provider: provider)
                        }
                    }
                    .nbCard()

                    // Ollama config
                    VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                        Text("OLLAMA (LOCAL)")
                            .font(NBDesign.captionFont)
                            .foregroundStyle(.secondary)

                        configRow(label: "URL", binding: $settings.ollamaURL, placeholder: "http://localhost:11434")
                        configRow(label: "Model", binding: $settings.ollamaModel, placeholder: "llama3.2")
                    }
                    .nbCard()

                    // Save button + feedback
                    HStack {
                        Spacer()
                        if let feedback = savedFeedback {
                            Text(feedback)
                                .font(NBDesign.captionFont)
                                .foregroundStyle(.secondary)
                        }
                        Button("SAVE KEYS") {
                            saveAllKeys()
                        }
                        .buttonStyle(NBButtonStyle(color: NBDesign.foreground, textColor: NBDesign.background))
                        Spacer()
                    }
                }
                .padding(NBDesign.padding)
            }
        }
        .frame(width: 520, height: 580)
        .background(NBDesign.background)
        .onAppear { loadDraftKeys() }
    }

    // MARK: - Subviews

    private func providerSection(label: String, binding: Binding<LLMProviderType>) -> some View {
        VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
            Text(label)
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(LLMProviderType.allCases) { provider in
                    Button(provider.rawValue.uppercased()) {
                        binding.wrappedValue = provider
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundStyle(binding.wrappedValue == provider ? NBDesign.background : NBDesign.foreground)
                    .background(binding.wrappedValue == provider ? NBDesign.foreground : NBDesign.surface)
                    .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                }
            }
        }
        .nbCard()
    }

    private func apiKeyRow(provider: LLMProviderType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            SecureField(provider.keyPlaceholder, text: Binding(
                get: { keyDraft[provider] ?? "" },
                set: { keyDraft[provider] = $0 }
            ))
            .font(NBDesign.bodyFont)
            .textFieldStyle(.plain)
            .padding(.horizontal, NBDesign.smallPadding)
            .padding(.vertical, 6)
            .background(NBDesign.surface)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
        }
    }

    private func configRow(label: String, binding: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            TextField(placeholder, text: binding)
                .font(NBDesign.bodyFont)
                .textFieldStyle(.plain)
                .padding(.horizontal, NBDesign.smallPadding)
                .padding(.vertical, 6)
                .background(NBDesign.surface)
                .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
        }
    }

    // MARK: - Key persistence

    private func loadDraftKeys() {
        for provider in LLMProviderType.allCases where provider.requiresAPIKey {
            keyDraft[provider] = settings.apiKey(for: provider)
        }
    }

    private func saveAllKeys() {
        for (provider, key) in keyDraft {
            settings.setAPIKey(key, for: provider)
        }
        savedFeedback = "Saved to Keychain"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            savedFeedback = nil
        }
    }
}
