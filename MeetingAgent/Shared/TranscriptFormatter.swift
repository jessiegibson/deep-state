import Foundation
import WhisperKit
import Speech

// MARK: - Transcript Formatter
// Groups transcription segments into readable paragraphs based on silence gaps.
// A new paragraph starts when the silence between segments exceeds gapThreshold.

struct TranscriptFormatter {

    // MARK: - WhisperKit segments
    // TranscriptionSegment has .start: Float and .end: Float (seconds)
    static func format(segments: [TranscriptionSegment], gapThreshold: Float = 2.0) -> String {
        guard !segments.isEmpty else { return "" }

        var paragraphs: [[TranscriptionSegment]] = []
        var current: [TranscriptionSegment] = [segments[0]]

        for i in 1..<segments.count {
            let gap = segments[i].start - segments[i - 1].end
            if gap > gapThreshold {
                paragraphs.append(current)
                current = []
            }
            current.append(segments[i])
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs
            .map { group in
                let text = group.map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return capitalizeFirst(text)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - SFTranscriptionSegment (live transcription path)
    // SFTranscriptionSegment has .timestamp: TimeInterval and .duration: TimeInterval
    static func format(sfSegments: [SFTranscriptionSegment], gapThreshold: TimeInterval = 2.0) -> String {
        guard !sfSegments.isEmpty else { return "" }

        var paragraphs: [[SFTranscriptionSegment]] = []
        var current: [SFTranscriptionSegment] = [sfSegments[0]]

        for i in 1..<sfSegments.count {
            let prevEnd = sfSegments[i - 1].timestamp + sfSegments[i - 1].duration
            let gap = sfSegments[i].timestamp - prevEnd
            if gap > gapThreshold {
                paragraphs.append(current)
                current = []
            }
            current.append(sfSegments[i])
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs
            .map { group in
                let text = group.map { $0.substring.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return capitalizeFirst(text)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Plain string fallback (for text with no segment metadata)
    // Splits on sentence-ending punctuation and groups into paragraphs every ~5 sentences.
    static func formatPlainText(_ text: String, sentencesPerParagraph: Int = 5) -> String {
        guard !text.isEmpty else { return text }

        // Try to split on sentence boundaries
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0 + "." }

        guard sentences.count > sentencesPerParagraph else {
            return capitalizeFirst(text.trimmingCharacters(in: .whitespaces))
        }

        var paragraphs: [String] = []
        var i = 0
        while i < sentences.count {
            let group = sentences[i..<min(i + sentencesPerParagraph, sentences.count)]
            paragraphs.append(group.joined(separator: " "))
            i += sentencesPerParagraph
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
