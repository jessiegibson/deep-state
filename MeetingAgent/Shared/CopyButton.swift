import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Clipboard
// AppKit and UIKit share no pasteboard API — this is the only place that
// difference is handled.

enum NBClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Copy Button

/// Copies `text` and briefly confirms with a checkmark before reverting.
struct NBCopyButton: View {
    let text: String
    var label: String = "COPY"

    @State private var copied = false

    var body: some View {
        Button {
            NBClipboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .bold))
                Text(copied ? "COPIED" : label)
                    .font(NBDesign.captionFont)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(copied ? NBDesign.background : Color.primary)
            .background(copied ? NBDesign.foreground : Color.clear)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy \(label.lowercased())")
    }
}

// MARK: - Section Header

/// Section label with an optional copy affordance on the trailing edge.
struct NBSectionHeader: View {
    let title: String
    var copyText: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)
            Spacer()
            if let copyText, !copyText.isEmpty {
                NBCopyButton(text: copyText)
            }
        }
    }
}
