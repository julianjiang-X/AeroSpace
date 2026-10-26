@testable import AppBundle
import XCTest

final class WorkspaceRuleEngineTest: XCTestCase {
    private func identity(appId: String? = "example.app", path: String? = "/opt/game/wine", guest: String? = "Game.exe", role: String? = "AXWindow", subrole: String? = "AXUnknown", title: String? = "Game") -> WorkspaceRuleWindowIdentity {
        .init(process: .init(appId: appId, bundlePath: "/Applications/Example.app", executablePath: path), firstExeArgument: guest, role: role, subrole: subrole, title: title)
    }

    func testExactAppIDAndFirstMatchingRuleWin() {
        let first = WorkspaceRule(id: "observe", match: .init(appId: "example.app"), workspace: "A", policy: .observe)
        let second = WorkspaceRule(id: "enforce", match: .init(appId: "example.app"), workspace: "B", policy: .enforce)
        XCTAssertEqual(WorkspaceRuleEngine.firstMatch(rules: [first, second], identity: identity())?.id, "observe")
        XCTAssertEqual(WorkspaceRuleEngine.firstMatch(rules: [second, first], identity: identity())?.workspace, "B")
        XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [first], identity: identity(appId: "example.other")))
        XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [first], identity: identity(appId: nil)))
        XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [], identity: identity()))
    }

    func testGuestIdentityIsExactAndCaseInsensitiveWithoutMatchingOtherGuests() {
        let rule = WorkspaceRule(id: "game", match: .init(executablePath: "/opt/game/wine", appIdAbsent: true, firstExeArgument: ["Game.exe"], windowTitle: ["Game"], axRole: "AXWindow", axSubrole: "AXUnknown"), workspace: "GAME", policy: .enforce)
        XCTAssertNotNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil)))
        XCTAssertNotNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, path: "/opt/game/../game/wine", guest: "C:\\Games\\GAME.EXE")))
        for guest in [nil, "Other.exe", "Game.exe.backup", "not-executable"] {
            XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, guest: guest)))
        }
        XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity()))
        XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, path: "/opt/other/wine")))
        XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, role: "AXSheet")))
        XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, subrole: nil)))
        XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, title: "Other Game")))
    }

    func testBundlePathAndMissingFieldsDoNotBroadenIdentity() {
        let exact = WorkspaceRule(id: "exact", match: .init(appId: "example.app", bundlePath: "/Applications/Example.app", executablePath: "/opt/game/wine"), workspace: "A", policy: .enforce)
        XCTAssertNotNil(WorkspaceRuleEngine.firstMatch(rules: [exact], identity: identity()))
        let otherBundle = WorkspaceRuleWindowIdentity(process: .init(appId: "example.app", bundlePath: "/Applications/Other.app", executablePath: "/opt/game/wine"), firstExeArgument: "Game.exe", role: "AXWindow", subrole: "AXUnknown", title: "Game")
        XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [exact], identity: otherBundle))
        for match in [WorkspaceRule.Match(), .init(windowTitle: ["Game"]), .init(executablePath: "/opt/game/wine"), .init(executablePath: "wine", firstExeArgument: ["Game.exe"]), .init(appId: "example.app", appIdAbsent: true)] {
            let malformed = WorkspaceRule(id: "bad", match: match, workspace: "A", policy: .enforce)
            XCTAssertNil(WorkspaceRuleEngine.firstMatch(rules: [malformed], identity: identity()))
        }
    }
}
