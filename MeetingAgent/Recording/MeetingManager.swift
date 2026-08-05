#if os(macOS)
import SwiftUI
import ScreenCaptureKit
import WhisperKit
import Combine
import AVFoundation
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
    @Published var recordingMode: RecordingMode = .audioOnly

    // Screen picker (only relevant in .screenAndAudio mode with multiple displays)
    @Published var availableDisplays: [DisplayOption] = []
    @Published var selectedDisplayID: CGDirectDisplayID?

    let storage = StorageManager.shared
    /// Convenience accessor — views that read savedFolderURL continue to work.
    var savedFolderURL: URL? { storage.rootURL }

    // Preferences
    @Published var shouldRecordCamera: Bool = UserDefaults.standard.bool(forKey: "pref_record_camera") {
        didSet { UserDefaults.standard.set(shouldRecordCamera, forKey: "pref_record_camera") }
    }
    @Published var shouldRecordSystemAudio: Bool = true
    @Published var shouldRecordMicrophoneAudio: Bool = true

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

    // Audio-only capture + file import helpers
    private let audioRecorder = AudioRecorder()
    private let fileImportService = FileImportService()

    // Audio file to save once recording stops (WAV, then reassigned to the M4A).
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

        // Audio-only capture drives the visualizer.
        audioRecorder.onAmplitudes = { [weak self] bars in
            withAnimation(.linear(duration: 0.05)) {
                self?.amplitudes = bars
            }
        }

        // File import / retranscribe: inject audio transforms, surface progress.
        fileImportService.transcribe = { [weak self] url in
            await self?.whisperTranscriber.transcribe(audioURL: url) ?? ""
        }
        fileImportService.extractAudio = { [weak self] url in
            try await self?.extractAudio(from: url) ?? nil
        }
        fileImportService.convertToM4A = { [weak self] url in
            guard let self = self else { throw CancellationError() }
            return try await self.audioRecorder.convertToM4A(from: url)
        }
        fileImportService.onImportingChanged = { [weak self] v in self?.isImporting = v }
        fileImportService.onImportProgress = { [weak self] v in self?.importProgress = v }
        fileImportService.onRetranscribingChanged = { [weak self] v in self?.isRetranscribing = v }
        fileImportService.onRetranscribeProgress = { [weak self] v in self?.retranscribeProgress = v }
        fileImportService.onStatus = { [weak self] v in self?.statusMessage = v }
        fileImportService.onLibraryChanged = { [weak self] in self?.loadLibrary() }

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
    
    // MARK: - Screen Picker

    /// Refreshes the list of connected displays and, if the current selection is unset
    /// or no longer connected, defaults it to the display containing the app's window.
    func refreshAvailableDisplays() async {
        do {
            let displays = try await ScreenRecorder.availableDisplays()
            availableDisplays = displays
            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = ScreenRecorder.displayContainingKeyWindow(in: displays)
            }
        } catch {
            print("❌ Failed to list displays: \(error)")
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
            screenRecorder.captureMicrophone = shouldRecordMicrophoneAudio
            screenRecorder.selectedDisplayID = selectedDisplayID
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
            let audioURL = try await extractAudio(from: videoURL)

            let transcriptText: String
            if let audioURL {
                statusMessage = "Transcribing with AI..."
                transcriptText = await transcribeAudio(audioURL: audioURL)
            } else {
                // No audio track in the capture — keep the video instead of
                // discarding the whole recording.
                transcriptText = "_No audio was captured with this screen recording._"
            }

            statusMessage = "Saving files..."
            saveTranscript(text: transcriptText, videoURL: videoURL, audioURL: audioURL)

            // Cleanup segment files and any merged temp file
            for url in recordingSegments { try? FileManager.default.removeItem(at: url) }
            if recordingSegments.count > 1 { try? FileManager.default.removeItem(at: videoURL) }
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            recordingSegments = []
            isNotesSheetOpen = false
            loadLibrary()

        } catch {
            let ns = error as NSError
            statusMessage = "Processing failed: \(error.localizedDescription) [\(ns.domain) \(ns.code)]"
            print("[MeetingManager] stopAndTranscribe failed: \(ns.domain) \(ns.code) — \(ns)")
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
                screenRecorder.captureMicrophone = shouldRecordMicrophoneAudio
                screenRecorder.selectedDisplayID = selectedDisplayID
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
        
        // Export the audio using the modern async API. A failed export shouldn't
        // abort processing — the caller saves the video without audio instead.
        do {
            try await exportSession.export(to: outputURL, as: .m4a)
        } catch {
            let ns = error as NSError
            print("[MeetingManager] Audio extraction export failed: \(ns.domain) \(ns.code) — \(ns)")
            statusMessage = "Audio extraction failed — saving video only"
            return nil
        }

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

    // MARK: - Import & Retranscribe (delegates to FileImportService)

    func importFiles() async {
        await fileImportService.importFiles()
    }

    func retranscribe(record: MeetingRecord) async {
        await fileImportService.retranscribe(record: record)
    }

    func retranscribeBatch(records: [MeetingRecord]) async {
        await fileImportService.retranscribeBatch(records: records)
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

        do {
            let wavURL = try audioRecorder.start()
            self.audioOnlyURL = wavURL

            isRecording = true
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

        audioRecorder.stop()
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
            // Conversion failed. Don't lose the recording — save the WAV instead.
            print("[MeetingManager] M4A conversion failed: \(error)")
            statusMessage = "Saving raw audio (M4A conversion failed)..."
            saveTranscript(
                text: "_Transcript unavailable. Audio saved as WAV._",
                videoURL: nil,
                audioURL: wavURL
            )
            try? FileManager.default.removeItem(at: wavURL)
            statusMessage = "Saved (WAV, no M4A)"
            return
        }

        statusMessage = "Transcribing with AI..."
        let transcriptText = await transcribeAudio(audioURL: m4aURL)

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

