import XCTest
@testable import Deep_State_Meeting_Agent_MacOS

/// Covers the transcript.md section parsing that backs the transcript/notes/summary
/// panes and their copy buttons. The layout under test is the one StorageManager
/// writes, plus the `## Summary` block TranscriptViewModel appends afterwards.
final class MeetingRecordSectionTests: XCTestCase {

    private func record(_ content: String?) -> MeetingRecord {
        MeetingRecord(
            folderURL: URL(fileURLWithPath: "/tmp/2026-03-08 14-30-00"),
            folderName: "2026-03-08 14-30-00",
            title: nil,
            date: Date(timeIntervalSince1970: 0),
            hasAudio: false,
            hasVideo: false,
            transcriptContent: content
        )
    }

    private let full = """
    # Q3 Planning
    2026-03-08 14:30:00

    ---

    ## Meeting Notes

    Discuss headcount.
    Budget too.

    ---

    ## Transcript

    **Sarah:** The numbers look strong.

    **Alex:** Agreed.
    """

    func testParsesNotesAndTranscript() {
        let r = record(full)
        XCTAssertEqual(r.meetingNotes, "Discuss headcount.\nBudget too.")
        XCTAssertEqual(r.transcriptBody, "**Sarah:** The numbers look strong.\n\n**Alex:** Agreed.")
    }

    /// The summary is appended to the same file, so the transcript section must
    /// stop at the divider rather than swallowing it.
    func testAppendedSummaryDoesNotLeakIntoTranscript() {
        let r = record(full + "\n\n---\n\n## Summary (general)\n\nTeam aligned on budget.")
        XCTAssertEqual(r.transcriptBody, "**Sarah:** The numbers look strong.\n\n**Alex:** Agreed.")
    }

    func testMissingNotesSectionIsNil() {
        let r = record("2026-03-08 14:30:00\n\n---\n\n## Transcript\n\nJust talking.")
        XCTAssertNil(r.meetingNotes)
        XCTAssertEqual(r.transcriptBody, "Just talking.")
    }

    /// Records written before this layout have no headers at all — the transcript
    /// pane falls back to the whole file rather than showing nothing.
    func testLegacyFileFallsBackToWholeContent() {
        let r = record("Some old transcript with no headers at all.")
        XCTAssertNil(r.transcriptBody)
        XCTAssertEqual(r.displayTranscript, "Some old transcript with no headers at all.")
    }

    func testEmptySectionIsNilRatherThanBlank() {
        let r = record("# T\n2026-03-08 14:30:00\n\n---\n\n## Transcript\n\n")
        XCTAssertNil(r.transcriptBody)
    }

    func testNilContentYieldsNilSections() {
        let r = record(nil)
        XCTAssertNil(r.meetingNotes)
        XCTAssertNil(r.transcriptBody)
        XCTAssertNil(r.displayTranscript)
    }

    func testDisplayTranscriptPrefersBodyOverWholeFile() {
        let r = record(full)
        XCTAssertEqual(r.displayTranscript, r.transcriptBody)
        XCTAssertNotEqual(r.displayTranscript, r.transcriptContent)
    }

    // MARK: - Screenshots

    /// `screenshotCount` was added behind an explicit initializer specifically so the
    /// seven-argument form above keeps compiling. This asserts that, and the default.
    func testScreenshotCountDefaultsToZero() {
        let r = record(full)
        XCTAssertEqual(r.screenshotCount, 0)
        XCTAssertFalse(r.hasScreenshots)
    }

    func testScreenshotPathsHangOffTheMeetingFolder() {
        let r = MeetingRecord(
            folderURL: URL(fileURLWithPath: "/tmp/2026-03-08 14-30-00"),
            folderName: "2026-03-08 14-30-00",
            title: nil,
            date: Date(timeIntervalSince1970: 0),
            hasAudio: true,
            hasVideo: true,
            transcriptContent: nil,
            screenshotCount: 12
        )
        XCTAssertTrue(r.hasScreenshots)
        XCTAssertEqual(r.screenshotsFolderURL.lastPathComponent, "screenshots")
        XCTAssertEqual(r.screenshotManifestURL.lastPathComponent, "screenshots.json")
        XCTAssertEqual(r.screenshotsFolderURL.deletingLastPathComponent().path, r.folderURL.path)
    }
}
