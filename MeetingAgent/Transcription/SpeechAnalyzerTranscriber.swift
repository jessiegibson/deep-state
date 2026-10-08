#if os(macOS)
import Foundation
import AVFoundation
import Speech

/// File-based transcription through the modern Speech stack — `SpeechAnalyzer` plus a
/// `SpeechTranscriber` module — introduced in macOS 26.
///
/// This is the replacement for `SFSpeechRecognizer`, which Apple now treats as legacy.
/// It runs fully on-device, has no 1-minute request ceiling, and takes an `AVAudioFile`
/// directly instead of streaming a URL request.
///
/// The app's deployment target is macOS 15.6, so this whole type is gated behind
/// `@available(macOS 26.0, *)` and `WhisperTranscriber` falls back to
/// `SFSpeechRecognizer` on anything older. Once the deployment target reaches 26 the
/// legacy path — and this availability dance — can be deleted outright.
@available(macOS 26.0, *)
enum SpeechAnalyzerTranscriber {

    /// Transcribes an audio file. Returns nil when the device or locale isn't
    /// supported, or when the audio genuinely contains no speech, so the caller can
    /// fall through to another engine rather than treating it as a hard failure.
    static func transcribe(audioURL: URL, locale: Locale = .current) async throws -> String? {
        guard SpeechTranscriber.isAvailable else {
            print("[SpeechAnalyzer] not available on this device")
            return nil
        }

        // The transcriber wants a locale it actually ships a model for, which is not
        // necessarily the exact one the user is running.
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            print("[SpeechAnalyzer] no supported locale equivalent to \(locale.identifier)")
            return nil
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)

        // Model assets are fetched on demand and cached by the system, once per
        // locale. A nil request means everything needed is already installed.
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("[SpeechAnalyzer] downloading assets for \(supportedLocale.identifier)…")
            try await installation.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)

        // Results must be drained concurrently with the analysis, not after it: the
        // analyzer applies backpressure and will stall if nothing is consuming the
        // module's output. Collecting in a child task is what keeps both moving.
        async let collected: String = collect(from: transcriber)

        let audioFile = try AVAudioFile(forReading: audioURL)
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            // No samples at all — an empty or unreadable file. Tear the session down
            // rather than leaving the analyzer waiting on input that never arrives.
            await analyzer.cancelAndFinishNow()
        }

        let text = try await collected
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // SpeechAnalyzer hands back an AttributedString with no segment timings unless
        // time-indexing attributes are requested, so there is nothing for the
        // segment-aware formatters to work with. Paragraph the plain text instead.
        let formatted = TranscriptFormatter.formatPlainText(trimmed)
        return formatted.isEmpty ? trimmed : formatted
    }

    /// Accumulates the finalized results. Volatile (in-progress) results are skipped —
    /// they are revised in place and would otherwise be counted twice.
    private static func collect(from transcriber: SpeechTranscriber) async throws -> String {
        var transcript = AttributedString()
        for try await result in transcriber.results where result.isFinal {
            transcript.append(result.text)
        }
        return String(transcript.characters)
    }
}
#endif
