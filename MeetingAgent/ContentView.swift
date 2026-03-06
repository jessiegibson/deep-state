import SwiftUI

enum AppView { case record, library }

// MARK: - Content View

struct ContentView: View {
    @StateObject var manager = MeetingManager()
    @State private var activeView: AppView = .record

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("deep state Meeting Agent")
                Spacer()
                HStack(spacing: 0) {
                    tabButton("RECORD", tab: .record)
                    tabButton("LIBRARY", tab: .library)
                }
            }
            .padding(NBDesign.padding)
            .background(NBDesign.foreground)

            switch activeView {
            case .record:
                RecordingView(manager: manager)
            case .library:
                LibraryView(manager: manager)
            }
        }
        .frame(width: 640, height: 480)
        .background(NBDesign.background)
        .sheet(isPresented: $manager.isNotesSheetOpen) {
            MeetingNotesSheet(notes: $manager.meetingNotes, title: $manager.meetingTitle, manager: manager)
        }
    }

    @ViewBuilder
    private func tabButton(_ label: String, tab: AppView) -> some View {
        Button(label) {
            if tab == .library { manager.loadLibrary() }
            activeView = tab
        }
        .font(NBDesign.captionFont)
        .foregroundStyle(activeView == tab ? Color.primary : Color.primary.opacity(0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(activeView == tab ? NBDesign.background : Color.clear)
        .overlay(
            Rectangle()
                .stroke(NBDesign.border, lineWidth: activeView == tab ? NBDesign.thinBorder : 0)
        )
        .buttonStyle(.plain)
    }
}

// MARK: - Recording View

struct RecordingView: View {
    @ObservedObject var manager: MeetingManager

    var body: some View {
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
}

// MARK: - Library View

struct LibraryView: View {
    @ObservedObject var manager: MeetingManager
    @State private var selectedRecord: MeetingRecord? = nil

    var body: some View {
        Group {
            if manager.meetingLibrary.isEmpty {
                VStack {
                    Spacer()
                    Text("NO RECORDINGS YET")
                        .font(NBDesign.bodyFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.meetingLibrary) { record in
                            MeetingRecordRow(record: record) {
                                selectedRecord = record
                            } onOpen: {
                                manager.openInFinder(record.folderURL)
                            }
                            Rectangle()
                                .fill(NBDesign.border)
                                .frame(height: NBDesign.thinBorder)
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedRecord) { record in
            TranscriptSheetView(record: record)
        }
    }
}

// MARK: - Meeting Record Row

struct MeetingRecordRow: View {
    let record: MeetingRecord
    let onViewTranscript: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NBDesign.padding) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayTitle)
                    .font(NBDesign.bodyFont)
                Text(record.formattedDate)
                    .font(NBDesign.captionFont)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if record.hasAudio { badge("AUDIO") }
                    if record.hasVideo { badge("VIDEO") }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("VIEW") { onViewTranscript() }
                    .buttonStyle(NBButtonStyle(color: NBDesign.foreground, textColor: NBDesign.background))
                Button("OPEN") { onOpen() }
                    .font(NBDesign.captionFont)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                    .buttonStyle(.plain)
            }
        }
        .padding(NBDesign.padding)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(NBDesign.captionFont)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
    }
}

// MARK: - Transcript Sheet

struct TranscriptSheetView: View {
    let record: MeetingRecord
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayTitle)
                        .font(NBDesign.headlineFont)
                    Text(record.formattedDate)
                        .font(NBDesign.captionFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
            .background(NBDesign.surface)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))

            ScrollView {
                Text(record.transcriptContent ?? "No transcript available")
                    .font(NBDesign.bodyFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(NBDesign.padding)
            }
            .background(NBDesign.background)
        }
        .frame(width: 600, height: 500)
        .background(NBDesign.background)
    }
}

// MARK: - Meeting Notes Sheet

struct MeetingNotesSheet: View {
    @Binding var notes: String
    @Binding var title: String
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

            // Title field
            TextField("Meeting title (optional)", text: $title)
                .font(NBDesign.bodyFont)
                .textFieldStyle(.plain)
                .padding(NBDesign.padding)
                .background(NBDesign.surface)
                .overlay(
                    Rectangle()
                        .stroke(NBDesign.border, lineWidth: NBDesign.thinBorder)
                )

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
        .frame(width: 520, height: 400)
        .background(NBDesign.background)
    }
}
