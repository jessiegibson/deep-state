#if os(iOS)
// iOS Meeting Manager
// Audio-only recording + live transcription + WhisperKit offline transcription.
// Saves recordings to iCloud Drive for cross-device access.

import Foundation
import AVFoundation
import Speech
import WhisperKit

@MainActor
class IOSMeetingManager: ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var statusMessage = "Ready"
    @Published var liveTranscript = ""
    @Published var amplitudes: [CGFloat] = Array(repeating: 0.1, count: 5)
    @Published var meetingTitle = ""
    @Published var meetingNotes = ""
    @Published var meetingLibrary: [MeetingRecord] = []

    // MARK: - Private

    private var whisper: WhisperKit?
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioURL: URL?
    private var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var rawSegments: [SFTranscriptionSegment] = []

    // MARK: - Init

    init() {
        Task { await loadWhisper() }
        loadLibrary()
    }

    // MARK: - WhisperKit Setup

    private func loadWhisper() async {
        statusMessage = "Loading AI model..."
        do {
            whisper = try await WhisperKit()
            statusMessage = "Ready"
        } catch {
            statusMessage = "AI model failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Recording

    func startRecording() async {
        let micStatus = AVAudioApplication.shared.recordPermission
        guard micStatus == .granted else {
            if micStatus == .undetermined {
                _ = await AVAudioApplication.requestRecordPermission()
            }
            statusMessage = "Microphone permission required."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            audioEngine = engine
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios_audio_\(Date().timeIntervalSince1970).wav")
            let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            audioFile = file
            audioURL = tempURL

            // Set up speech recognition
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                statusMessage = "Speech recognizer not available"
                return
            }
            recognitionTask?.cancel()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            recognitionRequest = request
            rawSegments = []

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    Task { @MainActor in
                        self.liveTranscript = result.bestTranscription.formattedString
                        self.rawSegments = result.bestTranscription.segments
                    }
                }
            }

            // Audio tap: write + feed recognizer + visualizer
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                try? self.audioFile?.write(from: buffer)
                self.recognitionRequest?.append(buffer)

                guard let channelData = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<count { sum += abs(channelData[i]) }
                let avg = CGFloat(sum / Float(count))
                let power = max(0.1, avg * 5.0)
                Task { @MainActor in
                    withAnimation(.linear(duration: 0.05)) {
                        self.amplitudes = (0..<5).map { _ in min(1.0, power * CGFloat.random(in: 0.8...1.2)) }
                    }
                }
            }

            engine.prepare()
            try engine.start()

            isRecording = true
            isPaused = false
            liveTranscript = ""
            meetingTitle = ""
            meetingNotes = ""
            statusMessage = "Recording..."
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        audioEngine?.pause()
        isPaused = true
        statusMessage = "Paused"
        amplitudes = Array(repeating: 0.1, count: 5)
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        do {
            try audioEngine?.start()
            isPaused = false
            statusMessage = "Recording..."
        } catch {
            statusMessage = "Resume failed: \(error.localizedDescription)"
        }
    }

    func stopAndSave() async {
        statusMessage = "Stopping..."

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioFile = nil

        isRecording = false
        isPaused = false
        amplitudes = Array(repeating: 0.1, count: 5)

        guard let wavURL = audioURL else { statusMessage = "No recording found"; return }

        // Convert to M4A
        statusMessage = "Converting audio..."
        guard let m4aURL = try? await convertToM4A(from: wavURL) else {
            if !liveTranscript.isEmpty {
                saveRecording(transcript: liveTranscript, audioURL: wavURL)
            } else {
                statusMessage = "Conversion failed"
            }
            return
        }

        // Use live transcript or run WhisperKit
        let transcript: String
        if !liveTranscript.isEmpty {
            let formatted = rawSegments.isEmpty
                ? TranscriptFormatter.formatPlainText(liveTranscript)
                : TranscriptFormatter.format(sfSegments: rawSegments)
            transcript = formatted.isEmpty ? liveTranscript : formatted
        } else {
            statusMessage = "Transcribing..."
            transcript = await transcribeOffline(m4aURL)
        }

        saveRecording(transcript: transcript, audioURL: m4aURL)
        try? FileManager.default.removeItem(at: wavURL)
        if m4aURL != wavURL { try? FileManager.default.removeItem(at: m4aURL) }
        loadLibrary()
        statusMessage = "Saved"
    }

    // MARK: - Transcription

    private func transcribeOffline(_ audioURL: URL) async -> String {
        guard let whisper else { return "AI model not loaded" }
        do {
            let results = try await whisper.transcribe(audioPath: audioURL.path)
            if let first = results.first, !first.text.isEmpty {
                let formatted = TranscriptFormatter.format(segments: first.segments)
                return formatted.isEmpty ? first.text : formatted
            }
            return "No speech detected"
        } catch {
            return "Transcription failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Save to iCloud Drive

    private func saveRecording(transcript: String, audioURL: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let timestamp = formatter.string(from: Date())

        let saveURL = iCloudFolder()?.appendingPathComponent(timestamp)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent(timestamp)

        do {
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)

            let titleTrimmed = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let notesTrimmed = meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let displayDate = displayFormatter.string(from: Date())

            var sections: [String] = []
            sections.append(titleTrimmed.isEmpty ? displayDate : "# \(titleTrimmed)\n\(displayDate)")
            if !notesTrimmed.isEmpty { sections.append("## Meeting Notes\n\n\(notesTrimmed)") }
            let finalText = sections.joined(separator: "\n\n---\n\n") + "\n\n---\n\n## Transcript\n\n\(transcript)"

            try finalText.write(to: saveURL.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

            if FileManager.default.fileExists(atPath: audioURL.path) {
                try FileManager.default.copyItem(at: audioURL, to: saveURL.appendingPathComponent("audio.m4a"))
            }

            statusMessage = "Saved to \(timestamp)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func iCloudFolder() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents")
            .appendingPathComponent("MeetingAgent")
    }

    // MARK: - Library

    func loadLibrary() {
        let root = iCloudFolder()
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"

        meetingLibrary = contents
            .filter { url in
                var isDir = ObjCBool(false)
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue && dateFormatter.date(from: url.lastPathComponent) != nil
            }
            .compactMap { parseMeetingRecord(from: $0, dateFormatter: dateFormatter) }
            .sorted { $0.date > $1.date }
    }

    private func parseMeetingRecord(from url: URL, dateFormatter: DateFormatter) -> MeetingRecord? {
        guard let date = dateFormatter.date(from: url.lastPathComponent) else { return nil }
        let fm = FileManager.default
        let hasAudio = fm.fileExists(atPath: url.appendingPathComponent("audio.m4a").path)
        let transcriptURL = url.appendingPathComponent("transcript.md")
        var title: String? = nil
        var content: String? = nil
        if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            content = text
            if let first = text.components(separatedBy: "\n").first, first.hasPrefix("# ") {
                title = String(first.dropFirst(2))
            }
        }
        return MeetingRecord(
            folderURL: url, folderName: url.lastPathComponent, title: title,
            date: date, hasAudio: hasAudio, hasVideo: false, transcriptContent: content
        )
    }

    // MARK: - Audio Conversion

    private func convertToM4A(from source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios_converted.m4a")
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "IOSMeetingManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Export session failed"])
        }
        try await session.export(to: output, as: .m4a)
        return output
    }
}
#endif
