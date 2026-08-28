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
    /// Structured status channel. Read `.message` for text, `.severity` for styling,
    /// and `.failure` to branch on a specific error category.
    @Published var status: AppStatus = .idle
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
    /// Whether to capture the mic alongside a screen recording. See
    /// `startMicrophoneAlongsideScreen()` — this is a separate `AVAudioEngine` tap,
    /// NOT `SCStreamConfiguration.captureMicrophone` (which is unusable here).
    @Published var shouldRecordMicrophone: Bool = true

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
    /// Guards against a second STOP while finalization is still in flight — two
    /// concurrent stops race on the same stream and corrupt the recording.
    @Published private(set) var isStopping = false
    private let whisperTranscriber = WhisperTranscriber()

    // Audio-only capture + file import helpers
    private let audioRecorder = AudioRecorder()
    private let fileImportService = FileImportService()

    // Audio file to save once recording stops (WAV, then reassigned to the M4A).
    private var audioOnlyURL: URL?

    /// Mic WAV recorded in parallel with a screen capture, or nil when the mic isn't
    /// being captured. Mixed with the MOV's system audio in `stopAndTranscribe()`.
    private var screenMicURL: URL?
    /// Why the mic isn't being captured, when it isn't. Surfaced in the status line so
    /// a silent recording is never a surprise discovered after the meeting.
    @Published private(set) var micStatusNote: String?

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
            self?.status = .progress(message)
        }

        // Screen-capture stream/recorder failures stop recording and report status.
        screenRecorder.onStreamStopped = { [weak self] error in
            self?.status = .failure(.streamStopped(error.localizedDescription))
            self?.isRecording = false
        }
        screenRecorder.onRecorderError = { [weak self] error in
            self?.status = .failure(.recorderError(error.localizedDescription))
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
        fileImportService.onStatus = { [weak self] v in self?.status = v }
        fileImportService.onLibraryChanged = { [weak self] in self?.loadLibrary() }

        // StorageManager.shared handles folder resolution (iCloud or local bookmark)
        print("Folder loaded")

        // No permission requests here. Mic and screen access are asked for at the
        // moment the feature is used (onboarding's GRANT buttons, or the start of a
        // recording), never at launch — a user who has not touched anything yet has
        // no idea what the prompt is for, and App Review reads a cold-start TCC
        // prompt as an unjustified request.

        // Start loading the AI model in the background.
        Task { await setupEngine() }
        print("WhisperKit setup started")
        
        print("MeetingManager init completed")
    }
    
    
    // MARK: - Setup
    private func setupEngine() async {
        status = .progress("Loading AI model…")
        if let error = await whisperTranscriber.load() {
            status = .failure(.modelLoadFailed(error))
        } else {
            status = .idle
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
            print("Failed to list displays: \(error)")
            // -3801 is TCC refusing screen capture. It's silent otherwise — the
            // picker just shows an empty list with no explanation.
            if (error as NSError).code == -3801 {
                availableDisplays = []
                PermissionsService.hasRequestedScreenRecording = true
                status = .failure(.screenRecordingDenied)
            }
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

        status = .progress("Starting…")
        recordingSegments = []
        segmentCounter = 0
        isPaused = false

        meetingNotes = ""
        isNotesSheetOpen = true

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("temp_rec_0.mov")
        self.lastRecordingURL = url

        // Ask for mic access before capture begins so the prompt isn't recorded.
        let micPermitted = await resolveMicrophonePermission()

        do {
            screenRecorder.captureSystemAudio = shouldRecordSystemAudio
            screenRecorder.selectedDisplayID = selectedDisplayID
            try await screenRecorder.startCapture(to: url)
            startMicrophoneAlongsideScreen(permitted: micPermitted)
            isRecording = true
            // Never let a missing mic pass unnoticed — it's the difference between
            // recording the meeting and recording silence.
            status = .recording(mode: recordingMode, micNote: micStatusNote)
        } catch {
            status = .failure(.captureStartFailed(error.localizedDescription))
            print("Start error: \(error)")
        }
    }

    /// Resolves microphone permission *before* screen capture starts, so the system
    /// prompt isn't captured into the recording. Returns whether the mic may be used.
    private func resolveMicrophonePermission() async -> Bool {
        guard shouldRecordMicrophone else { return false }
        return await PermissionsService.ensureMicrophoneAccess() == .granted
    }

    /// Starts a microphone capture that runs in parallel with the ScreenCaptureKit
    /// stream.
    ///
    /// `SCStream.capturesAudio` records **system audio only** — whatever is playing
    /// out of the speakers — and never the microphone. The one SCK setting that would
    /// include the mic (`SCStreamConfiguration.captureMicrophone`) is unusable here:
    /// it builds an aggregated HAL device that fails in a sandboxed app and drops every
    /// frame (REGRESSION_REGISTER.md L9). So the mic gets its own `AVAudioEngine` tap
    /// and the two sources are mixed back together at save time.
    ///
    /// Called *after* `startCapture` — starting an audio engine before ScreenCaptureKit
    /// makes the two compete as HAL clients (`_StartIO` error 35).
    ///
    /// Failure is non-fatal (a screen recording without mic audio is still worth
    /// keeping) but it is never silent: `micStatusNote` surfaces the reason in the UI.
    private func startMicrophoneAlongsideScreen(permitted: Bool) {
        screenMicURL = nil
        micStatusNote = nil

        guard shouldRecordMicrophone else { return }
        guard permitted else {
            micStatusNote = "microphone permission denied"
            print("[MeetingManager] mic not authorized — system audio only")
            return
        }

        do {
            screenMicURL = try audioRecorder.start()
            let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown input"
            print("[MeetingManager] mic capture started on '\(device)'")
        } catch {
            micStatusNote = error.localizedDescription
            print("[MeetingManager] mic capture unavailable: \(error.localizedDescription)")
            screenMicURL = nil
        }
    }
    
    func stopAndTranscribe() async {
        if recordingMode == .audioOnly {
            await stopAudioOnly()
            return
        }

        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        status = .progress("Stopping…")
        isPaused = false

        do {
            // Stop capture and wait for the recording output to finish writing the
            // MOV before reading it.
            try await screenRecorder.finalizeAndStop()
            // Stop the parallel mic tap in lockstep with the screen capture.
            var micURL: URL?
            if screenMicURL != nil {
                audioRecorder.stop()
                micURL = audioRecorder.wavURL
                screenMicURL = nil
                // A mic file that exists but holds no samples is the failure mode that
                // silently produced [BLANK_AUDIO] recordings — check, don't assume.
                if let url = micURL, !micFileHasAudio(url) {
                    print("[MeetingManager] mic WAV has no usable audio — discarding")
                    micStatusNote = "microphone recorded no audio"
                    micURL = nil
                }
            }
            isRecording = false

            if let currentURL = lastRecordingURL {
                recordingSegments.append(currentURL)
            }

            guard !recordingSegments.isEmpty else {
                status = .failure(.noRecordingFound)
                return
            }

            // A zero-byte or missing file means finalization didn't produce anything.
            // Report that plainly instead of letting AVFoundation surface it later as
            // a cryptic "Cannot Open / media may be damaged" error.
            recordingSegments = recordingSegments.filter { url in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                if size == 0 {
                    print("[MeetingManager] discarding empty segment \(url.lastPathComponent)")
                    return false
                }
                return true
            }

            guard !recordingSegments.isEmpty else {
                status = .failure(.recordingEmpty)
                return
            }

            // Merge segments if the recording was paused and resumed
            let videoURL: URL
            if recordingSegments.count > 1 {
                status = .progress("Merging recording segments…")
                videoURL = try await screenRecorder.mergeSegments(recordingSegments)
            } else {
                videoURL = recordingSegments[0]
            }

            status = .progress("Extracting audio…")
            let systemAudioURL = try await extractAudio(from: videoURL)

            // Two independent sources: system audio (inside the MOV) and the mic
            // (its own WAV). Mix whichever we actually got into one track.
            status = .progress("Mixing audio…")
            let audioURL = try await combineAudioSources(system: systemAudioURL, mic: micURL)

            let transcriptText: String
            if let audioURL {
                status = .progress("Transcribing with AI…")
                transcriptText = await transcribeAudio(audioURL: audioURL)
            } else {
                // No audio track in the capture — keep the video instead of
                // discarding the whole recording.
                transcriptText = "_No audio was captured with this screen recording._"
            }

            status = .progress("Saving files…")
            saveTranscript(text: transcriptText, videoURL: videoURL, audioURL: audioURL)

            // Cleanup segment files and any merged/intermediate temp files
            for url in recordingSegments { try? FileManager.default.removeItem(at: url) }
            if recordingSegments.count > 1 { try? FileManager.default.removeItem(at: videoURL) }
            for url in [audioURL, systemAudioURL, micURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
            recordingSegments = []
            isNotesSheetOpen = false
            loadLibrary()
            // saveTranscript() has just set the outcome; only annotate a success.
            if let note = micStatusNote, case .success(let saved) = status {
                status = .success("\(saved) — no mic audio (\(note))")
            }

        } catch {
            // The mic engine is stopped mid-`do`; if we threw before that, stop it here
            // so a failed save doesn't leave the microphone running.
            if screenMicURL != nil {
                audioRecorder.stop()
                screenMicURL = nil
            }
            let ns = error as NSError
            status = .failure(.processingFailed(
                description: error.localizedDescription,
                domain: ns.domain,
                code: ns.code
            ))
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
            status = .paused
        } else {
            do {
                // Finalize the current segment file before pausing.
                try await screenRecorder.finalizeAndStop()
                // Pause the mic too, so its WAV stays aligned with the video segments.
                if screenMicURL != nil { audioRecorder.pause() }
                if let url = lastRecordingURL {
                    recordingSegments.append(url)
                }
                isPaused = true
                status = .paused
            } catch {
                status = .failure(.pauseFailed(error.localizedDescription))
            }
        }
    }

    func resumeRecording() async {
        guard isRecording, isPaused else { return }

        if recordingMode == .audioOnly {
            do {
                try audioRecorder.resume()
                isPaused = false
                status = .recording(mode: recordingMode, micNote: nil)
            } catch {
                status = .failure(.resumeFailed(error.localizedDescription))
            }
        } else {
            segmentCounter += 1
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("temp_rec_\(segmentCounter).mov")
            self.lastRecordingURL = url
            do {
                screenRecorder.captureSystemAudio = shouldRecordSystemAudio
                screenRecorder.selectedDisplayID = selectedDisplayID
                try await screenRecorder.startCapture(to: url)
                if screenMicURL != nil { try audioRecorder.resume() }
                isPaused = false
                status = .recording(mode: recordingMode, micNote: micStatusNote)
            } catch {
                status = .failure(.resumeFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Transcription (delegates to WhisperTranscriber)
    private func transcribeAudio(audioURL: URL) async -> String {
        await whisperTranscriber.transcribe(audioURL: audioURL)
    }

    // MARK: - Audio Mixing

    /// Whether a recorded WAV holds any actual samples. Reports the peak level so a
    /// mic that ran but heard nothing (muted, wrong input device) is distinguishable
    /// in the log from a mic that never started.
    private func micFileHasAudio(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            print("[MeetingManager] mic WAV unreadable or empty")
            return false
        }
        // Sample the first few seconds — enough to tell signal from digital silence
        // without reading a long meeting into memory.
        let frames = AVAudioFrameCount(min(file.length, Int64(file.processingFormat.sampleRate * 5)))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData
        else { return true }  // can't measure — keep it rather than discard audio

        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
        }
        print(String(format: "[MeetingManager] mic peak level: %.4f over %.1fs",
                     peak, Double(file.length) / file.processingFormat.sampleRate))
        return peak > 0.0001
    }

    /// Combines the screen recording's system audio with the separately-captured mic
    /// into a single M4A. Returns whichever single source exists if only one does, or
    /// nil if neither did. Mixing failures fall back to the system audio rather than
    /// losing the recording.
    private func combineAudioSources(system: URL?, mic: URL?) async throws -> URL? {
        switch (system, mic) {
        case (nil, nil):
            return nil
        case (let system?, nil):
            return system
        case (nil, let mic?):
            // Mic only (e.g. the capture had no system audio) — still needs M4A.
            return try? await audioRecorder.convertToM4A(from: mic)
        case (let system?, let mic?):
            do {
                return try await mixAudioFiles([system, mic])
            } catch {
                print("[MeetingManager] audio mix failed, using system audio only: \(error)")
                return system
            }
        }
    }

    /// Mixes several audio files down to one M4A, all starting at t=0.
    private func mixAudioFiles(_ urls: [URL]) async throws -> URL {
        let composition = AVMutableComposition()
        var inputParameters: [AVMutableAudioMixInputParameters] = []

        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(
                      withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                  )
            else { continue }

            let duration = try await asset.load(.duration)
            guard duration.isValid, duration > .zero else { continue }
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero
            )

            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(1.0, at: .zero)
            inputParameters.append(params)
        }

        guard !composition.tracks(withMediaType: .audio).isEmpty else {
            throw NSError(domain: "MeetingManager", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No audio tracks to mix"])
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed_audio.m4a")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(domain: "MeetingManager", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create audio mix export session"])
        }
        exportSession.audioMix = audioMix
        try await exportSession.export(to: outputURL, as: .m4a)
        return outputURL
    }

    // MARK: - Audio Extraction
    private func extractAudio(from videoURL: URL) async throws -> URL? {
        let asset = AVURLAsset(url: videoURL)
        
        // Check if the asset has audio tracks
        guard try await asset.load(.tracks).contains(where: { $0.mediaType == .audio }) else {
            status = .failure(.noAudioTrack)
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
            status = .failure(.audioExtractionFailed)
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
        // `withScopedAccess` returns nil for exactly one reason — the security-scoped
        // bookmark refused to open — and rethrows anything `saveMeeting` throws. The
        // old code wrapped the whole thing in `try?`, which collapsed both into nil
        // and then *guessed* the cause from `rootURL`. A genuine write failure (disk
        // full, the folder deleted mid-save, a bad bookmark) was reported to the user
        // as "Permission denied to access folder", which sent them to fix the wrong
        // thing. Distinguish the two.
        do {
            let folder = try storage.withScopedAccess {
                try self.storage.saveMeeting(
                    transcript: text,
                    title: self.meetingTitle,
                    notes: self.meetingNotes,
                    audioURL: audioURL,
                    videoURL: videoURL
                )
            }

            guard let folder else {
                status = .failure(.saveLocationDenied)
                return
            }

            status = .success("Saved to \(folder.lastPathComponent)")
            // Reset calendar-driven state so the next recording starts clean.
            meetingTitle = ""
            calendarAttendees = []
            CalendarManager.shared.selectedEvent = nil
        } catch StorageManager.StorageError.noSaveLocation {
            status = .failure(.noSaveLocation)
        } catch StorageManager.StorageError.permissionDenied {
            status = .failure(.saveLocationDenied)
        } catch {
            print("[MeetingManager] saveMeeting failed: \(error)")
            status = .failure(.saveFailed(error.localizedDescription))
        }
    }
    
    // MARK: - Audio-Only Recording
    private func startAudioOnly() async {
        status = .progress("Starting audio recording…")

        // Ask for the mic here, at the point the user pressed RECORD, and wait for
        // the answer. The old code fired the request without awaiting it and then
        // read a status that was still .notDetermined, so granting access still
        // produced an error message and a recording that never started.
        guard await PermissionsService.ensureMicrophoneAccess() == .granted else {
            status = .failure(.microphoneDenied)
            return
        }

        do {
            let wavURL = try audioRecorder.start()
            self.audioOnlyURL = wavURL

            isRecording = true
            meetingNotes = ""
            isNotesSheetOpen = true
            status = .recording(mode: recordingMode, micNote: nil)
        } catch {
            status = .failure(.captureStartFailed(error.localizedDescription))
            print("Audio-only start error: \(error)")
        }
    }

    private func stopAudioOnly() async {
        status = .progress("Stopping…")

        audioRecorder.stop()
        isRecording = false
        isPaused = false
        amplitudes = Array(repeating: 0.1, count: 5)

        guard let wavURL = audioRecorder.wavURL else {
            status = .failure(.noRecordingFound)
            return
        }

        // Convert WAV to M4A for smaller file size
        status = .progress("Converting audio…")
        let m4aURL: URL
        do {
            m4aURL = try await audioRecorder.convertToM4A(from: wavURL)
        } catch {
            // Conversion failed. Don't lose the recording — save the WAV instead.
            print("[MeetingManager] M4A conversion failed: \(error)")
            status = .progress("Saving raw audio (M4A conversion failed)…")
            saveTranscript(
                text: "_Transcript unavailable. Audio saved as WAV._",
                videoURL: nil,
                audioURL: wavURL
            )
            try? FileManager.default.removeItem(at: wavURL)
            // saveTranscript() reported the real outcome. Only downgrade a success
            // to note the missing M4A — never paper over a save that actually failed.
            if case .success(let saved) = status {
                status = .success("\(saved) (WAV, no M4A)")
            }
            return
        }

        status = .progress("Transcribing with AI…")
        let transcriptText = await transcribeAudio(audioURL: m4aURL)

        status = .progress("Saving files…")
        saveTranscript(text: transcriptText, videoURL: nil, audioURL: m4aURL)

        // Cleanup temp files
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: m4aURL)

        isNotesSheetOpen = false
        loadLibrary()
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

