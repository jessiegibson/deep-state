#if os(macOS)
import AVFoundation
import SwiftUI

/// Drives the idle voice visualizer when the app is **not** recording. Runs an
/// `AVAudioRecorder` against /dev/null purely to read metering levels on a timer.
/// Extracted from `MeetingManager`; the manager owns one instance and forwards
/// `startMonitoring()`/`stopMonitoring()` so existing view call sites are unchanged.
///
/// Reports the 5 visualizer bar amplitudes via `onAmplitudes`. The owner decides how
/// to apply them (e.g. wrap in `withAnimation` and assign to its `@Published` array).
@MainActor
final class AmbientLevelMonitor {
    /// Called ~20×/sec with fresh bar amplitudes while monitoring.
    var onAmplitudes: (([CGFloat]) -> Void)?

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?

    func start() {
        // Stop any existing recorder before starting a new one
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()

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
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.audioRecorder?.updateMeters()
                    let power = self.audioRecorder?.averagePower(forChannel: 0) ?? -60

                    // Map the decibels (-60 to 0) to a scale of 0.1 to 1.0
                    let normalizedPower = max(0.1, CGFloat(pow(10, power / 20)))

                    // Create a staggered effect for the 5 bars
                    let bars = (0..<5).map { _ in normalizedPower * CGFloat.random(in: 0.8...1.2) }
                    self.onAmplitudes?(bars)
                }
            }
        } catch {
            print("Visualizer failed: \(error)")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        audioRecorder?.stop()
        audioRecorder = nil
    }
}
#endif
