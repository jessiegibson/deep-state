
import SwiftUI
import ScreenCaptureKit
import WhisperKit
import Combine
import AVFoundation
import Speech

// MARK: - Meeting Record Model
struct MeetingRecord: Identifiable {
    let id = UUID()
    let folderURL: URL
    let folderName: String
    let title: String?
    let date: Date
    let hasAudio: Bool
    let hasVideo: Bool
    let transcriptContent: String?

    var displayTitle: String { title ?? folderName }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy  h:mm a"
        return formatter.string(from: date)
    }
}

enum RecordingMode: String, CaseIterable {
    case screenAndAudio = "Screen + Audio"
    case audioOnly = "Audio Only"
}

enum PermissionStatus {
    case granted, denied, notDetermined
}

@MainActor
class MeetingManager: NSObject, ObservableObject, SCRecordingOutputDelegate {
    @Published var isRecording = false
    @Published var statusMessage = "Ready"
    @Published var savedFolderURL: URL?
    @Published var liveTranscript = ""
    @Published var recordingMode: RecordingMode = .audioOnly

    // Preferences
    @Published var shouldRecordCamera: Bool = UserDefaults.standard.bool(forKey: "pref_record_camera") {
        didSet { UserDefaults.standard.set(shouldRecordCamera, forKey: "pref_record_camera") }
    }
    @Published var shouldRecordSystemAudio: Bool = UserDefaults.standard.bool(forKey: "pref_record_audio") {
        didSet { UserDefaults.standard.set(shouldRecordSystemAudio, forKey: "pref_record_audio") }
    }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var lastRecordingURL: URL?
    private var whisper: WhisperKit? // Keep instance alive to avoid reloading model

    // Live transcription
    private var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Audio-only recording
    private var audioFile: AVAudioFile?
    private var audioOnlyEngine: AVAudioEngine?
    private var audioOnlyURL: URL?

