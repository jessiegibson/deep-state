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

    // Live transcription + audio-only capture (extracted helpers)
    private let liveTranscriber = LiveTranscriber()
    private let audioRecorder = AudioRecorder()

    // Audio file to save once recording stops (WAV, then reassigned to the M4A used
    // for the speaker-labeling handoff in finalizeWithSpeakerLabels).
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

    // Speaker diarization (voice analytics + raw segments live in LiveTranscriber)
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

        // Live transcript updates surface in the published transcript; rotation continues
        // only while actively recording.
        liveTranscriber.onTranscript = { [weak self] text in
            self?.liveTranscript = text
        }
        liveTranscriber.isActive = { [weak self] in
            guard let self = self else { return false }
            return self.isRecording && !self.isPaused
        }

        // Audio-only capture feeds the transcriber and drives the visualizer.
        audioRecorder.onBuffer = { [weak self] buffer in
            self?.liveTranscriber.append(buffer)
        }
        audioRecorder.onAmplitudes = { [weak self] bars in
            withAnimation(.linear(duration: 0.05)) {
                self?.amplitudes = bars
            }
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
            audioRecorder.pause()
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
                try audioRecorder.resume()
                isPaused = false
                // If the recognition task ended while paused (e.g., hit the ~1 min cap),
                // spin up a new one so live transcription resumes.
                liveTranscriber.resumeIfStopped(collectAnalytics: true)
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
                audioURL = try await audioRecorder.convertToM4A(from: tempCopy)
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

        guard liveTranscriber.isRecognizerAvailable else {
            statusMessage = "Speech recognizer not available"
            return
        }

        do {
            // Start a fresh recognition session (resets transcript + analytics) with
            // analytics collection enabled for speaker diarization, then begin capture.
            liveTranscriber.startFresh(collectAnalytics: true)
            let wavURL = try audioRecorder.start()
            self.audioOnlyURL = wavURL

            isRecording = true
            liveTranscript = ""
            meetingNotes = ""
            isNotesSheetOpen = true
            statusMessage = "Recording (Audio Only)..."
        } catch {
            liveTranscriber.cancel()
            statusMessage = "Error: \(error.localizedDescription)"
            print("Audio-only start error: \(error)")
        }
    }

    private func stopAudioOnly() async {
        statusMessage = "Stopping..."

        // Stop capture (closes the WAV file), then signal end of audio and wait for the
        // final recognition result — it carries the voice analytics needed for diarization.
        audioRecorder.stop()
        statusMessage = "Finishing transcription..."
        await liveTranscriber.endAndAwaitFinal()

        isRecording = false
        isPaused = false
        amplitudes = Array(repeating: 0.1, count: 5)

        guard let wavURL = audioRecorder.wavURL else {
            statusMessage = "No recording found"
            return
        }

        // Convert WAV to M4A for smaller file size
        statusMessage = "Converting audio..."
        let m4aURL: URL
        do {
            m4aURL = try await audioRecorder.convertToM4A(from: wavURL)
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
        let rawSegments = liveTranscriber.rawTranscriptionSegments
        let transcriptText: String
        if !liveTranscript.isEmpty {
            // Format live transcript segments into paragraphs
            let formatted = rawSegments.isEmpty
                ? TranscriptFormatter.formatPlainText(liveTranscript)
                : TranscriptFormatter.format(sfSegments: rawSegments)
            transcriptText = formatted.isEmpty ? liveTranscript : formatted
        } else {
            statusMessage = "Transcribing with AI..."
            transcriptText = await transcribeAudio(audioURL: m4aURL)
        }

        // Run speaker diarization if we captured voice analytics
        let vectors = liveTranscriber.voiceVectors
        print("🔊 Diarization check: \(vectors.count) voice vectors, \(rawSegments.count) transcription segments")
        if !vectors.isEmpty && !rawSegments.isEmpty {
            statusMessage = "Identifying speakers..."
            let segments = SpeakerSegmentBuilder.build(
                from: vectors,
                transcriptionSegments: rawSegments
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

