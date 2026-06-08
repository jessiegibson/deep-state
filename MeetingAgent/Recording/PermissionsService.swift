#if os(macOS)
import AVFoundation
import Speech
import ScreenCaptureKit

/// Stateless wrapper around the system permission APIs used by onboarding and
/// recording start-up. Extracted from `MeetingManager` so the permission logic
/// can be reasoned about (and unit-exercised) on its own. `MeetingManager` keeps
/// thin forwarding methods so existing call sites (`OnboardingView`) are unchanged.
enum PermissionsService {

    // MARK: Microphone
    static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: Screen Recording
    static func screenRecordingStatus() -> PermissionStatus {
        if #available(macOS 14.0, *) {
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        }
        return .granted
    }

    static func requestScreenRecording() {
        if #available(macOS 14.0, *) {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Speech Recognition
    static func speechRecognitionStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Prompts for microphone and screen-recording access on startup.
    /// Returns a status message if access is denied, otherwise nil.
    @discardableResult
    static func requestStartupPermissions() -> String? {
        var message: String? = nil

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .denied, .restricted:
            message = "Microphone access denied. Enable in Settings."
        default:
            break
        }

        if #available(macOS 14.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }
        }

        return message
    }
}
#endif