    // Voice Visualizer Properties
    @Published var amplitudes: [CGFloat] = Array(repeating: 0.1, count: 5)
    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
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
        // Microphone Check
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .denied, .restricted:
            Task { @MainActor in
                self.statusMessage = "Microphone access denied. Enable in Settings."
            }
        default:
            break
        }

        // Screen Recording Check (macOS 14+)
        if #available(macOS 14.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                // This opens the system dialog
                CGRequestScreenCaptureAccess()
            }
        }
    }

    override init() {
        super.init()
        
        print("MeetingManager init started")
        
        loadSavedFolder()
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
        do {
            // Load WhisperKit once at startup (this can take a few seconds)
            // Note: Ensure you are using the correct model variant for your Mac's RAM
            whisper = try await WhisperKit()
            statusMessage = "Ready"
        } catch {
            statusMessage = "AI Load Failed: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Recording Logic
    func start() async {
        if recordingMode == .audioOnly {
            await startAudioOnly()
            return
        }

        statusMessage = "Starting..."
        recordingSegments = []
        segmentCounter = 0
        isPaused = false

        meetingNotes = ""
        meetingTitle = ""
        isNotesSheetOpen = true

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("temp_rec_0.mov")
        self.lastRecordingURL = url

        do {
            try await startScreenRecording(to: url)
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
            try await stream?.stopCapture()
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
                videoURL = try await mergeVideoSegments(recordingSegments)
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
                try await stream?.stopCapture()
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
                try await startScreenRecording(to: url)
                isPaused = false
                statusMessage = "Recording..."
            } catch {
                statusMessage = "Resume failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Transcription
    private func transcribeAudio(audioURL: URL) async -> String {
        guard let whisper = whisper else {
            print("❌ WhisperKit model not loaded")
            return "Transcription unavailable - AI model not loaded"
        }
        
        do {
            print("🎤 Transcribing audio file...")
            let results = try await whisper.transcribe(audioPath: audioURL.path)
            
            if let text = results.first?.text, !text.isEmpty {
                print("✅ Transcription successful: \(text.count) characters")
                return text
            } else {
                print("⚠️ No speech detected in audio")
                return "No speech detected in recording"
            }
        } catch {
            print("❌ Transcription error: \(error.localizedDescription)")
            return "Transcription failed: \(error.localizedDescription)"
        }
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
        guard let folderURL = savedFolderURL else { meetingLibrary = []; return }
        guard folderURL.startAccessingSecurityScopedResource() else { return }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"

        meetingLibrary = contents
            .filter { url in
                var isDir = ObjCBool(false)
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue && dateFormatter.date(from: url.lastPathComponent) != nil
            }
            .compactMap { parseMeetingRecord(from: $0) }
            .sorted { $0.date > $1.date }
    }

    private func parseMeetingRecord(from folderURL: URL) -> MeetingRecord? {
        let folderName = folderURL.lastPathComponent
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        guard let date = dateFormatter.date(from: folderName) else { return nil }

        let fm = FileManager.default
        let hasAudio = fm.fileExists(atPath: folderURL.appendingPathComponent("audio.m4a").path)
        let hasVideo = fm.fileExists(atPath: folderURL.appendingPathComponent("video.mov").path)

        let transcriptURL = folderURL.appendingPathComponent("transcript.md")
        var title: String? = nil
        var transcriptContent: String? = nil

        if let content = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            transcriptContent = content
            if let firstLine = content.components(separatedBy: "\n").first,
               firstLine.hasPrefix("# ") {
                title = String(firstLine.dropFirst(2))
            }
        }

        return MeetingRecord(
            folderURL: folderURL,
            folderName: folderName,
            title: title,
            date: date,
            hasAudio: hasAudio,
            hasVideo: hasVideo,
            transcriptContent: transcriptContent
        )
    }

    func openInFinder(_ url: URL) {
        guard let folderURL = savedFolderURL else { return }
        guard folderURL.startAccessingSecurityScopedResource() else { return }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Screen Recording Helper
    private func startScreenRecording(to url: URL) async throws {
        if #available(macOS 14.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                throw NSError(domain: "MeetingManager", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission required. Check System Settings → Privacy & Security → Screen Recording"])
            }
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetingManager", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let excludedWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.capturesAudio = shouldRecordSystemAudio
        if #available(macOS 14.0, *) {
            config.captureMicrophone = true
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let recordConfig = SCRecordingOutputConfiguration()
        recordConfig.outputURL = url
        recordConfig.outputFileType = .mov
        recordConfig.videoCodecType = .h264

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        recordingOutput = SCRecordingOutput(configuration: recordConfig, delegate: self)

        guard let s = stream, let ro = recordingOutput else {
            throw NSError(domain: "MeetingManager", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create stream or recording output"])
        }

        try s.addRecordingOutput(ro)
        try await s.startCapture()
    }

    private func mergeVideoSegments(_ urls: [URL]) async throws -> URL {
        let composition = AVMutableComposition()
        var currentTime = CMTime.zero
        var compositionTracks: [Int: AVMutableCompositionTrack] = [:]

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)

            for (index, track) in tracks.enumerated() {
                let compositionTrack: AVMutableCompositionTrack
                if let existing = compositionTracks[index] {
                    compositionTrack = existing
                } else {
                    guard let newTrack = composition.addMutableTrack(
                        withMediaType: track.mediaType,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else { continue }
                    compositionTracks[index] = newTrack
                    compositionTrack = newTrack
                }
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: track,
                    at: currentTime
                )
            }
            currentTime = CMTimeAdd(currentTime, duration)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged_recording.mov")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(domain: "MeetingManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create export session for merge"])
        }

        try await exportSession.export(to: outputURL, as: .mov)
        return outputURL
    }

    // MARK: - Bookmark Logic
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            saveFolderBookmark(url: url)
        }
    }

    private func saveFolderBookmark(url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "folder_bookmark")
            self.savedFolderURL = url
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }

    private func loadSavedFolder() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "folder_bookmark") else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale { saveFolderBookmark(url: url) }
            self.savedFolderURL = url
        } catch {
            print("Failed to load bookmark: \(error)")
        }
    }


    // MARK: - Save Logic
    func saveTranscript(text: String, videoURL: URL? = nil, audioURL: URL? = nil) {
        guard let folderURL = savedFolderURL else {
            statusMessage = "No save location selected"
            return
        }
        
        // CRITICAL: Check the boolean return value
        guard folderURL.startAccessingSecurityScopedResource() else {
            statusMessage = "Permission denied to access folder."
            return
        }
        
        // Defer ensures we stop accessing even if we throw or return early
        defer {
            folderURL.stopAccessingSecurityScopedResource()
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        let meetingFolderName = timestamp
        
        // Create the meeting folder
        let meetingFolderURL = folderURL.appendingPathComponent(meetingFolderName)
        
        do {
            try FileManager.default.createDirectory(at: meetingFolderURL, withIntermediateDirectories: true)
            
            var savedFiles: [String] = []
            
            // Save the transcript, prepending any meeting notes
            let transcriptFilename = "transcript.md"
            let transcriptFileURL = meetingFolderURL.appendingPathComponent(transcriptFilename)
            let titleTrimmed = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNotes = meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayDateFormatter = DateFormatter()
            displayDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let displayTimestamp = displayDateFormatter.string(from: Date())
            var sections: [String] = []
            if !titleTrimmed.isEmpty {
                sections.append("# \(titleTrimmed)\n\(displayTimestamp)")
            } else {
                sections.append(displayTimestamp)
            }
            if !trimmedNotes.isEmpty { sections.append("## Meeting Notes\n\n\(trimmedNotes)") }
            let finalText = sections.joined(separator: "\n\n---\n\n") + "\n\n---\n\n## Transcript\n\n\(text)"
            try finalText.write(to: transcriptFileURL, atomically: true, encoding: .utf8)
            savedFiles.append(transcriptFilename)
            
            // Save the video file if provided
            if let videoURL = videoURL {
                // Verify the file exists before trying to copy
                guard FileManager.default.fileExists(atPath: videoURL.path) else {
                    throw NSError(domain: "MeetingManager", code: -1, 
                                  userInfo: [NSLocalizedDescriptionKey: "Video file not found at \(videoURL.path)"])
                }
                
                let videoFilename = "video.mov"
                let videoFileURL = meetingFolderURL.appendingPathComponent(videoFilename)
                try FileManager.default.copyItem(at: videoURL, to: videoFileURL)
                savedFiles.append(videoFilename)
            }
            
            // Save the audio file if provided
            if let audioURL = audioURL {
                // Verify the file exists before trying to copy
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    throw NSError(domain: "MeetingManager", code: -1, 
                                  userInfo: [NSLocalizedDescriptionKey: "Audio file not found at \(audioURL.path)"])
                }
                
                let audioFilename = "audio.m4a"
                let audioFileURL = meetingFolderURL.appendingPathComponent(audioFilename)
                try FileManager.default.copyItem(at: audioURL, to: audioFileURL)
                savedFiles.append(audioFilename)
            }
            
            statusMessage = "Saved to \(meetingFolderName): \(savedFiles.joined(separator: ", "))"
            
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            print("Save error details: \(error)")
        }
    }
    
    // MARK: - Live Speech-to-Text
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
        
        // Cancel any previous task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Create and configure the speech recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            print("❌ Failed to create recognition request")
            throw NSError(domain: "MeetingManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true // ✅ Offline mode
        
        print("✅ Recognition request created")
        
        let inputNode = audioEngine.inputNode
        print("✅ Got input node: \(inputNode)")
        
        // Start the recognition task
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] (result: SFSpeechRecognitionResult?, error: Error?) in
            guard let self = self else { return }
            
            if let result = result {
                Task { @MainActor in
                    self.liveTranscript = result.bestTranscription.formattedString
                    print("📝 Transcript updated (\(result.bestTranscription.formattedString.count) chars): \(self.liveTranscript.prefix(50))...")
                }
            }
            
            if let error = error {
                print("⚠️ Recognition error: \(error.localizedDescription)")
                let nsError = error as NSError
                print("   Error code: \(nsError.code), domain: \(nsError.domain)")
                
                Task { @MainActor in
                    // Don't stop on certain errors, just log them
                    if nsError.code != 216 { // 216 = retry error
                        self.statusMessage = "Transcription issue: \(error.localizedDescription)"
                    }
                }
            }
        }
        
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

            // Prepare WAV file for writing
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("audio_only_recording.wav")
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }

            let file = try AVAudioFile(forWriting: tempURL, settings: recordingFormat.settings)
            self.audioFile = file
            self.audioOnlyURL = tempURL

            // Set up live transcription
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                statusMessage = "Speech recognizer not available"
                return
            }

            recognitionTask?.cancel()
            recognitionTask = nil

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.recognitionRequest = request

            analyticsCollector.reset()
            rawTranscriptionSegments = []

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                if let result = result {
                    self.analyticsCollector.ingest(result: result)
                    let segments = result.bestTranscription.segments
                    Task { @MainActor in
                        self.liveTranscript = result.bestTranscription.formattedString
                        self.rawTranscriptionSegments = segments
                    }
                }
                if let error = error {
                    print("Recognition error: \(error.localizedDescription)")
                }
            }

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
            meetingTitle = ""
            isNotesSheetOpen = true
            statusMessage = "Recording (Audio Only)..."
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            print("Audio-only start error: \(error)")
        }
    }

    private func stopAudioOnly() async {
        statusMessage = "Stopping..."

        // Stop engine and transcription
        audioOnlyEngine?.stop()
        audioOnlyEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioFile = nil // Close the file handle

        isRecording = false
        isPaused = false
        amplitudes = Array(repeating: 0.1, count: 5)

        guard let wavURL = audioOnlyURL else {
            statusMessage = "No recording found"
            return
        }

        // Convert WAV to M4A for smaller file size
        statusMessage = "Converting audio..."
        guard let m4aURL = try? await convertToM4A(from: wavURL) else {
            // If conversion fails, use the live transcript with the WAV file
            if !liveTranscript.isEmpty {
                statusMessage = "Saving with live transcript..."
                saveTranscript(text: liveTranscript, videoURL: nil, audioURL: wavURL)
                try? FileManager.default.removeItem(at: wavURL)
                statusMessage = "Saved successfully"
            } else {
                statusMessage = "Audio conversion failed"
            }
            return
        }

        // Use live transcript if available, otherwise transcribe with WhisperKit
        let transcriptText: String
        if !liveTranscript.isEmpty {
            transcriptText = liveTranscript
        } else {
            statusMessage = "Transcribing with AI..."
            transcriptText = await transcribeAudio(audioURL: m4aURL)
        }

        // Run speaker diarization if we captured voice analytics
        let vectors = analyticsCollector.vectors
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
    func microphonePermissionStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func screenRecordingPermissionStatus() -> PermissionStatus {
        if #available(macOS 14.0, *) {
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        }
        return .granted
    }

    func requestScreenRecordingPermission() {
        if #available(macOS 14.0, *) {
            CGRequestScreenCaptureAccess()
        }
    }

    func speechRecognitionPermissionStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestSpeechRecognitionPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

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

    // MARK: - Delegate Method
    // CRITICAL: Must be nonisolated because SCKit calls this on a background thread
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.statusMessage = "Recorder Error: \(error.localizedDescription)"
            self.isRecording = false
        }
    }
}

extension MeetingManager {
    func startMonitoring() {
        let settings = [
            AVFormatIDKey: Int(kAudioFormatAppleLossless),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue
        ] as [String : Any]

        do {
            audioRecorder = try AVAudioRecorder(url: URL(fileURLWithPath: "/dev/null"), settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            
            // Update the visualizer 20 times per second
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.audioRecorder?.updateMeters()
                    let power = self.audioRecorder?.averagePower(forChannel: 0) ?? -60
                    
                    // Map the decibels (-60 to 0) to a scale of 0.1 to 1.0
                    let normalizedPower = max(0.1, CGFloat(pow(10, power / 20)))
                    
                    withAnimation(.linear(duration: 0.05)) {
                        // Create a staggered effect for the 5 bars
                        self.amplitudes = (0..<5).map { i in
                            normalizedPower * CGFloat.random(in: 0.8...1.2)
                        }
                    }
                }
            }
        } catch {
            print("Visualizer failed: \(error)")
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        audioRecorder?.stop()
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

