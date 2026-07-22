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

                    // Onboarding reset
                    Rectangle()
                        .fill(NBDesign.border)
                        .frame(height: NBDesign.thinBorder)
                        .padding(.vertical, NBDesign.smallPadding)

                    VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                        Text("ONBOARDING")
                            .font(NBDesign.captionFont)
                        Text("Re-run the permission walkthrough on next launch. Useful after adding new permissions like calendar access.")
                            .font(NBDesign.captionFont)
                            .foregroundStyle(.secondary)
                        Button("RESET ONBOARDING") {
                            UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
                        }
                        .buttonStyle(NBButtonStyle(color: NBDesign.background, textColor: NBDesign.foreground))
                    }
                }
                .padding(NBDesign.padding)
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
        .background(NBDesign.background)
        .onAppear { loadDraftKeys() }
    }

    // MARK: - Subviews

    private func providerSection(label: String, binding: Binding<LLMProviderType>) -> some View {
        VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
            Text(label)
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 0) {
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

// MARK: - Flow Layout
// Wraps subviews onto multiple rows instead of overflowing the container's width.

private struct FlowLayout: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + size.width > maxWidth {
                totalHeight += rowHeight
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
