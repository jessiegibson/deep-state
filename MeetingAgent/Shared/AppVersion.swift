import SwiftUI

// MARK: - App Version

/// Build stamp read straight out of the bundle so it can never drift from what
/// Xcode actually shipped. Both targets set `GENERATE_INFOPLIST_FILE = YES`, so
/// `MARKETING_VERSION` lands in `CFBundleShortVersionString` and
/// `CURRENT_PROJECT_VERSION` in `CFBundleVersion`.
enum AppVersion {
    static let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    #if DEBUG
    static let configuration = "DEBUG"
    #else
    static let configuration = "RELEASE"
    #endif

    #if os(macOS)
    static let platform = "macOS"
    #else
    static let platform = "iOS"
    #endif
    
    /// Modification time of the built executable — when this binary was compiled.
    static let buildDate: String = {
        guard let url = Bundle.main.executableURL,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                                  .contentModificationDate
        else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: date)
    }()

    /// TestFlight installs carry a sandbox receipt; App Store installs carry the
    /// production one. This is how we tell a tester's copy from a customer's copy.
    ///
    /// `appStoreReceiptURL` is deprecated in favour of StoreKit's `AppTransaction`,
    /// which is async and can hit the network on first call — far too much machinery
    /// for a footer label. Deliberately kept. If it is ever removed this stops
    /// compiling rather than misbehaving, and the fallback is the customer-facing
    /// string, which is the safe direction to fail.
    static let isTestFlight: Bool = {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }()

    /// Debug and TestFlight builds get the full diagnostic stamp. App Store builds
    /// do not — a shipped app should not advertise its build configuration, its
    /// compile time, or the platform it was built for.
    static var isInternalBuild: Bool {
        #if DEBUG
        return true
        #else
        return isTestFlight
        #endif
    }

    /// Full diagnostic stamp, e.g. `iOS v0.8 (20260922) · DEBUG · built Sep 22 12:25`
    static var displayString: String {
        "\(platform) v\(short) (\(build)) · \(configuration) · built \(buildDate)"
    }

    /// What customers see, e.g. `v0.8 (20260922)` — enough for a support ticket,
    /// nothing more.
    static var releaseString: String {
        "v\(short) (\(build))"
    }

    /// The string the footer renders, chosen by build channel.
    static var footerString: String {
        isInternalBuild ? displayString : releaseString
    }
}

// MARK: - Version Footer

/// Thin build stamp pinned under a screen. In Debug and TestFlight it carries the
/// full diagnostic string so a tester can paste it into a bug report; in an App
/// Store build it narrows to `v<version> (<build>)`.
struct VersionFooter: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(NBDesign.border)
                .frame(height: NBDesign.thinBorder)

            Text(AppVersion.footerString)
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .background(NBDesign.surface)
    }
}

struct NBVersionFooterModifier: ViewModifier {
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            VersionFooter()
        }
    }
}

extension View {
    /// Pins the build stamp under this view. Apply to a screen's root container.
    func nbVersionFooter() -> some View {
        modifier(NBVersionFooterModifier())
    }
}
