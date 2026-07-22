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
/// IMPORTANT: `SCRecordingOutput` does NOT finalize the MOV (moov atom) when
/// `stopCapture()` returns. We must call `removeRecordingOutput()` and await the
/// `didFinishRecordingTo:` delegate before the file is readable. `finalizeAndStop()`
/// encapsulates that handshake — never read a captured file without calling it first.
@MainActor
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    /// Mirrors the user's "record system audio" preference; applied at capture start.
    var captureSystemAudio = false
    var captureMicrophone = false
    /// Display to record, chosen by the user. Falls back to the first available display
    /// when nil or when the id no longer matches a connected display.
    var selectedDisplayID: CGDirectDisplayID?

    /// Surfaced to the owner when the stream stops unexpectedly or the recorder errors.
    var onStreamStopped: ((Error) -> Void)?
    var onRecorderError: ((Error) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingFinishedContinuation: CheckedContinuation<Void, Never>?

    var isCapturing: Bool { stream != nil }

    /// Lists connected displays as recordable options, labeled with each screen's
    /// system name (e.g. "Built-in Retina Display") via a match against `NSScreen.screens`.
    static func availableDisplays() async throws -> [DisplayOption] {
        let content = try await SCShareableContent.current
        return content.displays.map { display in
            let name = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }?.localizedName ?? "Display"
            return DisplayOption(id: display.displayID, name: name, width: Int(display.width), height: Int(display.height))
        }
    }

    /// The display currently containing the app's key window, if determinable —
    /// used as the default selection so the picker doesn't default to an arbitrary screen.
    static func displayContainingKeyWindow(in options: [DisplayOption]) -> CGDirectDisplayID? {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main,
              let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return options.first?.id }
        return options.first { $0.id == screenNumber }?.id ?? options.first?.id
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

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID })
            ?? content.displays.first else {
            throw NSError(domain: "ScreenRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let excludedWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.capturesAudio = captureSystemAudio
        config.captureMicrophone = captureMicrophone
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
        recordConfig.outputFileType = .mov
        recordConfig.videoCodecType = .h264

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        recordingOutput = SCRecordingOutput(configuration: recordConfig, delegate: self)

        guard let s = stream, let ro = recordingOutput else {
            throw NSError(domain: "ScreenRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create stream or recording output"])
        }

        try s.addRecordingOutput(ro)
        try await s.startCapture()
    }

    /// Finalizes the current segment's MOV file (removeRecordingOutput → await
    /// didFinishRecordingTo:) then stops capture. Safe to call when not capturing.
    func finalizeAndStop() async throws {
        if let s = stream, let ro = recordingOutput {
            do {
                try s.removeRecordingOutput(ro)
                await withCheckedContinuation { continuation in
                    self.recordingFinishedContinuation = continuation
                }
            } catch {
                print("[ScreenRecorder] removeRecordingOutput failed: \(error)")
            }
            // The MOV is finalized once didFinishRecordingTo: has fired. If the stream
            // already died internally (e.g. an audio pipeline error), stopCapture()
            // throws — but the recording on disk is still good, so don't propagate.
            do {
                try await s.stopCapture()
            } catch {
                print("[ScreenRecorder] stopCapture failed after finalization (recording kept): \(error)")
            }
        }
        stream = nil
        recordingOutput = nil
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

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFinishRecordingTo url: URL) {
        Task { @MainActor in
            self.recordingFinishedContinuation?.resume()
            self.recordingFinishedContinuation = nil
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.recordingFinishedContinuation?.resume()
            self.recordingFinishedContinuation = nil
            self.onRecorderError?(error)
        }
    }
}
#endif
