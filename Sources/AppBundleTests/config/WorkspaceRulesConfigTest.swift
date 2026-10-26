@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class WorkspaceRulesConfigTest: XCTestCase {
    private let launcherRule = """
    [[workspace-rules]]
    id = 'launcher-home'
    match = { app-id = 'example.launcher' }
    workspace = 'HOME'
    policy = 'enforce'
    """

    private let gameRule = """
    [[workspace-rules]]
    id = 'game-home'
    match = { executable-path = '/opt/game/wine', app-id-absent = true, first-exe-argument = ['Game.exe'], window-title = ['Game', 'Localized Game'], ax-role = 'AXWindow', ax-subrole = 'AXUnknown' }
    workspace = 'GAME'
    policy = 'observe'
    """

    private func parse(_ raw: String) -> ParseConfigResult {
        parseConfig("config-version = 2\n" + raw)
    }

    func testOldConfigurationIsDisabledAndRulesAreExplicit() {
        let old = parse("")
        XCTAssertTrue(old.errors.isEmpty)
        XCTAssertFalse(old.config.workspaceRulesEnabled)
        XCTAssertTrue(old.config.workspaceRules.isEmpty)
        let result = parse("workspace-rules-enabled = true\n" + launcherRule + "\n" + gameRule)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertTrue(result.config.workspaceRulesEnabled)
        XCTAssertEqual(result.config.workspaceRules.count, 2)
        guard result.config.workspaceRules.count == 2 else { return }
        let launcher = result.config.workspaceRules[0]
        XCTAssertEqual(launcher.id, "launcher-home")
        XCTAssertEqual(launcher.match.appId, "example.launcher")
        XCTAssertEqual(launcher.workspace, "HOME")
        XCTAssertEqual(launcher.policy, .enforce)
        let game = result.config.workspaceRules[1]
        XCTAssertEqual(game.match.executablePath, "/opt/game/wine")
        XCTAssertEqual(game.match.firstExeArgument, ["Game.exe"])
        XCTAssertEqual(game.match.windowTitle, ["Game", "Localized Game"])
        XCTAssertEqual(game.match.axRole, "AXWindow")
        XCTAssertEqual(game.match.axSubrole, "AXUnknown")
        XCTAssertEqual(game.match.appIdAbsent, true)
        XCTAssertEqual(game.policy, .observe)
        XCTAssertTrue(parse("workspace-rules = []").errors.isEmpty)
    }

    func testRequiredFieldsAndRuleIDsAreStrict() {
        for field in ["id = 'launcher-home'\n", "match = { app-id = 'example.launcher' }\n", "workspace = 'HOME'\n", "policy = 'enforce'"] {
            let result = parse(launcherRule.replacingOccurrences(of: field, with: ""))
            XCTAssertFalse(result.errors.isEmpty, "Accepted missing \(field)")
            XCTAssertTrue(result.config.workspaceRules.isEmpty)
        }
        let duplicate = parse(launcherRule + "\n" + launcherRule)
        XCTAssertFalse(duplicate.errors.isEmpty)
        XCTAssertTrue(duplicate.errors.contains { $0.message.contains("ids must be unique") })
        for value in ["''", "' '", "1", "false", "[]", "{}"] {
            let result = parse(launcherRule.replacingOccurrences(of: "id = 'launcher-home'", with: "id = \(value)"))
            XCTAssertFalse(result.errors.isEmpty, "Accepted id \(value)")
            XCTAssertTrue(result.config.workspaceRules.isEmpty)
        }
    }

    func testUnknownKeysTypesAndPoliciesAreRejected() {
        for (from, to) in [
            ("policy = 'enforce'", "policy = 'enforce'\nextra = true"),
            ("match = {", "match = { extra = true,"),
            ("match = { app-id = 'example.launcher' }", "match = false"),
            ("app-id = 'example.launcher'", "app-id = 1"),
            ("policy = 'enforce'", "policy = 'always'"),
            ("policy = 'enforce'", "policy = 'ENFORCE'"),
            ("policy = 'enforce'", "policy = true"),
        ] {
            let result = parse(launcherRule.replacingOccurrences(of: from, with: to))
            XCTAssertFalse(result.errors.isEmpty, "Accepted \(to)")
            XCTAssertTrue(result.config.workspaceRules.isEmpty)
        }
        for raw in ["workspace-rules = {}", "workspace-rules = [1]", "workspace-rules-enabled = 1", "workspace-rules-enabled = 'true'", "workspace-rules-enabled = []"] {
            XCTAssertFalse(parse(raw).errors.isEmpty, "Accepted \(raw)")
        }
    }

    func testOnlyExactIdentityAnchorsAreAccepted() {
        for raw in [
            "{}",
            "{ window-title = ['Game'] }",
            "{ executable-path = '/opt/game/wine' }",
            "{ first-exe-argument = ['Game.exe'] }",
            "{ app-id = '' }",
            "{ app-id = 'example.app', app-id-absent = true }",
            "{ executable-path = 'wine', first-exe-argument = ['Game.exe'] }",
            "{ executable-path = '/opt/game/wine', first-exe-argument = [] }",
            "{ executable-path = '/opt/game/wine', first-exe-argument = ['dir/Game.exe'] }",
            "{ executable-path = '/opt/game/wine', first-exe-argument = ['dir\\Game.exe'] }",
            "{ executable-path = '/opt/game/wine', first-exe-argument = ['Game'] }",
            "{ executable-path = '/opt/game/wine', first-exe-argument = ['.exe'] }",
            "{ executable-path = '/opt/game/wine', first-exe-argument = [1] }",
        ] {
            let result = parse(launcherRule.replacingOccurrences(of: "{ app-id = 'example.launcher' }", with: raw))
            XCTAssertFalse(result.errors.isEmpty, "Accepted match \(raw)")
            XCTAssertTrue(result.config.workspaceRules.isEmpty)
        }
        let home = parse(gameRule.replacingOccurrences(of: "'/opt/game/wine'", with: "'~/Games/wine'"))
        XCTAssertTrue(home.errors.isEmpty)
        XCTAssertEqual(home.config.workspaceRules.first?.match.executablePath, NSHomeDirectory() + "/Games/wine")
        let paths = parse(launcherRule.replacingOccurrences(of: "app-id = 'example.launcher'", with: "app-id = 'example.launcher', bundle-path = '/Applications/Launcher.app', executable-path = '/Applications/Launcher.app/Contents/MacOS/Launcher'"))
        XCTAssertTrue(paths.errors.isEmpty)
    }

    func testWorkspaceAndOptionalMatchFieldsAreStrict() {
        for value in ["''", "' '", "'next'", "'_reserved'", "'-option'", "'two words'", "'a,b'", "1", "false", "[]"] {
            let result = parse(launcherRule.replacingOccurrences(of: "workspace = 'HOME'", with: "workspace = \(value)"))
            XCTAssertFalse(result.errors.isEmpty, "Accepted workspace \(value)")
        }
        for (from, to) in [
            ("window-title = ['Game', 'Localized Game']", "window-title = []"),
            ("window-title = ['Game', 'Localized Game']", "window-title = ['']"),
            ("window-title = ['Game', 'Localized Game']", "window-title = [1]"),
            ("ax-role = 'AXWindow'", "ax-role = false"),
            ("ax-subrole = 'AXUnknown'", "ax-subrole = []"),
            ("app-id-absent = true", "app-id-absent = 1"),
        ] {
            XCTAssertFalse(parse(gameRule.replacingOccurrences(of: from, with: to)).errors.isEmpty, "Accepted \(to)")
        }
    }

    func testWorkspaceRuleUpdatesDoNotAcquireCompatibilityRestartLock() {
        let original = parse(launcherRule)
        let changed = parse("workspace-rules-enabled = true\n" + launcherRule.replacingOccurrences(of: "'HOME'", with: "'OTHER'"))
        XCTAssertTrue(configReloadErrors(changed, currentRules: original.config.compatibilityRules, rulesLocked: true, warningsAsErrors: true).isEmpty)
        XCTAssertEqual(changed.config.workspaceRules.first?.workspace, "OTHER")
        XCTAssertTrue(changed.config.workspaceRulesEnabled)
    }
}
