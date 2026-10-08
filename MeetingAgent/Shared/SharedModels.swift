import Foundation

// MARK: - MeetingRecord
// Shared between macOS and iOS targets.

struct MeetingRecord: Identifiable {
    let id = UUID()
    let folderURL: URL
    let folderName: String
    let title: String?
    let date: Date
    let hasAudio: Bool
    let hasVideo: Bool
    let transcriptContent: String?
    /// Number of files in the folder's `screenshots/` directory, 0 when there is none.
    let screenshotCount: Int

    /// Written out rather than synthesized so `screenshotCount` can default. A `let`
    /// with an inline default is dropped from the memberwise initializer entirely,
    /// which would break every existing call site.
    init(folderURL: URL,
         folderName: String,
         title: String?,
         date: Date,
         hasAudio: Bool,
         hasVideo: Bool,
         transcriptContent: String?,
         screenshotCount: Int = 0) {
        self.folderURL = folderURL
        self.folderName = folderName
        self.title = title
        self.date = date
        self.hasAudio = hasAudio
        self.hasVideo = hasVideo
        self.transcriptContent = transcriptContent
        self.screenshotCount = screenshotCount
    }

    var displayTitle: String { title ?? folderName }

    // MARK: - Screenshots

    var hasScreenshots: Bool { screenshotCount > 0 }

    var screenshotsFolderURL: URL { folderURL.appendingPathComponent("screenshots") }

    /// The machine-readable index other agents read. Present only once a recording has
    /// captured or extracted frames.
    var screenshotManifestURL: URL { folderURL.appendingPathComponent("screenshots.json") }

    /// Resolves the actual audio file on disk (m4a is the normal path; wav is the
    /// fallback used when the on-device m4a conversion fails — see StorageManager).
    var audioURL: URL? {
        guard hasAudio else { return nil }
        let m4a = folderURL.appendingPathComponent("audio.m4a")
        if FileManager.default.fileExists(atPath: m4a.path) { return m4a }
        let wav = folderURL.appendingPathComponent("audio.wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        return nil
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy  h:mm a"
        return formatter.string(from: date)
    }

    // MARK: - transcript.md sections
    // transcript.md is written by StorageManager as `---`-separated sections:
    // title/date, optional `## Meeting Notes`, `## Transcript`, and — once the
    // user runs a summary — an appended `## Summary (...)`. Views want the
    // sections individually so the copy buttons yield the spoken text rather
    // than the surrounding markdown scaffolding.

    var meetingNotes: String? { section(after: "## Meeting Notes") }

    var transcriptBody: String? { section(after: "## Transcript") }

    /// Transcript text for display and copying. Falls back to the whole file for
    /// records written before this layout, or by anything that skipped the header.
    var displayTranscript: String? { transcriptBody ?? transcriptContent }

    /// Returns the text between `marker` and the next `---` divider (or end of file).
    private func section(after marker: String) -> String? {
        guard let content = transcriptContent,
              let markerRange = content.range(of: marker) else { return nil }

        var body = content[markerRange.upperBound...]
        if let divider = body.range(of: "\n---\n") {
            body = body[body.startIndex..<divider.lowerBound]
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
