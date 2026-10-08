#if os(macOS)
import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation

/// A display the user can choose to record, with a human-readable label.
struct DisplayOption: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int

    var label: String { "\(name) · \(width)×\(height)" }
}

/// Owns the ScreenCaptureKit stream lifecycle: starting capture, the recording-output
/// finalization handshake, and merging paused segments. Extracted from `MeetingManager`.
///
/// IMPORTANT: `SCRecordingOutput` does NOT finalize the MOV (moov atom) synchronously.
/// Per `SCStream.h`, "if stopCapture is called without removing recordingOutput,
/// recording will be stopped and finish writing into the file" — so `stopCapture()`
/// begins finalization and `recordingOutputDidFinishRecording(_:)` reports when the
/// file is actually readable. `finalizeAndStop()` encapsulates that handshake —
/// never read a captured file without calling it first.
///
/// Do NOT reintroduce `removeRecordingOutput()` here: it is redundant with
/// `stopCapture()` and throws `SCStreamErrorInvalidParameter` (-3812) once the
/// recording output has already finished. See REGRESSION_REGISTER.md L5.
@MainActor
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    /// Mirrors the user's "record system audio" preference; applied at capture start.
    var captureSystemAudio = false
    /// Display to record, chosen by the user. Falls back to the first available display
    /// when nil or when the id no longer matches a connected display.
    var selectedDisplayID: CGDirectDisplayID?

    /// Surfaced to the owner when the stream stops unexpectedly or the recorder errors.
    var onStreamStopped: ((Error) -> Void)?
    var onRecorderError: ((Error) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?

    /// Finalization handshake state. `didFinishRecording` guards the case where the
    /// delegate fires *before* `finalizeAndStop()` starts awaiting, which would
    /// otherwise park the continuation forever.
    private var recordingFinishedContinuation: CheckedContinuation<Void, Never>?
    private var didFinishRecording = false
    private var recordingFailure: Error?

    var isCapturing: Bool { stream != nil }

    /// Lists connected displays as recordable options, labeled with each screen's
    /// system name (e.g. "Built-in Retina Display") via a match against `NSScreen.screens`.
    static func availableDisplays() async throws -> [DisplayOption] {
        let content = try await SCShareableContent.current
        return content.displays.map { display in
            DisplayOption(id: display.displayID,
                          name: localizedName(for: display.displayID),
                          width: Int(display.width),
                          height: Int(display.height))
        }
    }

    /// The system's name for a display ("Built-in Retina Display"), matched through
    /// `NSScreen`. Falls back to a generic label when the id no longer matches a
    /// connected screen. Also used to label screenshots in the manifest.
    static func localizedName(for displayID: CGDirectDisplayID) -> String {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.localizedName ?? "Display"
    }

    /// The display currently containing the app's key window, if determinable —
    /// used as the default selection so the picker doesn't default to an arbitrary screen.
    static func displayContainingKeyWindow(in options: [DisplayOption]) -> CGDirectDisplayID? {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main,
              let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return options.first?.id }
        return options.first { $0.id == screenNumber }?.id ?? options.first?.id
    }

    /// Resolves a display and builds a content filter that excludes this app's own
    /// windows.
    ///
    /// Shared by `startCapture` and `ScreenshotCapture` so a recording and a screenshot
    /// of the same moment see exactly the same thing. The exclusion is the point: with
    /// it, neither a captured frame nor a recorded one contains the recorder UI that
    /// produced it.
    ///
    /// Returns the `SCDisplay` alongside the filter because callers need its
    /// dimensions — the stream for its configuration, screenshots for the manifest.
    static func makeContentFilter(displayID: CGDirectDisplayID?) async throws -> (SCContentFilter, SCDisplay) {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else {
            throw NSError(domain: "ScreenRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let excludedWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        return (SCContentFilter(display: display, excludingWindows: excludedWindows), display)
    }

    /// Begins capturing the main display to `url`.
    func startCapture(to url: URL) async throws {
        if #available(macOS 14.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                throw NSError(domain: "ScreenRecorder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission required. Check System Settings → Privacy & Security → Screen Recording"])
            }
        }

        // Tear down any stale stream from a previous failed attempt
        if let s = stream {
            try? await s.stopCapture()
            stream = nil
        }
        recordingOutput = nil
        didFinishRecording = false
        recordingFailure = nil

        let (filter, display) = try await Self.makeContentFilter(displayID: selectedDisplayID)

        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.capturesAudio = captureSystemAudio
        // Do NOT set config.captureMicrophone here — in a sandboxed app it makes
        // ScreenCaptureKit build an aggregated HAL virtual device (system audio + mic),
        // and HAL daemon communication fails, dropping every frame from the start
        // (REGRESSION_REGISTER.md L9). Screen recordings capture system audio only;
        // mic audio is not available via SCStream in this app.
        if captureSystemAudio {
            // Apple requires an explicit audio format when capturesAudio is on;
            // leaving these unset can fail the stream with "invalid parameter".
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let recordConfig = SCRecordingOutputConfiguration()
        recordConfig.outputURL = url
        // Only apply container/codec overrides the OS actually advertises — setting an
        // unsupported value is a documented source of SCStreamErrorInvalidParameter.
        // Falling back to the defaults (MPEG-4 / H.264) still produces a readable file.
        if recordConfig.availableOutputFileTypes.contains(.mov) {
            recordConfig.outputFileType = .mov
        } else {
            print("[ScreenRecorder] .mov unsupported; using default \(recordConfig.outputFileType)")
        }
        if recordConfig.availableVideoCodecTypes.contains(.h264) {
            recordConfig.videoCodecType = .h264
        } else {
            print("[ScreenRecorder] h264 unsupported; using default \(recordConfig.videoCodecType)")
        }

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        recordingOutput = SCRecordingOutput(configuration: recordConfig, delegate: self)

        guard let s = stream, let ro = recordingOutput else {
            throw NSError(domain: "ScreenRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create stream or recording output"])
        }

        try s.addRecordingOutput(ro)
        try await s.startCapture()
    }

    /// Stops capture and waits for the recording output to finish writing the file.
    /// Safe to call when not capturing. Throws only if the recording output itself
    /// reported a failure — the file is unusable in that case.
    func finalizeAndStop() async throws {
        guard let s = stream else {
            stream = nil
            recordingOutput = nil
            return
        }
        defer {
            stream = nil
            recordingOutput = nil
        }

        // stopCapture() both stops the stream and tells the recording output to
        // finish writing. If the stream already died internally, this throws -3808
        // ("already stopped") — the recording on disk is still being finalized, so
        // don't propagate; wait for the delegate below to say whether it's good.
        do {
            try await s.stopCapture()
        } catch {
            print("[ScreenRecorder] stopCapture failed, awaiting finalization anyway: \(error)")
        }

        await awaitRecordingFinished(timeout: .seconds(15))

        if let failure = recordingFailure {
            throw failure
        }
    }

    /// Awaits `recordingOutputDidFinishRecording(_:)` / `didFailWithError:`, giving up
    /// after `timeout` so a delegate that never arrives can't wedge the stop flow.
    private func awaitRecordingFinished(timeout: Duration) async {
        guard !didFinishRecording else { return }

        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            print("[ScreenRecorder] timed out waiting for recording finalization")
            self.resumeFinalizationWaiter()
        }
        defer { timeoutTask.cancel() }

        await withCheckedContinuation { continuation in
            self.recordingFinishedContinuation = continuation
        }
    }

    /// Resumes the finalization waiter exactly once. MainActor-isolated, so the
    /// delegate callbacks and the timeout task can't double-resume.
    private func resumeFinalizationWaiter() {
        recordingFinishedContinuation?.resume()
        recordingFinishedContinuation = nil
    }

    /// Concatenates paused recording segments into a single MOV via composition.
    func mergeSegments(_ urls: [URL]) async throws -> URL {
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
            throw NSError(domain: "ScreenRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create export session for merge"])
        }

        try await exportSession.export(to: outputURL, as: .mov)
        return outputURL
    }

    // MARK: - Delegate Methods
    // CRITICAL: Must be nonisolated because SCKit calls these on a background thread
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("DIDSTOPWITH ERROR FIRED")
        Task { @MainActor in
            self.onStreamStopped?(error)
        }
    }

    // NOTE: these three selectors are the *entire* SCRecordingOutputDelegate protocol
    // (see SCRecordingOutput.h). They are @optional, so a misspelled signature compiles
    // fine and simply never fires — which is exactly how the old
    // `recordingOutput(_:didFinishRecordingTo:)` silently broke finalization.
    // Do not rename these without checking the header.
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            print("[ScreenRecorder] recording started")
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.didFinishRecording = true
            self.resumeFinalizationWaiter()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.didFinishRecording = true
            self.recordingFailure = error
            self.resumeFinalizationWaiter()
            self.onRecorderError?(error)
        }
    }
}
#endif
