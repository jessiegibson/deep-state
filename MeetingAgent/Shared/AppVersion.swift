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

    /// e.g. `macOS v0.8 (20260625) · DEBUG`
    static var displayString: String {
        "\(platform) v\(short) (\(build)) · \(configuration) - built: \(buildDate)"
    }
}

// MARK: - Version Footer

/// Thin build stamp pinned under a screen. Testing aid — the text is selectable
/// so it can be pasted straight into a bug report.
struct VersionFooter: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(NBDesign.border)
                .frame(height: NBDesign.thinBorder)

            Text(AppVersion.displayString)
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
