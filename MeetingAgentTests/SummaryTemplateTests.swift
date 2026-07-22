import XCTest
@testable import Deep_State_Meeting_Agent_MacOS

final class SummaryTemplateTests: XCTestCase {

    func testAllTemplatesHaveNonEmptySystemPrompt() {
        for template in SummaryTemplate.allCases {
            XCTAssertFalse(
                template.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(template.rawValue) has an empty system prompt"
            )
        }
    }

    func testTemplateIdsAreUnique() {
        let ids = SummaryTemplate.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "SummaryTemplate ids are not unique")
    }

    func testExpectedTemplateCount() {
        XCTAssertEqual(SummaryTemplate.allCases.count, 6)
    }
}
