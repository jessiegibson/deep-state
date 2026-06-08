import XCTest
import AVFoundation
@testable import deep_state_Meeting_Agent

/// Guards the regression fixed in commit 6864973: the capture WAV must be written as
/// 16-bit *integer* PCM. AVAudioEngine input is 32-bit float, but AVAssetExportSession
/// rejects float-PCM WAVs, breaking the M4A conversion.
final class AudioRecorderSettingsTests: XCTestCase {

    func testWavSettingsAre16BitIntegerPCM() {
        let settings = AudioRecorder.wavWriteSettings(sampleRate: 44100, channels: 1)

        XCTAssertEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
    }

    func testWavSettingsPreserveSampleRateAndChannels() {
        let settings = AudioRecorder.wavWriteSettings(sampleRate: 48000, channels: 2)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 48000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? AVAudioChannelCount, 2)
    }
}
