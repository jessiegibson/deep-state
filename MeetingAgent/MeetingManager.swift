#if os(macOS)
import SwiftUI
import ScreenCaptureKit
import WhisperKit
import Combine
import AVFoundation
import Speech
import UniformTypeIdentifiers
import EventKit


enum RecordingMode: String, CaseIterable {
    case screenAndAudio = "Screen + Audio"
    case audioOnly = "Audio Only"
}

enum PermissionStatus {
    case granted, denied, notDetermined
}

@MainActor
class MeetingManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var statusMessage = "Ready"
    @Published var liveTranscript = ""
    @Published var recordingMode: RecordingMode = .audioOnly

    let storage = StorageManager.shared
    /// Convenience accessor — views that read savedFolderURL continue to work.
    var savedFolderURL: URL? { storage.rootURL }

    // Preferences
    @Published var shouldRecordCamera: Bool = UserDefaults.standard.bool(forKey: "pref_record_camera") {
        didSet { UserDefaults.standard.set(shouldRecordCamera, forKey: "pref_record_camera") }
    }
    @Published var shouldRecordSystemAudio: Bool = UserDefaults.standard.bool(forKey: "pref_record_audio") {
        didSet { UserDefaults.standard.set(shouldRecordSystemAudio, forKey: "pref_record_audio") }
    }

    // LLM settings accessor (passed to LLMSettingsView). Summarization itself lives
    // in TranscriptViewModel — MeetingManager only exposes the shared settings object.
    let llmSettings = LLMSettings.shared

    // Calendar integration
    @Published var calendarAttendees: [String] = []

    // Import & retranscribe
    @Published var isImporting = false
    @Published var importProgress = ""
    @Published var isRetranscribing = false
    @Published var retranscribeProgress = ""

    private let screenRecorder = ScreenRecorder()
    private var lastRecordingURL: URL?
    private let whisperTranscriber = WhisperTranscriber()

    // Live transcription
    private var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    // Accumulator for finalized recognition chunks. SFSpeechRecognizer emits multiple
    // `isFinal` results per session (and on-device tasks cap around ~1 min), so we must
    // append finalized text here and display `finalizedTranscript + currentPartial` —
    // otherwise each new chunk's `formattedString` overwrites prior speech.
    // FUTURE: consider WhisperKit streaming (option B) for higher live accuracy —
    // would run WhisperKit on rolling audio windows in parallel with SFSpeech (kept for
    // SFVoiceAnalytics-based speaker diarization). Gated on thermal state + hardware.
    private var finalizedTranscript = ""
    private var collectAnalyticsInLiveTask = false

    // Audio-only recording
    private var audioFile: AVAudioFile?
    private var audioOnlyEngine: AVAudioEngine?
    private var audioOnlyURL: URL?

    // Voice Visualizer Properties
    @Published var amplitudes: [CGFloat] = Array(repeating: 0.1, count: 5)
    private let ambientMonitor = AmbientLevelMonitor()
    @Published var isPaused = false
    @Published var isNotesSheetOpen = false
    @Published var meetingNotes = ""
    @Published var meetingTitle = ""
    @Published var meetingLibrary: [MeetingRecord] = []
    private var recordingSegments: [URL] = []
    private var segmentCounter = 0

    // Speaker diarization
    private let analyticsCollector = VoiceAnalyticsCollector()
    private var rawTranscriptionSegments: [SFTranscriptionSegment] = []
    @Published var speakerSegments: [SpeakerSegment] = []
    @Published var isSpeakerLabelingOpen = false

    func checkPermissions() {
        if let message = PermissionsService.requestStartupPermissions() {
            statusMessage = message
        }
    }

    override init() {
        super.init()

        print("MeetingManager init started")

        // Idle visualizer levels flow back into our published amplitudes.
        ambientMonitor.onAmplitudes = { [weak self] bars in
            withAnimation(.linear(duration: 0.05)) {
                self?.amplitudes = bars
            }
        }

        // Transcription progress messages surface in the status line.
        whisperTranscriber.onStatus = { [weak self] message in
            self?.statusMessage = message
        }

        // Screen-capture stream/recorder failures stop recording and report status.
        screenRecorder.onStreamStopped = { [weak self] error in
            self?.statusMessage = "Stream stopped: \(error.localizedDescription)"
            self?.isRecording = false
        }
        screenRecorder.onRecorderError = { [weak self] error in
            self?.statusMessage = "Recorder Error: \(error.localizedDescription)"
            self?.isRecording = false
        }

        // StorageManager.shared handles folder resolution (iCloud or local bookmark)
        print("Folder loaded")
        
        // 1. Check permissions immediately on startup
        checkPermissions()
        print("Permissions check completed")
        
        // 2. Start loading the AI model in the background
        Task { await setupEngine() }
        print("WhisperKit setup started")
        
        print("MeetingManager init completed")
    }
    
    
    // MARK: - Setup
    private func setupEngine() async {
        statusMessage = "Loading AI Model..."
        if let error = await whisperTranscriber.load() {
            statusMessage = "AI Load Failed: \(error)"
        } else {
            statusMessage = "Ready"
        }
    }
    
    // MARK: - Recording Logic
    func start() async {
        // Pre-fill title and attendees from the selected calendar event (if any).
        // Only overwrite the title if the user hasn't typed a custom one.
        let cal = CalendarManager.shared
        if let event = cal.selectedEvent {
            if meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                meetingTitle = event.title ?? ""
            }
            calendarAttendees = cal.attendeeNames(for: event)
        } else {
            calendarAttendees = []
        }

        if recordingMode == .audioOnly {
            await startAudioOnly()
            return
        }

        // Release any AVAudioRecorder before ScreenCaptureKit starts — competing HAL clients
        // cause HALC_ProxyIOContext _StartIO to fail with error 35 (resource busy)
        stopMonitoring()

        statusMessage = "Starting..."
        recordingSegments = []
        segmentCounter = 0
        isPaused = false

        meetingNotes = ""
        isNotesSheetOpen = true

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("temp_rec_0.mov")
        self.lastRecordingURL = url

        do {
            screenRecorder.captureSystemAudio = shouldRecordSystemAudio
            try await screenRecorder.startCapture(to: url)
            isRecording = true
            statusMessage = "Recording..."
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            print("❌ Start error: \(error)")
        }
    }
    
    func stopAndTranscribe() async {
        if recordingMode == .audioOnly {
            await stopAudioOnly()
            return
        }

        statusMessage = "Stopping..."
        isPaused = false

        do {
            // Finalize the current segment's MOV (removeRecordingOutput → await
            // didFinishRecordingTo:) and stop capture before reading the file.
            try await screenRecorder.finalizeAndStop()
            isRecording = false

            if let currentURL = lastRecordingURL {
                recordingSegments.append(currentURL)
            }

            guard !recordingSegments.isEmpty else {
                statusMessage = "No recording found"
                return
            }

            // Merge segments if the recording was paused and resumed
            let videoURL: URL
            if recordingSegments.count > 1 {
                statusMessage = "Merging recording segments..."
                videoURL = try await screenRecorder.mergeSegments(recordingSegments)
            } else {
                videoURL = recordingSegments[0]
            }

            statusMessage = "Extracting audio..."
            guard let audioURL = try await extractAudio(from: videoURL) else {
                statusMessage = "Failed to extract audio"
                return
            }

            statusMessage = "Transcribing with AI..."
            let transcriptText = await transcribeAudio(audioURL: audioURL)

            statusMessage = "Saving files..."
            saveTranscript(text: transcriptText, videoURL: videoURL, audioURL: audioURL)

            // Cleanup segment files and any merged temp file
            for url in recordingSegments { try? FileManager.default.removeItem(at: url) }
            if recordingSegments.count > 1 { try? FileManager.default.removeItem(at: videoURL) }
            try? FileManager.default.removeItem(at: audioURL)
            recordingSegments = []
            isNotesSheetOpen = false
            loadLibrary()

        } catch {
            statusMessage = "Processing failed: \(error.localizedDescription)"
            isRecording = false
            isNotesSheetOpen = false
        }
    }
    
    // MARK: - Pause / Resume
    func pauseRecording() async {
        guard isRecording, !isPaused else { return }

        if recordingMode == .audioOnly {
            audioOnlyEngine?.pause()
            amplitudes = Array(repeating: 0.1, count: 5)
            isPaused = true
            statusMessage = "Paused"
        } else {
            do {
                // Finalize the current segment file before pausing.
                try await screenRecorder.finalizeAndStop()
                if let url = lastRecordingURL {
                    recordingSegments.append(url)
                }
                isPaused = true
                statusMessage = "Paused"
            } catch {
                statusMessage = "Pause failed: \(error.localizedDescription)"
            }
        }
    }

    func resumeRecording() async {
        guard isRecording, isPaused else { return }

        if recordingMode == .audioOnly {
            do {
                try audioOnlyEngine?.start()
                isPaused = false
                // If the recognition task ended while paused (e.g., hit the ~1 min cap),
                // spin up a new one so live transcription resumes. The audio tap feeds
                // `self.recognitionRequest`, which the helper replaces.
                if recognitionTask == nil {
                    startRotatingRecognitionTask(collectAnalytics: true)
                }
                statusMessage = "Recording (Audio Only)..."
            } catch {
                statusMessage = "Resume failed: \(error.localizedDescription)"
            }
        } else {
            segmentCounter += 1
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("temp_rec_\(segmentCounter).mov")
            self.lastRecordingURL = url
            do {
                screenRecorder.captureSystemAudio = shouldRecordSystemAudio
                try await screenRecorder.startCapture(to: url)
                isPaused = false
                statusMessage = "Recording..."
            } catch {
                statusMessage = "Resume failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Transcription (delegates to WhisperTranscriber)
    private func transcribeAudio(audioURL: URL) async -> String {
        await whisperTranscriber.transcribe(audioURL: audioURL)
    }

    // MARK: - Audio Extraction
    private func extractAudio(from videoURL: URL) async throws -> URL? {
        let asset = AVURLAsset(url: videoURL)
        
        // Check if the asset has audio tracks
        guard try await asset.load(.tracks).contains(where: { $0.mediaType == .audio }) else {
            statusMessage = "No audio track found in recording"
            return nil
        }
        
        // Create output URL for the extracted audio
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("extracted_audio.m4a")
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        // Create export session using modern API
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "MeetingManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        
        // Export the audio using the modern async API
        try await exportSession.export(to: outputURL, as: .m4a)
        
        return outputURL
    }

    // MARK: - Library
    func loadLibrary() {
        let result = storage.withScopedAccess {
            self.storage.loadMeetingLibrary()
        }
        meetingLibrary = result ?? []
    }

    func openInFinder(_ url: URL) {
        _ = storage.withScopedAccess {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Import External Files

    func importFiles() async {
        guard savedFolderURL != nil else {
            statusMessage = "Select a save folder first"
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "Select audio or video files to import and transcribe"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        isImporting = true
        importProgress = ""

        for (index, url) in urls.enumerated() {
            await importSingleFile(fileURL: url, index: index, total: urls.count)
        }

        isImporting = false
        importProgress = ""
        loadLibrary()
        statusMessage = "Imported \(urls.count) file\(urls.count == 1 ? "" : "s")"
    }

    private func importSingleFile(fileURL: URL, index: Int, total: Int) async {
        let filename = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        importProgress = "Processing \(filename) (\(index + 1)/\(total))..."

        _ = fileURL.startAccessingSecurityScopedResource()
        defer { fileURL.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory

        do {
            // Copy to temp to avoid sandbox issues
            let tempCopy = tempDir.appendingPathComponent("import_\(UUID().uuidString).\(ext)")
            try? fm.removeItem(at: tempCopy)
            try fm.copyItem(at: fileURL, to: tempCopy)
            defer { try? fm.removeItem(at: tempCopy) }

            let videoExtensions = ["mov", "mp4", "m4v"]
            let isVideo = videoExtensions.contains(ext)

            var audioURL: URL
            var videoURL: URL? = nil

            if isVideo {
                importProgress = "Extracting audio from \(filename) (\(index + 1)/\(total))..."
                guard let extracted = try await extractAudio(from: tempCopy) else {
                    print("❌ Failed to extract audio from \(filename)")
                    return
                }
                audioURL = extracted
                videoURL = tempCopy
            } else if ext == "m4a" {
                audioURL = tempCopy
            } else {
                importProgress = "Converting \(filename) (\(index + 1)/\(total))..."
                audioURL = try await convertToM4A(from: tempCopy)
            }
            defer {
                if audioURL != tempCopy { try? fm.removeItem(at: audioURL) }
            }

            importProgress = "Transcribing \(filename) (\(index + 1)/\(total))..."
            let transcript = await transcribeAudio(audioURL: audioURL)

            // Get file creation date for the folder timestamp
            let resourceValues = try? fileURL.resourceValues(forKeys: [.creationDateKey])
            let fileDate = resourceValues?.creationDate ?? Date()

            importProgress = "Saving \(filename) (\(index + 1)/\(total))..."
            saveImportedFile(transcript: transcript, title: filename, audioURL: audioURL, videoURL: videoURL, date: fileDate)

        } catch {
            print("❌ Import error for \(filename): \(error.localizedDescription)")
        }
    }

    private func saveImportedFile(transcript: String, title: String, audioURL: URL, videoURL: URL? = nil, date: Date) {
        _ = try? storage.withScopedAccess {
            try self.storage.saveMeeting(
                transcript: transcript,
                title: title,
                notes: "",
                audioURL: audioURL,
                videoURL: videoURL
            )
        }
    }

    // MARK: - Retranscribe Existing Recordings

    func retranscribe(record: MeetingRecord) async {
        guard record.hasAudio else {
            statusMessage = "No audio file to retranscribe"
            return
        }

        isRetranscribing = true
        retranscribeProgress = "Retranscribing \(record.displayTitle)..."

        guard savedFolderURL != nil else {
            isRetranscribing = false
            return
        }

        let audioURL = record.folderURL.appendingPathComponent("audio.m4a")

        let exists = storage.withScopedAccess {
            FileManager.default.fileExists(atPath: audioURL.path)
        }
        guard exists == true else {
            statusMessage = "Audio file not found"
            isRetranscribing = false
            return
        }

        let newTranscript = await transcribeAudio(audioURL: audioURL)

        // Update transcript.md preserving title and notes
        _ = storage.withScopedAccess {
            let transcriptURL = record.folderURL.appendingPathComponent("transcript.md")
            if let existingContent = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                let updated = self.replaceTranscriptSection(in: existingContent, with: newTranscript)
                try? updated.write(to: transcriptURL, atomically: true, encoding: .utf8)
            } else {
                try? ("## Transcript\n\n\(newTranscript)").write(to: transcriptURL, atomically: true, encoding: .utf8)
            }
        }

        isRetranscribing = false
        retranscribeProgress = ""
        loadLibrary()
        statusMessage = "Retranscription complete"
    }

    func retranscribeBatch(records: [MeetingRecord]) async {
        isRetranscribing = true
        for (i, record) in records.enumerated() {
            retranscribeProgress = "Retranscribing \(i + 1) of \(records.count): \(record.displayTitle)..."
            await retranscribe(record: record)
        }
        isRetranscribing = false
        retranscribeProgress = ""
        statusMessage = "Batch retranscription complete (\(records.count) files)"
    }

    private func replaceTranscriptSection(in existingContent: String, with newTranscript: String) -> String {
        let separator = "\n\n---\n\n"
        let sections = existingContent.components(separatedBy: separator)

        // Find the section that starts with "## Transcript"
        var headerSections: [String] = []
        for section in sections {
            if section.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## Transcript") {
                break
            }
            headerSections.append(section)
        }

        if headerSections.isEmpty {
            return "## Transcript\n\n\(newTranscript)"
        }

        return headerSections.joined(separator: separator) + separator + "## Transcript\n\n\(newTranscript)"
    }

    // MARK: - Folder Selection (delegates to StorageManager)

    func selectFolder() {
        storage.selectLocalFolder()
    }


    // MARK: - Save Logic
    func saveTranscript(text: String, videoURL: URL? = nil, audioURL: URL? = nil) {
        let result = try? storage.withScopedAccess {
            try self.storage.saveMeeting(
                transcript: text,
                title: self.meetingTitle,
                notes: self.meetingNotes,
                audioURL: audioURL,
                videoURL: videoURL
            )
        }

        if let folder = result {
            statusMessage = "Saved to \(folder.lastPathComponent)"
            // Reset calendar-driven state so the next recording starts clean.
            meetingTitle = ""
            calendarAttendees = []
            CalendarManager.shared.selectedEvent = nil
        } else if storage.rootURL == nil {
            statusMessage = "No save location selected"
        } else {
            statusMessage = "Permission denied to access folder."
        }
    }
    
    // MARK: - Live Speech-to-Text

    /// Creates a fresh SFSpeechAudioBufferRecognitionRequest + task and wires the callback.
    /// Accumulates finalized chunks into `finalizedTranscript` and rotates the task when
    /// a result becomes final or the task ends — this is required because on-device tasks
    /// cap around ~1 minute and each `isFinal` result resets `formattedString` on the
    /// next partial. The audio tap feeds `self.recognitionRequest`, which this method
    /// updates, so rotation is transparent to the tap.
    private func startRotatingRecognitionTask(collectAnalytics: Bool) {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("❌ Speech recognizer not available for rotation")
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
                        self.liveTranscript = self.finalizedTranscript
                    } else {
                        self.liveTranscript = self.finalizedTranscript + joiner + current
                    }
                }
            }

            if let error = error {
                let nsError = error as NSError
                print("⚠️ Recognition error: \(error.localizedDescription) code=\(nsError.code)")
            }

            // Rotate: if the task ended (final or error), spin up a new one so we keep
            // transcribing beyond the per-task time cap. Only rotate if we're still
            // recording — otherwise stop cleanly.
            let ended = (result?.isFinal ?? false) || error != nil
            if ended {
                Task { @MainActor in
                    guard self.isRecording, !self.isPaused else { return }
                    // Avoid rotating if a newer request has already replaced this one.
                    guard self.recognitionRequest === request else { return }
                    self.startRotatingRecognitionTask(collectAnalytics: self.collectAnalyticsInLiveTask)
                }
            }
        }
    }

    private func startLiveTranscription() throws {
        print("🎤 Starting live transcription...")
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("❌ Speech recognizer not available")
            throw NSError(domain: "MeetingManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available"])
        }
        
        print("✅ Speech recognizer is available")
        
        // Initialize audio engine if needed
        if audioEngine == nil {
            audioEngine = AVAudioEngine()
        }
        
        guard let audioEngine = audioEngine else {
            throw NSError(domain: "MeetingManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
        }
        
        // Cancel any previous task and reset the live accumulator for a fresh session.
        recognitionTask?.cancel()
        recognitionTask = nil
        finalizedTranscript = ""

        let inputNode = audioEngine.inputNode
        print("✅ Got input node: \(inputNode)")

        // Start (and auto-rotate) the recognition task.
        startRotatingRecognitionTask(collectAnalytics: false)
        print("✅ Recognition task started")

        // Configure the microphone input
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        print("✅ Recording format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount) channels")
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, _: AVAudioTime) in
            self?.recognitionRequest?.append(buffer)
        }
        
        print("✅ Audio tap installed")
        
        audioEngine.prepare()
        try audioEngine.start()
        
        print("✅ Audio engine started - Live transcription is NOW RUNNING")
    }
    
    private func stopLiveTranscription() {
        print("⏹️ Stopping live transcription")
        print("   Current transcript length: \(liveTranscript.count) characters")
        print("   Transcript preview: \(liveTranscript.prefix(100))")
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        
        print("✅ Live transcription stopped")
    }

    // MARK: - Audio-Only Recording
    private func startAudioOnly() async {
        statusMessage = "Starting audio recording..."

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            if micStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            statusMessage = "Microphone access required."
            return
        }

        do {
            let engine = AVAudioEngine()
            self.audioOnlyEngine = engine

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // Prepare WAV file for writing. AVAudioEngine input delivers 32-bit float
            // PCM in the device's native format, but AVAssetExportSession rejects float
            // PCM WAVs. Force standard 16-bit signed integer PCM so the M4A conversion
            // (and any downstream reader) accepts it.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("audio_only_recording.wav")
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }

            let writeSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: recordingFormat.sampleRate,
                AVNumberOfChannelsKey: recordingFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let file = try AVAudioFile(forWriting: tempURL, settings: writeSettings)
            self.audioFile = file
            self.audioOnlyURL = tempURL

            // Set up live transcription
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                statusMessage = "Speech recognizer not available"
                return
            }

            recognitionTask?.cancel()
            recognitionTask = nil
            finalizedTranscript = ""

            analyticsCollector.reset()
            rawTranscriptionSegments = []

            // Start (and auto-rotate) the recognition task with analytics collection
            // enabled for speaker diarization.
            startRotatingRecognitionTask(collectAnalytics: true)

            // Single tap: write to file + feed recognizer + compute amplitude
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self = self else { return }

                // Write to audio file
                try? self.audioFile?.write(from: buffer)

                // Feed to speech recognizer
                self.recognitionRequest?.append(buffer)

                // Compute amplitude for visualizer
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += abs(channelData[i])
                }
                let avg = sum / Float(frameLength)
                let normalizedPower = max(0.1, CGFloat(avg) * 5.0)

                Task { @MainActor in
                    withAnimation(.linear(duration: 0.05)) {
                        self.amplitudes = (0..<5).map { _ in
                            min(1.0, normalizedPower * CGFloat.random(in: 0.8...1.2))
                        }
                    }
                }
            }

            engine.prepare()
            try engine.start()

            isRecording = true
            liveTranscript = ""
            meetingNotes = ""
            isNotesSheetOpen = true
            statusMessage = "Recording (Audio Only)..."
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            print("Audio-only start error: \(error)")
        }
    }

    private func stopAudioOnly() async {
        statusMessage = "Stopping..."

        // Stop engine and audio tap
        audioOnlyEngine?.stop()
        audioOnlyEngine?.inputNode.removeTap(onBus: 0)
        audioFile = nil // Close the file handle

        // Signal end of audio and wait for the final recognition result.
        // The final result carries speechRecognitionMetadata.voiceAnalytics,
        // which is needed for speaker diarization. Cancelling immediately
        // would abort before that final callback fires.
        recognitionRequest?.endAudio()
        if let task = recognitionTask {
            statusMessage = "Finishing transcription..."
            // Wait up to 2 seconds for the recognizer to deliver the final result
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // If still running, force cancel
            if task.state == .running {
                task.cancel()
            }
        }
        recognitionRequest = nil
        recognitionTask = nil

        isRecording = false
        isPaused = false
        amplitudes = Array(repeating: 0.1, count: 5)

        guard let wavURL = audioOnlyURL else {
            statusMessage = "No recording found"
            return
        }

        // Convert WAV to M4A for smaller file size
        statusMessage = "Converting audio..."
        let m4aURL: URL
        do {
            m4aURL = try await convertToM4A(from: wavURL)
        } catch {
            // Conversion failed. Don't lose the recording. Save the WAV instead
            // and use whatever transcript exists (live transcript or empty).
            print("[MeetingManager] M4A conversion failed: \(error)")
            statusMessage = "Saving raw audio (M4A conversion failed)..."
            let fallbackText = liveTranscript.isEmpty
                ? "_Transcript unavailable. Audio saved as WAV._"
                : liveTranscript
            saveTranscript(text: fallbackText, videoURL: nil, audioURL: wavURL)
            try? FileManager.default.removeItem(at: wavURL)
            statusMessage = "Saved (WAV, no M4A)"
            return
        }

        // Use live transcript if available, otherwise transcribe with WhisperKit
        let transcriptText: String
        if !liveTranscript.isEmpty {
            // Format live transcript segments into paragraphs
            let formatted = rawTranscriptionSegments.isEmpty
                ? TranscriptFormatter.formatPlainText(liveTranscript)
                : TranscriptFormatter.format(sfSegments: rawTranscriptionSegments)
            transcriptText = formatted.isEmpty ? liveTranscript : formatted
        } else {
            statusMessage = "Transcribing with AI..."
            transcriptText = await transcribeAudio(audioURL: m4aURL)
        }

        // Run speaker diarization if we captured voice analytics
        let vectors = analyticsCollector.vectors
        print("🔊 Diarization check: \(vectors.count) voice vectors, \(rawTranscriptionSegments.count) transcription segments")
        if !vectors.isEmpty && !rawTranscriptionSegments.isEmpty {
            statusMessage = "Identifying speakers..."
            let segments = SpeakerSegmentBuilder.build(
                from: vectors,
                transcriptionSegments: rawTranscriptionSegments
            )
            // Pre-match against known voice prints
            speakerSegments = segments.map { seg in
                var s = seg
                if let match = VoicePrintStore.shared.match(seg.features) {
                    s.speakerName = match.name
                }
                return s
            }
            if speakerSegments.count > 1 {
                // Store audio URL for saving after labeling
                self.audioOnlyURL = m4aURL
                isSpeakerLabelingOpen = true
                // stopAudioOnly returns here; saving happens in finalizeWithSpeakerLabels()
                try? FileManager.default.removeItem(at: wavURL)
                return
            }
        }

        statusMessage = "Saving files..."
        saveTranscript(text: transcriptText, videoURL: nil, audioURL: m4aURL)

        // Cleanup temp files
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: m4aURL)

        isNotesSheetOpen = false
        loadLibrary()
        statusMessage = "Saved successfully"
    }

    private func convertToM4A(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_converted.m4a")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(domain: "MeetingManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        try await exportSession.export(to: outputURL, as: .m4a)
        return outputURL
    }

    // MARK: - Permission Status (for Onboarding)
    // Thin forwarders to PermissionsService so OnboardingView call sites are unchanged.
    func microphonePermissionStatus() -> PermissionStatus { PermissionsService.microphoneStatus() }

    func requestMicrophonePermission() async -> Bool { await PermissionsService.requestMicrophone() }

    func screenRecordingPermissionStatus() -> PermissionStatus { PermissionsService.screenRecordingStatus() }

    func requestScreenRecordingPermission() { PermissionsService.requestScreenRecording() }

    func speechRecognitionPermissionStatus() -> PermissionStatus { PermissionsService.speechRecognitionStatus() }

    func requestSpeechRecognitionPermission() async -> Bool { await PermissionsService.requestSpeechRecognition() }

    // MARK: - Speaker Diarization

    /// Called by SpeakerLabelingView when user finishes naming speakers
    func finalizeWithSpeakerLabels(_ labeledSegments: [SpeakerSegment]) {
        let transcriptText = buildDiarizedTranscript(from: labeledSegments)

        // Update voice prints for named speakers
        for segment in labeledSegments {
            guard let name = segment.speakerName else { continue }
            VoicePrintStore.shared.upsert(name: name, features: segment.features)
        }

        statusMessage = "Saving files..."
        saveTranscript(text: transcriptText, videoURL: nil, audioURL: audioOnlyURL)

        if let m4a = audioOnlyURL { try? FileManager.default.removeItem(at: m4a) }
        audioOnlyURL = nil
        speakerSegments = []
        isSpeakerLabelingOpen = false
        isNotesSheetOpen = false
        statusMessage = "Saved successfully"
    }

    func cancelSpeakerLabeling() {
        // Save without speaker labels using plain transcript
        saveTranscript(text: liveTranscript, videoURL: nil, audioURL: audioOnlyURL)
        if let m4a = audioOnlyURL { try? FileManager.default.removeItem(at: m4a) }
        audioOnlyURL = nil
        speakerSegments = []
        isSpeakerLabelingOpen = false
        isNotesSheetOpen = false
        statusMessage = "Saved successfully"
    }

    private func buildDiarizedTranscript(from segments: [SpeakerSegment]) -> String {
        guard !segments.isEmpty else { return liveTranscript }
        return segments.map { seg in
            "**\(seg.displayName):** \(seg.text)"
        }.joined(separator: "\n\n")
    }

}

extension MeetingManager {
    // Forwarders to AmbientLevelMonitor (idle voice visualizer). Called by ContentView.
    func startMonitoring() {
        ambientMonitor.start()
    }

    func stopMonitoring() {
        ambientMonitor.stop()
        amplitudes = Array(repeating: 0.1, count: 5)
    }
}

#Preview {
    @Previewable @State var manager = MeetingManager()

    Button("Stop & Transcribe") {
        Task {
            await manager.stopAndTranscribe()
        }
    }
    .padding()
}
#endif

