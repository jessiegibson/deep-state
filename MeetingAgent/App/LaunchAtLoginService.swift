#if os(macOS)
import Foundation
import Observation
import ServiceManagement

/// Launch-at-login, backed by `SMAppService.mainApp` (macOS 13+).
///
/// `SMAppService` registers the app bundle itself, so there is no separate helper
/// app to build, embed, code-sign and keep in sync — which is what the deprecated
/// `SMLoginItemSetEnabled` required.
///
/// The state lives in the system, not in `UserDefaults`: the user can turn the app
/// off in System Settings → General → Login Items at any time and the app is never
/// told. So `status` is always read back from `SMAppService` rather than cached, and
/// the toggle re-reads it whenever the settings sheet appears.
@MainActor
@Observable
final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    /// Set when a register/unregister call fails, for display next to the toggle.
    private(set) var lastError: String?

    private init() {}

    /// Whether the app is currently registered to launch at login.
    ///
    /// `.requiresApproval` deliberately reads as off: the app is registered but the
    /// user has switched it off in System Settings, and it will not launch. Showing
    /// the toggle as on would be a lie.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the app is registered but System Settings is holding it back. The UI
    /// uses this to offer the Login Items pane, because toggling here cannot fix it.
    var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Registers or unregisters the app. Returns the status actually in effect
    /// afterwards, which is not necessarily what was asked for.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        do {
            if enabled {
                // Registering while already registered throws, and unregistering
                // while not registered throws. Both are no-ops as far as the user is
                // concerned, so don't surface them as errors.
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return false }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
            print("[LaunchAtLogin] \(enabled ? "register" : "unregister") failed: \(error)")
        }
        return isEnabled
    }

    /// Opens System Settings → General → Login Items, the only place a
    /// `.requiresApproval` state can be resolved.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
#endif
