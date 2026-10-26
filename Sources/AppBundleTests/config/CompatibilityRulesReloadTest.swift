@testable import AppBundle
import XCTest

@MainActor
final class CompatibilityRulesReloadTest: XCTestCase {
    private let appRule = """
    [[compatibility-rules]]
    id = 'wrapped-launcher'
    phase = 'application'
    match = { app-id = 'example.launcher', bundle-path = '/Applications/Launcher.app', executable-path = '/Applications/Launcher.app/Contents/MacOS/Launcher' }
    action = { recover-pid = 'window-owner' }
    """

    private let windowRule = """
    [[compatibility-rules]]
    id = 'game-main'
    phase = 'window'
    match = { executable-path = '/opt/game/wine', app-id-absent = true, first-exe-argument = ['Game.exe'], window-title = ['Game'], ax-role = 'AXWindow', ax-subrole = 'AXUnknown', activation-policy = 'regular', native-fullscreen = false, window-level = [0, 26], min-size = [640, 360] }
    action = { classify = 'floating' }
    """

    private func parse(_ rules: String) -> ParseConfigResult {
        parseConfig("config-version = 2\n" + rules)
    }

    func testRuntimeRuleChangeRequiresRestartButOrdinaryReloadIsAllowed() {
        let current = parse(appRule)
        XCTAssertTrue(current.errors.isEmpty)
        let changedLayout = parse("accordion-padding = 44\n" + appRule)
        XCTAssertTrue(configReloadErrors(changedLayout, currentRules: current.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false).isEmpty)

        for candidate in [parse(""), parse(windowRule), parse(appRule + "\n" + windowRule)] {
            let errors = configReloadErrors(candidate, currentRules: current.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false)
            XCTAssertEqual(errors.count, 1)
            XCTAssertTrue(errors[0].message.contains("requires an AeroSpace restart"))
            XCTAssertTrue(errors[0].preventConfigReload)
        }
        let ordered = parse(appRule + "\n" + windowRule)
        let reordered = parse(windowRule + "\n" + appRule)
        XCTAssertFalse(configReloadErrors(reordered, currentRules: ordered.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false).isEmpty)
        XCTAssertTrue(configReloadErrors(ordered, currentRules: [], rulesLocked: false, warningsAsErrors: false).isEmpty)
    }

    func testInvalidCandidateAndWarningsCannotPublishPartialConfig() {
        let currentRules = parse(appRule).config.compatibilityRules
        for candidate in [parse("accordion-padding = 'invalid'"), parse(windowRule.replacingOccurrences(of: "'floating'", with: "'invalid'"))] {
            XCTAssertFalse(candidate.errors.isEmpty)
            let errors = configReloadErrors(candidate, currentRules: currentRules, rulesLocked: true, warningsAsErrors: false)
            XCTAssertEqual(errors.count, candidate.errors.count)
            XCTAssertFalse(errors.contains { $0.message.contains("requires an AeroSpace restart") })
        }
        let warning = parseConfig("config-version = 1")
        XCTAssertTrue(warning.errors.isEmpty)
        XCTAssertFalse(warning.warnings.isEmpty)
        XCTAssertTrue(configReloadErrors(warning, currentRules: [], rulesLocked: true, warningsAsErrors: false).isEmpty)
        XCTAssertFalse(configReloadErrors(warning, currentRules: [], rulesLocked: true, warningsAsErrors: true).isEmpty)
    }

    func testMinimizedRestoreChangeRequiresRestartAndLeavesOrdinaryReloadAvailable() {
        let oldRules = parse(windowRule)
        let restoringRule = windowRule.replacingOccurrences(
            of: "classify = 'floating'",
            with: "classify = 'floating', restore-minimized = 'on-workspace-focus'",
        )
        let restoring = parse(restoringRule)
        XCTAssertTrue(restoring.errors.isEmpty)
        for (current, candidate) in [(oldRules, restoring), (restoring, oldRules)] {
            let errors = configReloadErrors(candidate, currentRules: current.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false)
            XCTAssertEqual(errors.count, 1)
            XCTAssertTrue(errors.first?.message.contains("requires an AeroSpace restart") == true)
            XCTAssertTrue(errors.first?.preventConfigReload == true)
        }
        let changedLayout = parse("accordion-padding = 44\n" + restoringRule)
        XCTAssertTrue(configReloadErrors(changedLayout, currentRules: restoring.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false).isEmpty)
        XCTAssertTrue(configReloadErrors(restoring, currentRules: oldRules.config.compatibilityRules, rulesLocked: false, warningsAsErrors: false).isEmpty)
    }

    func testInvalidMinimizedRestoreCannotPublishPartialConfigOrMaskItsError() {
        let current = parse(windowRule)
        let invalid = parse("accordion-padding = 44\n" + windowRule.replacingOccurrences(
            of: "classify = 'floating'",
            with: "classify = 'floating', restore-minimized = true",
        ))
        XCTAssertFalse(invalid.errors.isEmpty)
        let errors = configReloadErrors(invalid, currentRules: current.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false)
        XCTAssertEqual(errors, invalid.errors)
        XCTAssertFalse(errors.contains { $0.message.contains("requires an AeroSpace restart") })
    }
}
