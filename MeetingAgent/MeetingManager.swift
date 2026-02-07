import SwiftUI
import ScreenCaptureKit
import WhisperKit
import Combine
import AVFoundation


@MainActor
class MeetingManager: NSObject, ObservableObject, SCRecordingOutputDelegate {
    @Published var isRecording = false
    @Published var statusMessage = "Ready"
    @Published var savedFolderURL: URL?
    
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
    
    // Voice Visualizer Properties
    @Published var amplitudes: [CGFloat] = Array(repeating: 0.1, count: 5)
    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    
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

        // Screen Recording Check (macOS 15+)
        if #available(macOS 14.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                // This opens the system dialog
                CGRequestScreenCaptureAccess()
            }
        }
    }

    override init() {
        super.init()
        loadSavedFolder()
        
        // 1. Check permissions immediately on startup
        checkPermissions()
        
        // 2. Start loading the AI model in the background
        Task { await setupEngine() }
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
        statusMessage = "Starting..."
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                statusMessage = "No display found"
                return
            }
            
            // Exclude our own app window to prevent 'infinity mirror' effect
            let excludedWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            
            // Apply User Preferences
            config.capturesAudio = shouldRecordSystemAudio
            if #available(macOS 14.0, *) {
                config.captureMicrophone = true
            }
            
            // Set temp recording path
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("temp_rec.mov")
            self.lastRecordingURL = url
            
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            
            let recordConfig = SCRecordingOutputConfiguration()
            recordConfig.outputURL = url
            recordConfig.outputFileType = .mov
            recordConfig.videoCodecType = .h264
            
            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            recordingOutput = SCRecordingOutput(configuration: recordConfig, delegate: self)
            
            guard let stream = stream, let recordingOutput = recordingOutput else { return }
            
            try stream.addRecordingOutput(recordingOutput)
            try await stream.startCapture()
            
            isRecording = true
            statusMessage = "Recording..."
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }
    
    func stopAndTranscribe() async {
        statusMessage = "Stopping..."
        
        do {
            try await stream?.stopCapture()
            isRecording = false
            
            guard let url = lastRecordingURL else { return }
            guard let whisper = self.whisper else {
                statusMessage = "AI Model not loaded yet."
                return
            }
            
            statusMessage = "Extracting audio..."
            
            // Extract audio from the .mov file to a format WhisperKit can handle
            guard let audioURL = try await extractAudio(from: url) else {
                statusMessage = "Failed to extract audio"
                return
            }
            
            statusMessage = "Transcribing (this may take a moment)..."
            
            let result = try await whisper.transcribe(audioPath: audioURL.path)
            let transcriptText = result.first?.text ?? "No text found"
            
            saveTranscript(text: transcriptText, videoURL: url)
            
            // Clean up the extracted audio file
            try? FileManager.default.removeItem(at: audioURL)
            
        } catch {
            statusMessage = "Processing failed: \(error.localizedDescription)"
            isRecording = false
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
    func saveTranscript(text: String, videoURL: URL? = nil) {
        guard let folderURL = savedFolderURL else { return }
        
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
        dateFormatter.dateFormat = "yyyyMMdd:HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let baseFilename = "meeting-\(timestamp)"
        
        // Save the transcript
        let transcriptFilename = "\(baseFilename).md"
        let transcriptFileURL = folderURL.appendingPathComponent(transcriptFilename)
        
        do {
            try text.write(to: transcriptFileURL, atomically: true, encoding: .utf8)
            
            // Save the video file if provided
            if let videoURL = videoURL {
                let videoFilename = "\(baseFilename).mov"
                let videoFileURL = folderURL.appendingPathComponent(videoFilename)
                
                try FileManager.default.copyItem(at: videoURL, to: videoFileURL)
                statusMessage = "Saved \(transcriptFilename) and \(videoFilename)"
            } else {
                statusMessage = "Transcript Saved to \(transcriptFilename)"
            }
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
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
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
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

