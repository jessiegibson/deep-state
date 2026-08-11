#if os(macOS)
import AVFoundation
import AppKit
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

    /// Set once we've called `CGRequestScreenCaptureAccess()`. Needed because TCC
    /// gives us no way to read back "denied" — preflight returns false for both
    /// "never asked" and "asked and refused", and those need opposite UI.
    private static let screenRequestedKey = "hasRequestedScreenRecording"

    static var hasRequestedScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: screenRequestedKey) }
        set { UserDefaults.standard.set(newValue, forKey: screenRequestedKey) }
    }

    static func screenRecordingStatus() -> PermissionStatus {
        guard #available(macOS 14.0, *) else { return .granted }
        if CGPreflightScreenCaptureAccess() { return .granted }
        return hasRequestedScreenRecording ? .denied : .notDetermined
    }

    /// Asks for screen-recording access, or routes to System Settings when asking
    /// can no longer do anything.
    ///
    /// `CGRequestScreenCaptureAccess()` only shows the system prompt while TCC holds
    /// *no* record for this bundle ID. Once a record exists — granted, denied, or
    /// inherited from an earlier build of the app at a different path — it returns
    /// silently and the user sees nothing at all. Calling it unconditionally is what
    /// makes a GRANT button look dead.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        guard #available(macOS 14.0, *) else { return true }
        if CGPreflightScreenCaptureAccess() { return true }

        if hasRequestedScreenRecording {
            openScreenRecordingSettings()
        } else {
            hasRequestedScreenRecording = true
            CGRequestScreenCaptureAccess()
        }
        return false
    }

    /// Opens Privacy & Security → Screen Recording.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
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

        if #available(macOS 14.0, *), !CGPreflightScreenCaptureAccess(), !hasRequestedScreenRecording {
            hasRequestedScreenRecording = true
            CGRequestScreenCaptureAccess()
        }

        return message
    }
}
#endif
