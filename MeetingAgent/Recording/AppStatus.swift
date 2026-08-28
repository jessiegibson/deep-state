#if os(macOS)
import Foundation

/// Why an operation failed, as a value rather than a sentence.
///
/// The old `statusMessage: String` carried success, progress and failure on one
/// channel, so nothing downstream could tell them apart: the UI styled a crash the
/// same as "Saved", and there was no stable key to bucket failures by. Each case
/// here owns its user-facing wording *and* a `code` that stays put when the wording
/// changes, which is what analytics and bug reports should key on.
enum AppFailure: Error, Equatable {

    // Permissions
    case microphoneDenied
    case screenRecordingDenied

    // Model
    case modelLoadFailed(String)

    // Capture
    case captureStartFailed(String)
    case streamStopped(String)
    case recorderError(String)
    case pauseFailed(String)
    case resumeFailed(String)

    // Post-processing
    case noRecordingFound
    case recordingEmpty
    case noAudioTrack
    case audioExtractionFailed
    case audioConversionFailed
    case processingFailed(description: String, domain: String, code: Int)

    // Storage
    case noSaveLocation
    case saveLocationDenied
    case saveFailed(String)

    // Import / retranscribe
    case importFailed(String)

    /// Stable identifier for grouping. Never derive this from `message` — the
    /// wording is expected to change and the bucket is not.
    var code: String {
        switch self {
        case .microphoneDenied:      return "mic_denied"
        case .screenRecordingDenied: return "screen_denied"
        case .modelLoadFailed:       return "model_load_failed"
        case .captureStartFailed:    return "capture_start_failed"
        case .streamStopped:         return "stream_stopped"
        case .recorderError:         return "recorder_error"
        case .pauseFailed:           return "pause_failed"
        case .resumeFailed:          return "resume_failed"
        case .noRecordingFound:      return "no_recording_found"
        case .recordingEmpty:        return "recording_empty"
        case .noAudioTrack:          return "no_audio_track"
        case .audioExtractionFailed: return "audio_extraction_failed"
        case .audioConversionFailed: return "audio_conversion_failed"
        case .processingFailed:      return "processing_failed"
        case .noSaveLocation:        return "no_save_location"
        case .saveLocationDenied:    return "save_location_denied"
        case .saveFailed:            return "save_failed"
        case .importFailed:          return "import_failed"
        }
    }

    /// Whether the user can do something about this without a relaunch. Drives
    /// whether the UI offers a next step alongside the message.
    var isRecoverable: Bool {
        switch self {
        case .microphoneDenied, .screenRecordingDenied, .noSaveLocation, .saveLocationDenied:
            return true
        default:
            return false
        }
    }

    var message: String {
        switch self {
        case .microphoneDenied:
            return "Microphone access denied — enable it in System Settings → Privacy & Security → Microphone."
        case .screenRecordingDenied:
            return "Screen Recording permission denied — enable it in System Settings, then relaunch."
        case .modelLoadFailed(let detail):
            return "AI load failed: \(detail)"
        case .captureStartFailed(let detail):
            return "Couldn't start recording: \(detail)"
        case .streamStopped(let detail):
            return "Stream stopped: \(detail)"
        case .recorderError(let detail):
            return "Recorder error: \(detail)"
        case .pauseFailed(let detail):
            return "Pause failed: \(detail)"
        case .resumeFailed(let detail):
            return "Resume failed: \(detail)"
        case .noRecordingFound:
            return "No recording found"
        case .recordingEmpty:
            return "Recording was empty — nothing was captured"
        case .noAudioTrack:
            return "No audio track found in recording"
        case .audioExtractionFailed:
            return "Audio extraction failed — saving video only"
        case .audioConversionFailed:
            return "M4A conversion failed — audio saved as WAV"
        case .processingFailed(let description, let domain, let code):
            return "Processing failed: \(description) [\(domain) \(code)]"
        case .noSaveLocation:
            return "No save location selected"
        case .saveLocationDenied:
            return "Permission denied to access folder"
        case .saveFailed(let detail):
            return "Save failed: \(detail)"
        case .importFailed(let detail):
            return detail
        }
    }
}

/// The single status channel for `MeetingManager`, replacing the free-form
/// `statusMessage: String`.
///
/// Callers assign a case; the UI reads `message` for text and `severity` for
/// styling, and can pull `failure` out to branch on a specific error.
enum AppStatus: Equatable {
    /// Nothing in flight.
    case idle
    /// Transient work with a phase label — "Extracting audio…", "Saving files…".
    case progress(String)
    /// Capturing. `micNote` is non-nil when the mic is *not* being captured, and
    /// says why; a silent recording must never be a surprise found after the fact.
    case recording(mode: RecordingMode, micNote: String?)
    case paused
    case success(String)
    case failure(AppFailure)

    enum Severity {
        case neutral, active, success, failure
    }

    var severity: Severity {
        switch self {
        case .idle:                     return .neutral
        case .progress:                 return .active
        case .recording(_, let micNote): return micNote == nil ? .active : .failure
        case .paused:                   return .neutral
        case .success:                  return .success
        case .failure:                  return .failure
        }
    }

    var message: String {
        switch self {
        case .idle:
            return "Ready"
        case .progress(let text):
            return text
        case .recording(let mode, let micNote):
            if let micNote { return "Recording — NO MIC (\(micNote))" }
            return mode == .audioOnly ? "Recording (Audio Only)…" : "Recording…"
        case .paused:
            return "Paused"
        case .success(let text):
            return text
        case .failure(let failure):
            return failure.message
        }
    }

    /// Non-nil only in the `.failure` case. Lets call sites branch on the error
    /// category without re-parsing the message.
    var failure: AppFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }

    var isFailure: Bool { failure != nil }
}
#endif
