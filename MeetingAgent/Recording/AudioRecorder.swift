#if os(macOS)
import Foundation
@preconcurrency import AVFoundation

/// Audio-only capture: runs an `AVAudioEngine` input tap that writes a WAV file,
/// forwards buffers to the live transcriber, and reports visualizer amplitudes.
/// Also converts the WAV to M4A. Extracted from `MeetingManager`.
@MainActor
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private(set) var wavURL: URL?
    private var converter: AVAudioConverter?
    private var configChangeObserver: (any NSObjectProtocol)?
    private var isPausedByUser = false

    /// Each captured microphone buffer (for the live transcriber). Called on the audio thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// The 5 visualizer bar amplitudes, reported on the main actor.
    var onAmplitudes: (([CGFloat]) -> Void)?

    /// Standard 16-bit signed integer PCM. AVAudioEngine input delivers 32-bit float
    /// PCM, but AVAssetExportSession rejects float-PCM WAVs — forcing 16-bit int keeps
    /// the downstream M4A conversion (and any reader) happy.
    nonisolated static func wavWriteSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
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
        isPausedByUser = false
        converter = nil

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            self.engine = nil
            throw NSError(domain: "AudioRecorder", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "No active audio input. If you're using Bluetooth headphones, their microphone may still be switching on — try again, or pick another input in System Settings → Sound."
            ])
        }

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

        installTap(format: recordingFormat)

        // Bluetooth headsets renegotiate their profile (A2DP → HFP) when the mic
        // engages, which changes the input hardware format mid-session and kills a
        // fixed-format tap. Reinstall the tap on the new format and keep writing
        // through a converter so the WAV and the recognizer stay valid.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }

        engine.prepare()
        try engine.start()
        return tempURL
    }

    /// Single tap: write to file + feed recognizer + compute amplitude.
    /// Buffers are converted to the file's processing format when the hardware
    /// format has drifted from the one the WAV was created with.
    private func installTap(format: AVAudioFormat) {
        engine?.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, let file = self.audioFile else { return }

            let outBuffer: AVAudioPCMBuffer
            if buffer.format.isEqual(file.processingFormat) {
                outBuffer = buffer
            } else {
                guard let converted = self.convert(buffer, to: file.processingFormat) else { return }
                outBuffer = converted
            }

            do {
                try file.write(from: outBuffer)
            } catch {
                print("[AudioRecorder] WAV write failed: \(error)")
            }

            // Feed to the live transcriber
            self.onBuffer?(outBuffer)

            // Compute amplitude for visualizer
            guard let channelData = outBuffer.floatChannelData?[0] else { return }
            let frameLength = Int(outBuffer.frameLength)
            guard frameLength > 0 else { return }
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
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat.isEqual(buffer.format) != true {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            print("[AudioRecorder] Buffer conversion failed: \(convError?.localizedDescription ?? "unknown")")
            return nil
        }
        return out
    }

    private func handleConfigurationChange() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            print("[AudioRecorder] Input device went away after configuration change")
            return
        }
        converter = nil
        installTap(format: newFormat)
        if !isPausedByUser && !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    func pause() {
        isPausedByUser = true
        engine?.pause()
    }

    func resume() throws {
        isPausedByUser = false
        try engine?.start()
    }

    /// Stops the engine, removes the tap, and closes the file handle.
    func stop() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        audioFile = nil
        converter = nil
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
