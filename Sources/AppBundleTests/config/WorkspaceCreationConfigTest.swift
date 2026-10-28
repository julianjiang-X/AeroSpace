@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class WorkspaceCreationConfigTest: XCTestCase {
    private func parse(_ raw: String) -> ParseConfigResult {
        parseConfig("config-version = 2\n" + raw)
    }

    func testSettingDefaultsToAutoAndAcceptsPersistentOnly() {
        let none = parse("")
        XCTAssertTrue(none.errors.isEmpty)
        XCTAssertEqual(none.config.workspaceCreation, .auto)
        let strict = parse("persistent-workspaces = ['1', 'Mail']\nworkspace-creation = 'persistent-only'")
        XCTAssertTrue(strict.errors.isEmpty, "\(strict.errors)")
        XCTAssertEqual(strict.config.workspaceCreation, .persistentOnly)
        XCTAssertEqual(parse("workspace-creation = 'auto'").config.workspaceCreation, .auto)
        for invalid in ["workspace-creation = 'never'", "workspace-creation = true"] {
            XCTAssertFalse(parse(invalid).errors.isEmpty, "Accepted \(invalid)")
        }
    }

    func testOnlyPersistentOrExistingNamesPassInPersistentOnlyMode() {
        let saved = config
        defer { config = saved }
        config.persistentWorkspaces = ["1", "Mail"]

        config.workspaceCreation = .auto
        XCTAssertNil(workspaceCreationError("zz-unlisted-workspace"))

        config.workspaceCreation = .persistentOnly
        XCTAssertNil(workspaceCreationError("1"))
        XCTAssertNil(workspaceCreationError("Mail"))
        XCTAssertNotNil(workspaceCreationError("zz-unlisted-workspace"))
        XCTAssertNotNil(workspaceCreationError("6"))
        XCTAssertNotNil(workspaceCreationError("mail"), "Names are exact")
    }
}
