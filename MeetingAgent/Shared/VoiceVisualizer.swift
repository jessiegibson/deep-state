//
//  VoiceVisualizer.swift
//  MeetingAgent
//
//  Created by JAG on 1/27/26.
//

import SwiftUI

struct VoiceVisualizer: View {
    let amplitudes: [CGFloat]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<amplitudes.count, id: \.self) { index in
                Rectangle()
                    .fill(barColor(for: amplitudes[index]))
                    .frame(width: 8, height: max(4, 40 * amplitudes[index]))
                    .overlay(
                        Rectangle()
                            .stroke(NBDesign.border, lineWidth: NBDesign.thinBorder)
                    )
                    .animation(.linear(duration: 0.05), value: amplitudes[index])
            }
        }
        .frame(height: 44)
        .padding(.vertical, 4)
    }

    private func barColor(for amplitude: CGFloat) -> Color {
        if amplitude > 0.8 {
            return NBDesign.accent
        } else if amplitude > 0.5 {
            return NBDesign.foreground
        } else {
            return NBDesign.foreground.opacity(0.5)
        }
    }
}
