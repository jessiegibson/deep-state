#if os(macOS)
import SwiftUI
import Combine
import EventKit

enum AppView { case record, library }

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var manager: MeetingManager
    @State private var activeView: AppView = .record
    @State private var isSettingsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: NBDesign.smallPadding) {
                Image("deepStateRobot01")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                Text("deep state Meeting Agent")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(NBDesign.background)
                Spacer()
                HStack(spacing: 0) {
                    tabButton("RECORD", tab: .record)
                    tabButton("LIBRARY", tab: .library)
                }
                Button {
                    isSettingsOpen = true
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(NBDesign.background)
                }
                .buttonStyle(.plain)
                .padding(8)
                .overlay(Rectangle().stroke(NBDesign.background.opacity(0.3), lineWidth: NBDesign.thinBorder))
                .padding(.leading, 8)
            }
            .padding(NBDesign.padding)
            .background(NBDesign.foreground)
            .sheet(isPresented: $isSettingsOpen) {
                LLMSettingsView(settings: manager.llmSettings)
            }

            switch activeView {
            case .record:
                RecordingView(manager: manager)
            case .library:
                LibraryView(manager: manager)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(NBDesign.background)
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
    @StateObject private var calendar = CalendarManager.shared
    @State private var isStorageSettingsOpen = false

    private var saveLocationLabel: String {
        let storage = StorageManager.shared
        if storage.storageMode == .iCloud {
            return "iCloud / \(storage.iCloudSubfolder)"
        }
        return storage.localBookmarkURL?.lastPathComponent ?? "No Folder Selected"
    }

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
            .disabled(manager.isRecording || manager.isImporting)
            .opacity(manager.isRecording || manager.isImporting ? 0.5 : 1.0)
            .task(id: manager.recordingMode) {
                if manager.recordingMode == .screenAndAudio {
                    await manager.refreshAvailableDisplays()
                }
            }

            // Screen Picker (only shown when there's an actual choice to make)
            if manager.recordingMode == .screenAndAudio && manager.availableDisplays.count > 1 {
                VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                    Text("SCREEN")
                        .font(NBDesign.captionFont)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 0) {
                        ForEach(manager.availableDisplays) { option in
                            Button(option.label) {
                                manager.selectedDisplayID = option.id
                            }
                            .font(NBDesign.captionFont)
                            .foregroundStyle(
                                manager.selectedDisplayID == option.id
                                    ? NBDesign.background
                                    : NBDesign.foreground
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                manager.selectedDisplayID == option.id
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
                .disabled(manager.isRecording || manager.isImporting)
                .opacity(manager.isRecording || manager.isImporting ? 0.5 : 1.0)
            }

            // Save Location
            VStack(alignment: .leading, spacing: 4) {
                Text("SAVE TO")
                    .font(NBDesign.captionFont)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: manager.storage.storageMode == .iCloud ? "icloud.fill" : "folder.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text(saveLocationLabel)
                        .font(NBDesign.bodyFont)
                        .lineLimit(1)
                    Spacer()
                    Button("CHANGE") {
                        isStorageSettingsOpen = true
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
            .sheet(isPresented: $isStorageSettingsOpen) {
                StorageSettingsView()
            }

            // Upcoming Calendar Events (hidden while recording or when not authorized)
            if !manager.isRecording && !manager.isImporting && calendar.authorizationStatus == .granted && !calendar.todayEvents.isEmpty {
                upcomingEventsPanel
            }

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

                    VoiceVisualizer(amplitudes: manager.amplitudes)
                }
                .transition(.opacity)
            } else if manager.isImporting {
                VStack(spacing: NBDesign.smallPadding) {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text(manager.importProgress.uppercased())
                        .font(NBDesign.bodyFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
                .frame(minHeight: 60)
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

            // Inline Notes Panel
            if manager.isRecording && manager.isNotesSheetOpen {
                inlineNotesPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Auto-start countdown banner
            if let countdown = calendar.autoStartCountdown, !manager.isRecording {
                HStack {
                    Text("AUTO-STARTING IN \(countdown)s")
                        .font(NBDesign.captionFont)
                        .foregroundStyle(NBDesign.background)
                    Spacer()
                    Button("CANCEL") {
                        calendar.disarmAutoStart()
                    }
                    .font(NBDesign.captionFont)
                    .foregroundStyle(NBDesign.background)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(NBDesign.background, lineWidth: NBDesign.thinBorder))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, NBDesign.padding)
                .padding(.vertical, NBDesign.smallPadding)
                .background(NBDesign.accent)
            }

            // Record Buttons
            HStack {
                Spacer()
                if manager.isRecording {
                    Button("NOTES") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            manager.isNotesSheetOpen.toggle()
                        }
                    }
                    .buttonStyle(NBButtonStyle(
                        color: manager.isNotesSheetOpen ? NBDesign.foreground : NBDesign.surface,
                        textColor: manager.isNotesSheetOpen ? NBDesign.background : NBDesign.foreground
                    ))

                    Button(manager.isPaused ? "RESUME" : "PAUSE") {
                        Task {
                            if manager.isPaused {
                                await manager.resumeRecording()
                            } else {
                                await manager.pauseRecording()
                            }
                        }
                    }
                    .buttonStyle(NBButtonStyle(color: NBDesign.surface, textColor: NBDesign.foreground))

                    Button("STOP & SAVE") {
                        Task {
                            await manager.stopAndTranscribe()
                        }
                    }
                    .buttonStyle(NBButtonStyle(color: NBDesign.accent, textColor: NBDesign.background))
                } else {
                    Button("IMPORT") {
                        Task { await manager.importFiles() }
                    }
                    .buttonStyle(NBButtonStyle(color: NBDesign.surface, textColor: NBDesign.foreground))
                    .disabled(manager.isImporting || manager.savedFolderURL == nil)

                    Button("START RECORDING") {
                        Task {
                            await manager.start()
                        }
                    }
                    .buttonStyle(NBButtonStyle(color: NBDesign.foreground, textColor: NBDesign.background))
                    .disabled(manager.isImporting)
                }
                Spacer()
            }
        }
        .padding(NBDesign.padding)
        .onChange(of: calendar.shouldAutoStart) { _, firing in
            guard firing, !manager.isRecording else { return }
            calendar.shouldAutoStart = false
            Task {
                await manager.start()
            }
        }
    }

    // MARK: - Upcoming Events Panel

    private var upcomingEventsPanel: some View {
        VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
            Text("UPCOMING MEETINGS")
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(calendar.todayEvents, id: \.eventIdentifier) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: EKEvent) -> some View {
        let isSelected = calendar.selectedEvent?.eventIdentifier == event.eventIdentifier
        let isArmed = calendar.armedEventID == event.eventIdentifier

        return HStack(spacing: NBDesign.smallPadding) {
            // Calendar color dot
            Circle()
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 8, height: 8)

            // Title + time
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Untitled")
                    .font(NBDesign.bodyFont)
                    .lineLimit(1)
                Text(formatEventTime(event))
                    .font(NBDesign.captionFont)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Auto-start toggle
            Button(isArmed ? "ARMED" : "AUTO-START") {
                if isArmed {
                    calendar.disarmAutoStart()
                } else {
                    calendar.armAutoStart(eventID: event.eventIdentifier)
                }
            }
            .font(NBDesign.captionFont)
            .foregroundStyle(isArmed ? NBDesign.background : NBDesign.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isArmed ? NBDesign.foreground : NBDesign.surface)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NBDesign.smallPadding)
        .padding(.vertical, 6)
        .background(isSelected ? NBDesign.surface : NBDesign.background)
        .overlay(Rectangle().stroke(isSelected ? NBDesign.foreground : NBDesign.border, lineWidth: isSelected ? 2 : NBDesign.thinBorder))
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                calendar.selectedEvent = nil
                manager.meetingTitle = ""
            } else {
                calendar.selectedEvent = event
                manager.meetingTitle = event.title ?? ""
            }
        }
    }

    private func formatEventTime(_ event: EKEvent) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return fmt.string(from: event.startDate)
    }

    // MARK: - Notes Panel

    private var inlineNotesPanel: some View {
        VStack(spacing: 0) {
            TextField("Meeting title (optional)", text: $manager.meetingTitle)
                .font(NBDesign.bodyFont)
                .textFieldStyle(.plain)
                .padding(.horizontal, NBDesign.smallPadding)
                .padding(.vertical, 6)
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
            .frame(height: 72)
            .background(NBDesign.background)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
        }
    }
}

