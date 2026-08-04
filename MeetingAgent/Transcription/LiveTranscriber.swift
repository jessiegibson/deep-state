#if os(macOS)
import Foundation
import Speech
import AVFoundation

/// Live on-device speech recognition with auto-rotating tasks, plus per-segment
/// voice-analytics collection for speaker diarization. Extracted from `MeetingManager`.
///
/// On-device `SFSpeechRecognizer` tasks cap around ~1 minute and each `isFinal` result
/// resets `formattedString` on the next partial, so we accumulate finalized chunks in
/// `finalizedTranscript` and rotate the task when one ends. The audio source feeds
/// buffers via `append(_:)`; rotation is transparent to the caller.
@MainActor
final class LiveTranscriber {
    private let speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finalizedTranscript = ""
    private var collectAnalyticsInLiveTask = false

    private let analyticsCollector = VoiceAnalyticsCollector()
    private(set) var rawTranscriptionSegments: [SFTranscriptionSegment] = []

    /// Emits the current live transcript (finalized + partial) on each update.
    var onTranscript: ((String) -> Void)?
    /// Returns whether recognition should keep rotating (i.e. still recording, not paused).
    var isActive: (() -> Bool)?

    var isRecognizerAvailable: Bool { speechRecognizer?.isAvailable ?? false }
    var hasActiveTask: Bool { recognitionTask != nil }
    var voiceVectors: [VoiceFeatureVector] { analyticsCollector.vectors }

    /// Resets accumulated state and starts a fresh rotating recognition session.
    func startFresh(collectAnalytics: Bool) {
        recognitionTask?.cancel()
        recognitionTask = nil
        finalizedTranscript = ""
        analyticsCollector.reset()
        rawTranscriptionSegments = []
        startRotatingTask(collectAnalytics: collectAnalytics)
    }

    /// Restarts the rotating task without clearing the accumulated transcript — used on
    /// resume when the previous task ended (e.g. hit the per-task time cap) while paused.
    func resumeIfStopped(collectAnalytics: Bool) {
        if recognitionTask == nil {
            startRotatingTask(collectAnalytics: collectAnalytics)
        }
    }

    /// Feeds a microphone buffer to the active recognition request.
    func append(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    /// Immediately tears down recognition without waiting (error/abort path).
    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    /// Signals end of audio and waits up to 2s for the final result (which carries the
    /// voice analytics needed for diarization) before tearing down.
    func endAndAwaitFinal() async {
        recognitionRequest?.endAudio()
        if let task = recognitionTask {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if task.state == .running {
                task.cancel()
            }
        }
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func startRotatingTask(collectAnalytics: Bool) {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("Speech recognizer not available for rotation")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request
        self.collectAnalyticsInLiveTask = collectAnalytics

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                if collectAnalytics {
                    self.analyticsCollector.ingest(result: result)
                }
                let current = result.bestTranscription.formattedString
                let segments = result.bestTranscription.segments
                let isFinal = result.isFinal
                Task { @MainActor in
                    if collectAnalytics {
                        self.rawTranscriptionSegments = segments
                    }
                    let joiner = self.finalizedTranscript.isEmpty ? "" : " "
                    if isFinal {
                        self.finalizedTranscript += joiner + current
                        self.onTranscript?(self.finalizedTranscript)
                    } else {
                        self.onTranscript?(self.finalizedTranscript + joiner + current)
                    }
                }
            }

            if let error = error {
                let nsError = error as NSError
                print("Recognition error: \(error.localizedDescription) code=\(nsError.code)")
            }

            // Rotate: if the task ended (final or error), spin up a new one so we keep
            // transcribing beyond the per-task time cap. Only rotate if still active.
            let ended = (result?.isFinal ?? false) || error != nil
            if ended {
                Task { @MainActor in
                    guard self.isActive?() ?? false else { return }
                    // Avoid rotating if a newer request has already replaced this one.
                    guard self.recognitionRequest === request else { return }
                    self.startRotatingTask(collectAnalytics: self.collectAnalyticsInLiveTask)
                }
            }
        }
    }
}
#endif
