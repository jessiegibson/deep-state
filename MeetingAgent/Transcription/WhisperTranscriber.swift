#if os(macOS)
import Foundation
import WhisperKit
import Speech

/// Post-hoc, file-based transcription: WhisperKit first, Apple's on-device speech
/// stack as fallback. Extracted from `MeetingManager`. Holds the WhisperKit instance
/// alive so the model is loaded only once.
///
/// The fallback picks an engine by OS version: `SpeechAnalyzer`/`SpeechTranscriber`
/// on macOS 26+, `SFSpeechRecognizer` below it. The deployment target is 15.6, so
/// both have to exist; `SFSpeechRecognizer` goes away when the target reaches 26.
@MainActor
final class WhisperTranscriber {
    private var whisper: WhisperKit?
    private let speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer()

    /// Progress messages for the UI (e.g. "Transcribing with AI...").
    var onStatus: ((String) -> Void)?

    var isModelLoaded: Bool { whisper != nil }

    /// Loads the WhisperKit model once. Returns an error description on failure, nil on success.
    func load() async -> String? {
        do {
            // Load WhisperKit once at startup (this can take a few seconds).
            // The variant comes from WhisperModelPreference rather than being
            // hardcoded here, so the planned Settings picker has one place to write
            // to and low-RAM Macs are not stuck with whatever this line said.
            let modelName = WhisperModelPreference.selected.rawValue
            let candidatePath = Bundle.main.resourceURL?
                .appendingPathComponent(modelName)
                .path()
            // Only pass modelFolder if it actually exists on disk — WhisperKit uses
            // it as-is and skips downloading whenever it's non-nil, even if the path
            // is bogus, so a not-found bundled model must fall through as nil.
            let bundleModelFolder = candidatePath.flatMap {
                FileManager.default.fileExists(atPath: $0) ? $0 : nil
            }
            let config = WhisperKitConfig(
                model: modelName,
                modelFolder: bundleModelFolder,
                download: true   // fetches from Hugging Face and caches locally if not bundled
            )
            whisper = try await WhisperKit(config)

        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// Transcribes an audio file. Tries WhisperKit, then Apple Speech.
    func transcribe(audioURL: URL) async -> String {
        if let whisper = whisper {
            do {
                print("Transcribing audio file with WhisperKit...")
                onStatus?("Transcribing with AI...")
                let results = try await whisper.transcribe(audioPath: audioURL.path)

                if let first = results.first, !first.text.isEmpty {
                    // Never return `first.text` raw — it still carries the model's
                    // special tokens (<|startoftranscript|>, <|0.00|>, [BLANK_AUDIO], …).
                    let formatted = TranscriptFormatter.format(segments: first.segments)
                    let text = formatted.isEmpty
                        ? TranscriptFormatter.cleanSegmentText(first.text)
                        : formatted
                    if !text.isEmpty {
                        print("WhisperKit transcription successful: \(text.count) characters")
                        return text
                    }
                    print("WhisperKit: audio contained no speech, trying Apple Speech fallback...")
                } else {
                    print("WhisperKit: No speech detected, trying Apple Speech fallback...")
                }
            } catch {
                print("WhisperKit error: \(error.localizedDescription), trying Apple Speech fallback...")
            }
        } else {
            print("WhisperKit not loaded, using Apple Speech fallback...")
        }

        // Fallback: Apple's on-device speech stack.
        onStatus?("Transcribing with Apple Speech (fallback)...")
        if let appleSpeechResult = await transcribeWithAppleSpeech(audioURL: audioURL) {
            return appleSpeechResult
        }

        // Both engines ran and neither found speech. If WhisperKit was loaded and
        // returned cleanly, the audio really is silent — say so plainly rather than
        // claiming the transcriber is broken.
        if whisper != nil {
            return "_No speech was detected in this recording._"
        }
        return "Transcription failed - both WhisperKit and Apple Speech unavailable"
    }

    /// Apple's on-device fallback, newest available engine first.
    private func transcribeWithAppleSpeech(audioURL: URL) async -> String? {
        if #available(macOS 26.0, *) {
            do {
                if let text = try await SpeechAnalyzerTranscriber.transcribe(audioURL: audioURL) {
                    print("SpeechAnalyzer transcription successful: \(text.count) characters")
                    return text
                }
                // Nil here means "no speech" or "locale unsupported", not a fault.
                // SFSpeechRecognizer is still worth a try before giving up.
                print("SpeechAnalyzer returned no transcript, trying SFSpeechRecognizer...")
            } catch {
                print("SpeechAnalyzer error: \(error.localizedDescription), trying SFSpeechRecognizer...")
            }
        }

        return await transcribeWithSFSpeechRecognizer(audioURL: audioURL)
    }

    /// Legacy on-device transcription via `SFSpeechURLRecognitionRequest`. Used below
    /// macOS 26, and as a second chance when `SpeechAnalyzer` comes back empty.
    private func transcribeWithSFSpeechRecognizer(audioURL: URL) async -> String? {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("Apple Speech recognizer not available")
            return nil
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }

                if let error = error {
                    print("Apple Speech error: \(error.localizedDescription)")
                    hasResumed = true
                    continuation.resume(returning: nil)
                    return
                }

                guard let result = result else { return }

                if result.isFinal {
                    hasResumed = true
                    let segments = result.bestTranscription.segments
                    let formatted = TranscriptFormatter.format(sfSegments: segments)
                    let text = formatted.isEmpty ? result.bestTranscription.formattedString : formatted
                    print("Apple Speech transcription successful: \(text.count) characters")
                    continuation.resume(returning: text.isEmpty ? nil : text)
                }
            }
        }
    }
}
#endif
