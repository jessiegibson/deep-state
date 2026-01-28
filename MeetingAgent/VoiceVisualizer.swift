//
//  VoiceVisualizer.swift
//  MeetingAgent
//
//  Created by JAG on 1/27/26.
//

struct VoiceVisualizer: View {
    let amplitudes: [CGFloat]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<amplitudes.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 10)
                    // Dynamic color based on volume (Green to Red)
                    .foregroundStyle(barColor(for: amplitudes[index]))
                    .frame(width: 4, height: 20 * amplitudes[index])
                    // The "Glow" effect
                    .shadow(color: barColor(for: amplitudes[index]).opacity(0.6),
                            radius: amplitudes[index] > 0.7 ? 8 : 3)
                    .animation(.spring(response: 0.2, dampingFraction: 0.5), value: amplitudes[index])
            }
        }
        .frame(height: 40)
    }

    // Logic to change color if the user gets too loud
    private func barColor(for amplitude: CGFloat) -> Color {
        if amplitude > 0.8 {
            return .red    // High volume "Glow"
        } else if amplitude > 0.5 {
            return .orange // Medium volume
        } else {
            return .green  // Normal volume
        }
    }
}
