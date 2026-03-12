#if os(iOS)
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
                    // Transcript
                    Text(record.transcriptContent ?? "No transcript available")
                        .font(NBDesign.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                            Task { await vm.summarize(transcript: t) }
                        }
                        .buttonStyle(NBButtonStyle(color: NBDesign.foreground, textColor: NBDesign.background))
                        .disabled(vm.isSummarizing || record.transcriptContent == nil)

                        if let error = vm.error {
                            Text(error).font(NBDesign.captionFont).foregroundStyle(NBDesign.accent)
                        }
                        if let summary = vm.summaryResult {
                            Text(summary)
                                .font(NBDesign.bodyFont)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .nbCard()
                        }
                    }
                }
                .padding(NBDesign.padding)
            }
            .background(NBDesign.background)
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
#endif
