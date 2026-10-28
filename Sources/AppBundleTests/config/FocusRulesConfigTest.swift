@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class FocusRulesConfigTest: XCTestCase {
    private let testHostRule = """
    [[focus-rules]]
    id = 'test-host'
    if.app-name-regex-substring = '^dmhost$'
    policy = 'ignore-activation'
    """

    private func parse(_ raw: String) -> ParseConfigResult {
        parseConfig("config-version = 2\n" + raw)
    }

    func testRulesAreOptionalAndParsedInOrder() {
        let none = parse("")
        XCTAssertTrue(none.errors.isEmpty)
        XCTAssertTrue(none.config.focusRules.isEmpty)
        XCTAssertTrue(parse("focus-rules = []").errors.isEmpty)

        let result = parse(testHostRule + """

            [[focus-rules]]
            id = 'parked'
            if = { app-id = 'example.app', window-title-regex-substring = 'Preview', workspace = 'Emu' }
            policy = 'ignore-activation'
            """)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.config.focusRules.map(\.id), ["test-host", "parked"])
        guard result.config.focusRules.count == 2 else { return }
        let host = result.config.focusRules[0]
        XCTAssertEqual(host.policy, .ignoreActivation)
        XCTAssertEqual(host.matcher.appNameRegexSubstring?.origin, "^dmhost$")
        XCTAssertNil(host.matcher.appId)
        let parked = result.config.focusRules[1]
        XCTAssertEqual(parked.matcher.appId, "example.app")
        XCTAssertEqual(parked.matcher.windowTitleRegexSubstring?.origin, "Preview")
        XCTAssertEqual(parked.matcher.workspace, "Emu")
    }

    func testRequiredFieldsAreStrict() {
        for field in ["id = 'test-host'\n", "if.app-name-regex-substring = '^dmhost$'\n", "policy = 'ignore-activation'"] {
            let result = parse(testHostRule.replacingOccurrences(of: field, with: ""))
            XCTAssertFalse(result.errors.isEmpty, "Accepted missing \(field)")
            XCTAssertTrue(result.config.focusRules.isEmpty)
        }
        XCTAssertFalse(parse(testHostRule.replacingOccurrences(of: "id = 'test-host'", with: "id = ' '")).errors.isEmpty)
        XCTAssertFalse(parse(testHostRule + "\n" + testHostRule).errors.isEmpty)
    }

    func testInvalidValuesRejectTheRule() {
        let invalid = [
            testHostRule.replacingOccurrences(of: "'ignore-activation'", with: "'follow'"),
            testHostRule + "\nworkspace = 'Emu'",
            testHostRule.replacingOccurrences(of: "if.app-name-regex-substring", with: "if.app-name"),
            testHostRule.replacingOccurrences(of: "if.app-name-regex-substring = '^dmhost$'", with: "if = {}"),
            testHostRule.replacingOccurrences(of: "if.app-name-regex-substring = '^dmhost$'", with: "if = 'true'"),
            testHostRule + "\nif.during-aerospace-startup = false",
            "focus-rules = 'test-host'",
        ]
        for raw in invalid {
            let result = parse(raw)
            XCTAssertFalse(result.errors.isEmpty, "Accepted \(raw)")
            XCTAssertTrue(result.config.focusRules.isEmpty)
        }
    }
}
