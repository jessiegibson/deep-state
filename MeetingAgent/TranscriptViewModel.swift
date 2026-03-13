import Foundation
import Combine

// MARK: - TranscriptSheetViewModel
// Shared between macOS and iOS targets.
// macOS passes savedFolderURL for security-scoped bookmark access.
// iOS passes nil (iCloud/Documents URLs are directly accessible).

@MainActor
class TranscriptSheetViewModel: ObservableObject {
    @Published var selectedTemplate: SummaryTemplate = .general
    @Published var isSummarizing = false
    @Published var summaryResult: String? = nil
    @Published var error: String? = nil

    func summarize(transcript: String, folderURL: URL, savedFolderURL: URL? = nil) async {
        isSummarizing = true
        summaryResult = nil
        error = nil

        do {
            let provider = try LLMSettings.shared.summaryLLM()
            let result = try await provider.complete(
                systemPrompt: selectedTemplate.systemPrompt,
                userContent: transcript
            )
            summaryResult = result
            saveSummaryToFile(summary: result, template: selectedTemplate,
                              folderURL: folderURL, savedFolderURL: savedFolderURL)
        } catch {
            self.error = error.localizedDescription
        }
        isSummarizing = false
    }

    private func saveSummaryToFile(summary: String, template: SummaryTemplate,
                                   folderURL: URL, savedFolderURL: URL?) {
        #if os(macOS)
        let accessGranted = savedFolderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if accessGranted { savedFolderURL?.stopAccessingSecurityScopedResource() } }
        #endif

        let transcriptURL = folderURL.appendingPathComponent("transcript.md")
        let summarySection = "## Summary (\(template.rawValue))\n\n\(summary)"

        guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            try? summarySection.write(to: transcriptURL, atomically: true, encoding: .utf8)
            return
        }

        if let range = content.range(of: "\n\n---\n\n## Summary") {
            content = String(content[content.startIndex..<range.lowerBound])
        }

        content += "\n\n---\n\n\(summarySection)"
        try? content.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }
}
