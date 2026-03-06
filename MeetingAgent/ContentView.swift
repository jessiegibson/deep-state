import SwiftUI

struct ContentView: View {
    @StateObject var manager = MeetingManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("deep state Meeting Agent")
                Spacer()
            }
            .padding(NBDesign.padding)
            .background(NBDesign.foreground)

            VStack(alignment: .leading, spacing: NBDesign.padding) {

                // Recording Mode Picker
                VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                    Text("MODE")
                        .font(NBDesign.captionFont)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 0) {
                        ForEach(RecordingMode.allCases, id: \.self) { mode in
                            Button(mode.rawValue.uppercased()) {
                                manager.recordingMode = mode
                            }
                            .font(NBDesign.captionFont)
                            .foregroundStyle(
                                manager.recordingMode == mode
                                    ? NBDesign.background
                                    : NBDesign.foreground
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                manager.recordingMode == mode
                                    ? NBDesign.foreground
                                    : NBDesign.surface
                            )
                            .overlay(
                                Rectangle()
                                    .stroke(NBDesign.border, lineWidth: NBDesign.thinBorder)
                            )
                        }
                    }
                }
                .disabled(manager.isRecording)
                .opacity(manager.isRecording ? 0.5 : 1.0)

                // Save Location
                VStack(alignment: .leading, spacing: 4) {
                    Text("SAVE TO")
                        .font(NBDesign.captionFont)
                        .foregroundStyle(.secondary)

                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text(manager.savedFolderURL?.lastPathComponent ?? "No Folder Selected")
                            .font(NBDesign.bodyFont)
                            .lineLimit(1)
                        Spacer()
                        Button("CHANGE") {
                            manager.selectFolder()
                        }
                        .font(NBDesign.captionFont)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay(
                            Rectangle()
                                .stroke(NBDesign.border, lineWidth: NBDesign.thinBorder)
                        )
                    }
                }
                .nbCard()

                // Divider
                Rectangle()
                    .fill(NBDesign.border)
                    .frame(height: NBDesign.thinBorder)

                // Status / Recording Area
                if manager.isRecording {
                    VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                        HStack {
                            Circle()
                                .fill(manager.isPaused ? Color.secondary : NBDesign.accent)
                                .frame(width: 10, height: 10)
                            Text(manager.isPaused ? "PAUSED" : "RECORDING")
                                .font(NBDesign.captionFont)
                                .foregroundStyle(manager.isPaused ? Color.secondary : NBDesign.accent)
                        }

                        // Live transcript (audio-only mode)
                        if manager.recordingMode == .audioOnly && !manager.liveTranscript.isEmpty {
                            ScrollView {
                                Text(manager.liveTranscript)
                                    .font(NBDesign.bodyFont)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 100)
                            .nbCard()
                        }

                        VoiceVisualizer(amplitudes: manager.amplitudes)
                    }
                    .transition(.opacity)
                } else {
                    VStack {
                        Spacer()
                        Text(manager.statusMessage.uppercased())
                            .font(NBDesign.bodyFont)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    }
                    .frame(minHeight: 60)
                }

                // Record Buttons
                HStack {
                    Spacer()
                    if manager.isRecording {
                        Button(manager.isPaused ? "RESUME" : "PAUSE") {
                            Task {
                                if manager.isPaused {
                                    await manager.resumeRecording()
                                    if manager.recordingMode == .screenAndAudio {
                                        manager.startMonitoring()
                                    }
                                } else {
                                    await manager.pauseRecording()
                                    if manager.recordingMode == .screenAndAudio {
                                        manager.stopMonitoring()
                                    }
                                }
                            }
                        }
                        .buttonStyle(NBButtonStyle(color: NBDesign.surface, textColor: NBDesign.foreground))

                        Button("STOP & SAVE") {
                            Task {
                                await manager.stopAndTranscribe()
                                if manager.recordingMode == .screenAndAudio {
                                    manager.stopMonitoring()
                                }
                            }
                        }
                        .buttonStyle(NBButtonStyle(color: NBDesign.accent, textColor: NBDesign.background))
                    } else {
                        Button("START RECORDING") {
                            Task {
                                await manager.start()
                                if manager.recordingMode == .screenAndAudio {
                                    manager.startMonitoring()
                                }
                            }
                        }
                        .buttonStyle(NBButtonStyle(color: NBDesign.foreground, textColor: NBDesign.background))
                    }
                    Spacer()
                }
            }
            .padding(NBDesign.padding)
        }
        .frame(width: 640, height: 480)
        .background(NBDesign.background)
        .sheet(isPresented: $manager.isNotesSheetOpen) {
            MeetingNotesSheet(notes: $manager.meetingNotes, manager: manager)
        }
    }
}

struct MeetingNotesSheet: View {
    @Binding var notes: String
    @ObservedObject var manager: MeetingManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("MEETING NOTES")
                    .font(NBDesign.headlineFont)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(manager.isPaused ? Color.secondary : NBDesign.accent)
                        .frame(width: 8, height: 8)
                    Text(manager.isPaused ? "PAUSED" : "REC")
                        .font(NBDesign.captionFont)
                        .foregroundStyle(manager.isPaused ? Color.secondary : NBDesign.accent)
                }
                .opacity(manager.isRecording ? 1 : 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .padding(8)
                .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
            }
            .padding(NBDesign.padding)
            .background(NBDesign.foreground)

            // Notes editor
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .font(NBDesign.bodyFont)
                    .scrollContentBackground(.hidden)
                    .padding(NBDesign.padding)

                if notes.isEmpty {
                    Text("Take notes during your meeting...\nThese will be added to the top of the transcript.")
                        .font(NBDesign.bodyFont)
                        .foregroundStyle(.secondary.opacity(0.5))
                        .padding(NBDesign.padding + 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NBDesign.background)
        }
        .frame(width: 520, height: 380)
        .background(NBDesign.background)
    }
}
