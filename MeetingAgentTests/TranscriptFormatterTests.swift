import XCTest
@testable import deep_state_Meeting_Agent

final class TranscriptFormatterTests: XCTestCase {

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(TranscriptFormatter.formatPlainText(""), "")
    }

    func testShortTextIsCapitalizedAndTrimmed() {
        // Fewer than `sentencesPerParagraph` sentences → single capitalized line.
        XCTAssertEqual(TranscriptFormatter.formatPlainText("  hello there  "), "Hello there")
    }

    func testManySentencesAreGroupedIntoParagraphs() {
        // 6 sentences with default 5-per-paragraph → two paragraphs separated by blank line.
        let input = "one. two. three. four. five. six."
        let output = TranscriptFormatter.formatPlainText(input)
        XCTAssertTrue(output.contains("\n\n"), "Expected a paragraph break, got: \(output)")
        XCTAssertTrue(output.hasSuffix("six."))
    }
}