// MARK: - Library View

struct LibraryView: View {
    @ObservedObject var manager: MeetingManager
    @State private var selectedRecord: MeetingRecord? = nil
    @State private var isSelectionMode = false
    @State private var selectedFolderURLs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Library toolbar
            HStack {
                if isSelectionMode {
                    Text("\(selectedFolderURLs.count) SELECTED")
                        .font(NBDesign.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !selectedFolderURLs.isEmpty {
                        Button(manager.isRetranscribing ? "RETRANSCRIBING..." : "RETRANSCRIBE SELECTED") {
                            let records = manager.meetingLibrary.filter {
                                selectedFolderURLs.contains($0.folderURL.path)
                            }
                            Task { await manager.retranscribeBatch(records: records) }
                        }
                        .font(NBDesign.captionFont)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(NBDesign.background)
                        .background(NBDesign.foreground)
                        .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                        .buttonStyle(.plain)
                        .disabled(manager.isRetranscribing)
                    }
                    Button("DONE") {
                        isSelectionMode = false
                        selectedFolderURLs = []
                    }
                    .font(NBDesign.captionFont)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                    if !manager.meetingLibrary.isEmpty {
                        Button("SELECT") {
                            isSelectionMode = true
                        }
                        .font(NBDesign.captionFont)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, NBDesign.padding)
            .padding(.vertical, NBDesign.smallPadding)

            // Retranscribe progress bar
            if manager.isRetranscribing {
                HStack(spacing: NBDesign.smallPadding) {
                    ProgressView()
                        .controlSize(.small)
                    Text(manager.retranscribeProgress.uppercased())
                        .font(NBDesign.captionFont)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, NBDesign.padding)
                .padding(.bottom, NBDesign.smallPadding)
            }

            Rectangle()
                .fill(NBDesign.border)
                .frame(height: NBDesign.thinBorder)

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
                            HStack(spacing: 0) {
                                if isSelectionMode {
                                    Button {
                                        let path = record.folderURL.path
                                        if selectedFolderURLs.contains(path) {
                                            selectedFolderURLs.remove(path)
                                        } else {
                                            selectedFolderURLs.insert(path)
                                        }
                                    } label: {
                                        Image(systemName: selectedFolderURLs.contains(record.folderURL.path)
                                              ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(NBDesign.foreground)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.leading, NBDesign.padding)
                                }

                                MeetingRecordRow(
                                    record: record,
                                    isRetranscribing: manager.isRetranscribing,
                                    onViewTranscript: { selectedRecord = record },
                                    onOpen: { manager.openInFinder(record.folderURL) },
                                    onRetranscribe: {
                                        Task { await manager.retranscribe(record: record) }
                                    }
                                )
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
            TranscriptSheetView(record: record, savedFolderURL: manager.savedFolderURL) {
                Task { await manager.retranscribe(record: record) }
            }
        }
    }
}

// MARK: - Meeting Record Row

struct MeetingRecordRow: View {
    let record: MeetingRecord
    let isRetranscribing: Bool
    let onViewTranscript: () -> Void
    let onOpen: () -> Void
    let onRetranscribe: () -> Void

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
                HStack(spacing: 6) {
                    Button(isRetranscribing ? "..." : "RETRANSCRIBE") { onRetranscribe() }
                        .font(NBDesign.captionFont)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                        .buttonStyle(.plain)
                        .disabled(isRetranscribing || !record.hasAudio)
                    Button("OPEN") { onOpen() }
                        .font(NBDesign.captionFont)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                        .buttonStyle(.plain)
                    if let audioURL = record.audioURL {
                        ShareLink(item: audioURL) {
                            Text("SHARE")
                                .font(NBDesign.captionFont)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                        }
                        .buttonStyle(.plain)
                    }
                }
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
    let savedFolderURL: URL?
    let onRetranscribe: (() -> Void)?
    @Environment(\.dismiss) var dismiss
    @StateObject private var vm = TranscriptSheetViewModel()

    init(record: MeetingRecord, savedFolderURL: URL? = nil, onRetranscribe: (() -> Void)? = nil) {
        self.record = record
        self.savedFolderURL = savedFolderURL
        self.onRetranscribe = onRetranscribe
    }

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
                if let onRetranscribe = onRetranscribe, record.hasAudio {
                    Button("RETRANSCRIBE") {
                        onRetranscribe()
                        dismiss()
                    }
                    .buttonStyle(NBButtonStyle(color: NBDesign.surface, textColor: NBDesign.foreground))
                }
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
                VStack(alignment: .leading, spacing: NBDesign.padding) {
                    // Audio file
                    if let audioURL = record.audioURL {
                        HStack {
                            Image(systemName: "waveform")
                                .font(.system(size: 16, weight: .bold))
                            Text(audioURL.lastPathComponent)
                                .font(NBDesign.bodyFont)
                                .lineLimit(1)
                            Spacer()
                            ShareLink(item: audioURL) {
                                Text("SHARE")
                                    .font(NBDesign.captionFont)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                            }
                            .buttonStyle(.plain)
                        }
                        .nbCard()
                    }

                    // Transcript content
                    Text(record.transcriptContent ?? "No transcript available")
                        .font(NBDesign.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Summarize section
                    VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                        Text("SUMMARIZE")
                            .font(NBDesign.captionFont)
                            .foregroundStyle(.secondary)

                        // Template picker
                        HStack(spacing: 0) {
                            ForEach(SummaryTemplate.allCases) { template in
                                Button(template.rawValue.uppercased()) {
                                    vm.selectedTemplate = template
                                }
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                                .foregroundStyle(vm.selectedTemplate == template ? NBDesign.background : NBDesign.foreground)
                                .background(vm.selectedTemplate == template ? NBDesign.foreground : NBDesign.surface)
                                .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                            }
                        }

                        HStack {
                            Button(vm.isSummarizing ? "SUMMARIZING..." : "RUN SUMMARY") {
                                guard let transcript = record.transcriptContent else { return }
                                Task {
                                    await vm.summarize(
                                        transcript: transcript,
                                        folderURL: record.folderURL,
                                        savedFolderURL: savedFolderURL
                                    )
                                }
                            }
                            .buttonStyle(NBButtonStyle(color: NBDesign.foreground, textColor: NBDesign.background))
                            .disabled(vm.isSummarizing || record.transcriptContent == nil)
                        }

                        if let error = vm.error {
                            Text(error)
                                .font(NBDesign.captionFont)
                                .foregroundStyle(NBDesign.accent)
                                .nbCard()
                        }

                        if let summary = vm.summaryResult {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("SUMMARY (\(vm.selectedTemplate.rawValue.uppercased()))")
                                    .font(NBDesign.captionFont)
                                    .foregroundStyle(.secondary)
                                Text(summary)
                                    .font(NBDesign.bodyFont)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .nbCard()
                        }
                    }
                }
                .padding(NBDesign.padding)
            }
            .background(NBDesign.background)
        }
        .frame(width: 640, height: 600)
        .background(NBDesign.background)
    }
}
#endif
