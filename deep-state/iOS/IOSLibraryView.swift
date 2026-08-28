import SwiftUI

struct IOSLibraryView: View {
    @ObservedObject var manager: IOSMeetingManager
    @State private var selectedRecord: MeetingRecord? = nil

    var body: some View {
        Group {
            if manager.meetingLibrary.isEmpty {
                VStack {
                    Spacer()
                    Text("NO RECORDINGS YET")
                        .font(NBDesign.bodyFont)
                        .foregroundStyle(.secondary)
                    Text("Recordings sync via iCloud Drive")
                        .font(NBDesign.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(manager.meetingLibrary) { record in
                        HStack {
                            Button {
                                selectedRecord = record
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.displayTitle)
                                        .font(NBDesign.bodyFont)
                                        .foregroundStyle(Color.primary)
                                    Text(record.formattedDate)
                                        .font(NBDesign.captionFont)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        if record.hasAudio { badge("AUDIO") }
                                        if record.hasVideo { badge("VIDEO") }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            if let audioURL = record.audioURL {
                                ShareLink(item: audioURL) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(NBDesign.foreground)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowBackground(NBDesign.background)
                    }
                }
                .listStyle(.plain)
                .background(NBDesign.background)
            }
        }
        .sheet(item: $selectedRecord) { record in
            IOSTranscriptView(record: record)
        }
        .onAppear { manager.loadLibrary() }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(NBDesign.captionFont)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
    }
}

// MARK: - iOS Transcript Detail View

struct IOSTranscriptView: View {
    let record: MeetingRecord
    @Environment(\.dismiss) var dismiss
    @StateObject private var vm = TranscriptSheetViewModel()

    var body: some View {
        NavigationView {
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

                    // Meeting notes (only written when the user took notes)
                    if let notes = record.meetingNotes {
                        VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                            NBSectionHeader(title: "MEETING NOTES", copyText: notes)
                            Text(notes)
                                .font(NBDesign.bodyFont)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Transcript
                    VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                        NBSectionHeader(title: "TRANSCRIPT", copyText: record.displayTranscript)
                        Text(record.displayTranscript ?? "No transcript available")
                            .font(NBDesign.bodyFont)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Summarize
                    VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
                        Text("SUMMARIZE")
                            .font(NBDesign.captionFont)
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                ForEach(SummaryTemplate.allCases) { template in
                                    Button(template.rawValue.uppercased()) {
                                        vm.selectedTemplate = template
                                    }
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(vm.selectedTemplate == template ? NBDesign.background : NBDesign.foreground)
                                    .background(vm.selectedTemplate == template ? NBDesign.foreground : NBDesign.surface)
                                    .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                                }
                            }
                        }

                        Button(vm.isSummarizing ? "SUMMARIZING..." : "RUN SUMMARY") {
                            guard let t = record.transcriptContent else { return }
                            Task { await vm.summarize(transcript: t, folderURL: record.folderURL) }
                        }
                        .buttonStyle(NBButtonStyle(color: NBDesign.foreground, textColor: NBDesign.background))
                        .disabled(vm.isSummarizing || record.transcriptContent == nil)

                        if let error = vm.error {
                            Text(error).font(NBDesign.captionFont).foregroundStyle(NBDesign.accent)
                        }
                        if let summary = vm.summaryResult {
                            VStack(alignment: .leading, spacing: 4) {
                                NBSectionHeader(
                                    title: "SUMMARY (\(vm.selectedTemplate.rawValue.uppercased()))",
                                    copyText: summary
                                )
                                Text(summary)
                                    .font(NBDesign.bodyFont)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .nbCard()
                        }
                    }
                }
                .padding(NBDesign.padding)
            }
            .background(NBDesign.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { VersionFooter() }
            .navigationTitle(record.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
