#if os(macOS)
import Foundation
import AVFoundation

/// Audio-only capture: runs an `AVAudioEngine` input tap that writes a WAV file,
/// forwards buffers to the live transcriber, and reports visualizer amplitudes.
/// Also converts the WAV to M4A. Extracted from `MeetingManager`.
@MainActor
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private(set) var wavURL: URL?

    /// Each captured microphone buffer (for the live transcriber). Called on the audio thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// The 5 visualizer bar amplitudes, reported on the main actor.
    var onAmplitudes: (([CGFloat]) -> Void)?

    /// Standard 16-bit signed integer PCM. AVAudioEngine input delivers 32-bit float
    /// PCM, but AVAssetExportSession rejects float-PCM WAVs — forcing 16-bit int keeps
    /// the downstream M4A conversion (and any reader) happy.
    static func wavWriteSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Starts capturing to a temp WAV file and returns its URL.
    func start() throws -> URL {
        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_only_recording.wav")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let file = try AVAudioFile(
            forWriting: tempURL,
            settings: Self.wavWriteSettings(
                sampleRate: recordingFormat.sampleRate,
                channels: recordingFormat.channelCount
            )
        )
        self.audioFile = file
        self.wavURL = tempURL

        // Single tap: write to file + feed recognizer + compute amplitude
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Write to audio file
            try? self.audioFile?.write(from: buffer)

            // Feed to the live transcriber
            self.onBuffer?(buffer)

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
                let bars = (0..<5).map { _ in min(1.0, normalizedPower * CGFloat.random(in: 0.8...1.2)) }
                self.onAmplitudes?(bars)
            }
        }

        engine.prepare()
        try engine.start()
        return tempURL
    }

    func pause() {
        engine?.pause()
    }

    func resume() throws {
        try engine?.start()
    }

    /// Stops the engine, removes the tap, and closes the file handle.
    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        audioFile = nil
        engine = nil
    }

    func convertToM4A(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_converted.m4a")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(domain: "AudioRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        try await exportSession.export(to: outputURL, as: .m4a)
        return outputURL
    }
}
#endif
