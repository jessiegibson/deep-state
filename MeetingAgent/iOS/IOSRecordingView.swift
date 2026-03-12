#if os(iOS)
import SwiftUI

struct IOSRecordingView: View {
    @ObservedObject var manager: IOSMeetingManager
    @State private var isNotesExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NBDesign.padding) {

                // Status
                statusCard

                // Voice visualizer
                if manager.isRecording {
                    VoiceVisualizer(amplitudes: manager.amplitudes)
                        .frame(height: 48)
                        .nbCard()
                }

                // Live transcript
                if manager.isRecording && !manager.liveTranscript.isEmpty {
                    ScrollView {
                        Text(manager.liveTranscript)
                            .font(NBDesign.bodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .nbCard()
                }

                // Notes panel
                if manager.isRecording && isNotesExpanded {
                    notesPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Controls
                controlButtons
            }
            .padding(NBDesign.padding)
        }
        .background(NBDesign.background)
    }

    // MARK: - Subviews

    private var statusCard: some View {
        HStack {
            if manager.isRecording {
                Circle()
                    .fill(manager.isPaused ? Color.secondary : NBDesign.accent)
                    .frame(width: 10, height: 10)
                Text(manager.isPaused ? "PAUSED" : "RECORDING")
                    .font(NBDesign.captionFont)
                    .foregroundStyle(manager.isPaused ? Color.secondary : NBDesign.accent)
            } else {
                Text(manager.statusMessage.uppercased())
                    .font(NBDesign.bodyFont)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .nbCard()
    }

    private var notesPanel: some View {
        VStack(spacing: 0) {
            TextField("Meeting title (optional)", text: $manager.meetingTitle)
                .font(NBDesign.bodyFont)
                .textFieldStyle(.plain)
                .padding(.horizontal, NBDesign.smallPadding)
                .padding(.vertical, 8)
                .background(NBDesign.surface)
                .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $manager.meetingNotes)
                    .font(NBDesign.bodyFont)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if manager.meetingNotes.isEmpty {
                    Text("Meeting notes...")
                        .font(NBDesign.bodyFont)
                        .foregroundStyle(.secondary.opacity(0.5))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 100)
            .background(NBDesign.background)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
        }
    }

    private var controlButtons: some View {
        HStack(spacing: NBDesign.smallPadding) {
            Spacer()

            if manager.isRecording {
                Button("NOTES") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isNotesExpanded.toggle()
                    }
                }
                .buttonStyle(NBButtonStyle(
                    color: isNotesExpanded ? NBDesign.foreground : NBDesign.surface,
                    textColor: isNotesExpanded ? NBDesign.background : NBDesign.foreground
                ))

                Button(manager.isPaused ? "RESUME" : "PAUSE") {
                    if manager.isPaused { manager.resumeRecording() }
                    else { manager.pauseRecording() }
                }
                .buttonStyle(NBButtonStyle(color: NBDesign.surface, textColor: NBDesign.foreground))

                Button("STOP & SAVE") {
                    Task { await manager.stopAndSave() }
                }
                .buttonStyle(NBButtonStyle(color: NBDesign.accent, textColor: NBDesign.background))
            } else {
                Button("START RECORDING") {
                    Task { await manager.startRecording() }
                }
                .buttonStyle(NBButtonStyle(color: NBDesign.foreground, textColor: NBDesign.background))
            }

            Spacer()
        }
    }
}
#endif
