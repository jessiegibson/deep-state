import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit

#endif

// MARK: - Design Tokens
enum NBDesign {
    // Typography
    static let headlineFont: Font = .system(size: 18, weight: .black, design: .monospaced)
    static let bodyFont: Font = .system(size: 14, weight: .medium, design: .monospaced)
    static let captionFont: Font = .system(size: 11, weight: .bold, design: .monospaced)
    static let buttonFont: Font = .system(size: 14, weight: .heavy, design: .monospaced)

    // Colors
    static let background = Color.white
    static let foreground = Color.green
    static let accent = Color(red: 1.0, green: 0.2, blue: 0.2)
    static let secondaryAccent = Color(red: 0.0, green: 0.5, blue: 1.0)
    static let surface = Color.gray.opacity(0.05)
    static let border = Color.black

    // Borders
    static let borderWidth: CGFloat = 3
    static let thinBorder: CGFloat = 1

    // Spacing
    static let padding: CGFloat = 16
    static let smallPadding: CGFloat = 8

    // Corner radius (sharp, minimal)
    static let cornerRadius: CGFloat = 2

    // Shadow (offset shadow for depth — classic brutalist technique)
    static let shadowOffset: CGFloat = 4
}

// MARK: - Reusable Modifiers
struct NBCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(NBDesign.padding)
            .background(NBDesign.surface)
            .overlay(
                Rectangle()
                    .stroke(NBDesign.border, lineWidth: NBDesign.borderWidth)
            )
            
    }
}

struct NBButtonStyle: ButtonStyle {
    var color: Color = NBDesign.foreground
    var textColor: Color = NBDesign.background

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NBDesign.buttonFont)
            .foregroundStyle(textColor)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(color)
            .overlay(
                Rectangle()
                    .stroke(NBDesign.border, lineWidth: NBDesign.borderWidth)
            )
            .offset(
                x: configuration.isPressed ? NBDesign.shadowOffset : 0,
                y: configuration.isPressed ? NBDesign.shadowOffset : 0
            )
            
    }
}

extension View {
    func nbCard() -> some View {
        modifier(NBCardModifier())
    }
}

extension Color {
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(UIColor(dynamicProvider: { traits in
            switch traits.userInterfaceStyle {
            case .dark:
                return UIColor(dark)
            default:
                return UIColor(light)
            }
        }))
        #elseif canImport(AppKit)
        self.init(NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        }))
        #else
        self = light
        #endif
    }
}
