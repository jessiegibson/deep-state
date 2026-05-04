#if os(macOS)
import SwiftUI
import AVFoundation

struct SpeakerLabelingView: View {
    @ObservedObject var manager: MeetingManager
    @State private var editedSegments: [SpeakerSegment]
    @State private var activePlayerID: UUID? = nil
    @State private var player: AVAudioPlayer? = nil
    @State private var nameInputs: [UUID: String] = [:]

    init(manager: MeetingManager) {
        self.manager = manager
        _editedSegments = State(initialValue: manager.speakerSegments)
    }

    // Unique clusters detected
    private var clusterCount: Int {
        Set(editedSegments.map(\.clusterID)).count
    }

    // Name suggestions from voice print store + already-entered names
    private var nameSuggestions: [String] {
        let stored = VoicePrintStore.shared.knownNames
        let entered = nameInputs.values.filter { !$0.isEmpty }
        return Array(Set(stored + entered)).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            subheader
            segmentList
            footer
        }
        .frame(width: 560, height: 520)
        .background(NBDesign.background)
        .onAppear {
            // Seed name inputs from any pre-matched voice prints
            for seg in editedSegments {
                nameInputs[seg.id] = seg.speakerName ?? ""
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("IDENTIFY SPEAKERS")
                .font(NBDesign.headlineFont)
                .foregroundStyle(NBDesign.background)
            Spacer()
            Button {
                stopPlayback()
                manager.cancelSpeakerLabeling()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NBDesign.background)
            }
            .buttonStyle(.plain)
            .padding(8)
            .overlay(Rectangle().stroke(NBDesign.background, lineWidth: NBDesign.thinBorder))
        }
        .padding(NBDesign.padding)
        .background(NBDesign.foreground)
    }

    // MARK: - Subheader

    private var subheader: some View {
        HStack {
            Text("\(clusterCount) SPEAKER\(clusterCount == 1 ? "" : "S") DETECTED · NAME EACH GROUP")
                .font(NBDesign.captionFont)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, NBDesign.padding)
        .padding(.vertical, NBDesign.smallPadding)
        .background(NBDesign.surface)
        .overlay(
            Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder),
            alignment: .bottom
        )
    }

    // MARK: - Segment List

    private var segmentList: some View {
        ScrollView {
            VStack(spacing: NBDesign.smallPadding) {
                // Group by cluster so same-speaker segments are visually linked
                ForEach(sortedClusters, id: \.self) { clusterID in
                    let clusterSegments = editedSegments.filter { $0.clusterID == clusterID }
                    clusterCard(clusterID: clusterID, segments: clusterSegments)
                }
            }
            .padding(NBDesign.padding)
        }
        .frame(maxHeight: .infinity)
    }

    private var sortedClusters: [Int] {
        Array(Set(editedSegments.map(\.clusterID))).sorted()
    }

    // MARK: - Cluster Card

    private func clusterCard(clusterID: Int, segments: [SpeakerSegment]) -> some View {
        // Use the ID of the first segment as the name binding key for this cluster
        let keySegment = segments[0]
        let binding = Binding<String>(
            get: { nameInputs[keySegment.id] ?? "" },
            set: { newVal in
                // Apply the name to ALL segments in this cluster
                for seg in segments {
                    nameInputs[seg.id] = newVal
                    if let idx = editedSegments.firstIndex(where: { $0.id == seg.id }) {
                        editedSegments[idx].speakerName = newVal.isEmpty ? nil : newVal
                    }
                }
            }
        )

        let totalText = segments.map(\.text).joined(separator: " ")
        let previewText = String(totalText.prefix(120)) + (totalText.count > 120 ? "…" : "")
        let timeRange = formatTimeRange(start: segments.first?.startTime ?? 0, end: segments.last?.endTime ?? 0)
        let suggestedName = segments.first.flatMap { VoicePrintStore.shared.match($0.features) }?.name

        return VStack(alignment: .leading, spacing: NBDesign.smallPadding) {
            HStack {
                // Cluster color indicator
                Rectangle()
                    .fill(clusterColor(clusterID))
                    .frame(width: 6)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("SPEAKER \(clusterID + 1)")
                            .font(NBDesign.captionFont)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timeRange)
                            .font(NBDesign.captionFont)
                            .foregroundStyle(.secondary)
                        Text("\(segments.count) SEGMENT\(segments.count == 1 ? "" : "S")")
                            .font(NBDesign.captionFont)
                            .foregroundStyle(.secondary)
                    }

                    // Name input row
                    HStack(spacing: NBDesign.smallPadding) {
                        TextField(suggestedName.map { "Suggested: \($0)" } ?? "Enter name…", text: binding)
                            .font(NBDesign.bodyFont)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(NBDesign.background)
                            .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))

                        // Suggestion pills
                        if !nameSuggestions.isEmpty {
                            Menu {
                                ForEach(nameSuggestions, id: \.self) { name in
                                    Button(name) { binding.wrappedValue = name }
                                }
                            } label: {
                                Text("▾")
                                    .font(NBDesign.buttonFont)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(NBDesign.surface)
                                    .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Transcript preview
                    if !previewText.isEmpty {
                        Text("\"\(previewText)\"")
                            .font(NBDesign.captionFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .nbCard()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("SKIP") {
                stopPlayback()
                manager.cancelSpeakerLabeling()
            }
            .buttonStyle(NBButtonStyle(color: NBDesign.surface, textColor: NBDesign.foreground))

            Spacer()

            let namedCount = Set(nameInputs.values.filter { !$0.isEmpty }).count
            let total = clusterCount

            Button("SAVE (\(namedCount)/\(total) NAMED)") {
                stopPlayback()
                applyLabelsAndSave()
            }
            .buttonStyle(NBButtonStyle(color: NBDesign.foreground, textColor: NBDesign.background))
        }
        .padding(NBDesign.padding)
        .overlay(Rectangle().stroke(NBDesign.border, lineWidth: NBDesign.thinBorder), alignment: .top)
    }

    // MARK: - Helpers

    private func applyLabelsAndSave() {
        let finalSegments = editedSegments.map { seg -> SpeakerSegment in
            var s = seg
            let name = nameInputs[seg.id] ?? ""
            s.speakerName = name.isEmpty ? nil : name
            return s
        }
        manager.finalizeWithSpeakerLabels(finalSegments)
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        activePlayerID = nil
    }

    private func formatTimeRange(start: TimeInterval, end: TimeInterval) -> String {
        let fmt = { (t: TimeInterval) -> String in
            let m = Int(t) / 60
            let s = Int(t) % 60
            return String(format: "%d:%02d", m, s)
        }
        return "\(fmt(start))–\(fmt(end))"
    }

    private func clusterColor(_ id: Int) -> Color {
        let colors: [Color] = [
            NBDesign.foreground,
            NBDesign.accent,
            NBDesign.secondaryAccent,
            .orange,
            .purple
        ]
        return colors[id % colors.count]
    }
}
#endif
