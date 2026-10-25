@testable import AppBundle
import XCTest

@MainActor
final class CompatibilityRulesConfigTest: XCTestCase {
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

    func testValidRuleTypesAndExactValues() {
        let result = parse(appRule + "\n" + windowRule)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.config.compatibilityRules.count, 2)
        guard result.config.compatibilityRules.count == 2 else { return }
        let app = result.config.compatibilityRules[0]
        XCTAssertEqual(app.id, "wrapped-launcher")
        XCTAssertEqual(app.phase, .application)
        XCTAssertEqual(app.match.appId, "example.launcher")
        XCTAssertEqual(app.match.bundlePath, "/Applications/Launcher.app")
        XCTAssertEqual(app.match.executablePath, "/Applications/Launcher.app/Contents/MacOS/Launcher")
        XCTAssertEqual(app.action.recoverPid, .windowOwner)
        XCTAssertNil(app.action.classify)
        let window = result.config.compatibilityRules[1]
        XCTAssertEqual(window.phase, .window)
        XCTAssertEqual(window.match.firstExeArgument, ["Game.exe"])
        XCTAssertEqual(window.match.windowTitle, ["Game"])
        XCTAssertEqual(window.match.axRole, "AXWindow")
        XCTAssertEqual(window.match.axSubrole, "AXUnknown")
        XCTAssertEqual(window.match.activationPolicy, .regular)
        XCTAssertEqual(window.match.nativeFullscreen, false)
        XCTAssertEqual(window.match.appIdAbsent, true)
        XCTAssertEqual(window.match.windowLevel, [0, 26])
        XCTAssertEqual(window.match.minSize, [640.0, 360.0])
        XCTAssertEqual(window.action.classify, .floating)
        XCTAssertNil(window.action.recoverPid)
    }

    func testOptionalWindowFieldsAndEmptyRuleList() {
        let minimal = """
        [[compatibility-rules]]
        id = 'identified-window'
        phase = 'window'
        match = { app-id = 'example.app', window-title = ['Main'], ax-role = 'AXWindow', ax-subrole = 'AXUnknown' }
        action = { classify = 'floating' }
        """
        XCTAssertTrue(parse(minimal).errors.isEmpty)
        XCTAssertTrue(parse("compatibility-rules = []").errors.isEmpty)
        XCTAssertEqual(parse("").config.compatibilityRules, [])
    }

    func testHomePathsExpandButOtherRelativePathsAreRejected() {
        let result = parse(appRule.replacingOccurrences(of: "'/Applications/Launcher.app'", with: "'~/Applications/Launcher.app'"))
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.config.compatibilityRules.first?.match.bundlePath, NSHomeDirectory() + "/Applications/Launcher.app")
        let homeWindow = parse(windowRule.replacingOccurrences(of: "'/opt/game/wine'", with: "'~/Games/wine'"))
        XCTAssertTrue(homeWindow.errors.isEmpty)
        XCTAssertEqual(homeWindow.config.compatibilityRules.first?.match.executablePath, NSHomeDirectory() + "/Games/wine")
    }

    func testRejectsUnknownKeysAtEveryRuleTable() {
        for (original, replacement) in [
            ("phase = 'application'", "phase = 'application'\nunknown = true"),
            ("match = { app-id", "match = { mystery = true, app-id"),
            ("action = { recover-pid", "action = { mystery = true, recover-pid"),
        ] {
            let result = parse(appRule.replacingOccurrences(of: original, with: replacement))
            XCTAssertTrue(result.errors.contains { $0.message == "Unknown key" }, "\(result.errors)")
            XCTAssertTrue(result.config.compatibilityRules.isEmpty)
        }
    }

    func testApplicationIdentityAndPhaseAreStrict() {
        let invalidRules = [
            appRule.replacingOccurrences(of: "id = 'wrapped-launcher'", with: "id = ''"),
            appRule.replacingOccurrences(of: "id = 'wrapped-launcher'", with: ""),
            appRule.replacingOccurrences(of: "phase = 'application'", with: "phase = 'unknown'"),
            appRule.replacingOccurrences(of: "phase = 'application'", with: ""),
            appRule.replacingOccurrences(of: "app-id = 'example.launcher', ", with: ""),
            appRule.replacingOccurrences(of: "bundle-path = '/Applications/Launcher.app', ", with: ""),
            appRule.replacingOccurrences(of: ", executable-path = '/Applications/Launcher.app/Contents/MacOS/Launcher'", with: ""),
            appRule.replacingOccurrences(of: "'/Applications/Launcher.app'", with: "'Applications/Launcher.app'"),
            appRule.replacingOccurrences(of: "'/Applications/Launcher.app/Contents/MacOS/Launcher'", with: "'Launcher'"),
            appRule.replacingOccurrences(of: "match = {", with: "match = { window-title = ['Game'],"),
            appRule.replacingOccurrences(of: "recover-pid = 'window-owner'", with: "classify = 'floating'"),
            appRule.replacingOccurrences(of: "'window-owner'", with: "'any-process'"),
            appRule.replacingOccurrences(of: "action = { recover-pid = 'window-owner' }", with: "action = {}"),
            appRule.replacingOccurrences(of: "action = { recover-pid = 'window-owner' }", with: ""),
            appRule.replacingOccurrences(of: "match = { app-id = 'example.launcher', bundle-path = '/Applications/Launcher.app', executable-path = '/Applications/Launcher.app/Contents/MacOS/Launcher' }", with: "match = false"),
        ]
        for rules in invalidRules {
            let result = parse(rules)
            XCTAssertFalse(result.errors.isEmpty, rules)
            XCTAssertTrue(result.config.compatibilityRules.isEmpty, rules)
        }
        XCTAssertFalse(parse(appRule + "\n" + appRule).errors.isEmpty)
    }

    func testWindowMatchAndActionsAreStrict() {
        let mutations = [
            ("executable-path = '/opt/game/wine', ", ""),
            ("'/opt/game/wine'", "'wine'"),
            ("window-title = ['Game'], ", ""),
            ("ax-role = 'AXWindow', ", ""),
            ("ax-subrole = 'AXUnknown', ", ""),
            ("app-id-absent = true", "app-id = 'example.app', app-id-absent = true"),
            ("app-id-absent = true", "app-id-absent = 1"),
            ("['Game.exe']", "[]"),
            ("['Game.exe']", "['dir/Game.exe']"),
            ("['Game.exe']", "['dir\\Game.exe']"),
            ("['Game.exe']", "['Game']"),
            ("['Game.exe']", "['.exe']"),
            ("['Game']", "[]"),
            ("['Game']", "['']"),
            ("['Game']", "[1]"),
            ("'regular'", "'accessory'"),
            ("native-fullscreen = false", "native-fullscreen = 'false'"),
            ("[0, 26]", "[]"),
            ("[0, 26]", "['0']"),
            ("[640, 360]", "[]"),
            ("[640, 360]", "[640]"),
            ("[640, 360]", "[640, 360, 1]"),
            ("[640, 360]", "[0, 360]"),
            ("[640, 360]", "[-1, 360]"),
            ("[640, 360]", "[640.5, 360]"),
            ("[640, 360]", "[inf, 360]"),
            ("[640, 360]", "[true, 360]"),
            ("classify = 'floating'", "classify = 'tiled'"),
            ("classify = 'floating'", "recover-pid = 'window-owner'"),
        ]
        for (original, replacement) in mutations {
            let result = parse(windowRule.replacingOccurrences(of: original, with: replacement))
            XCTAssertFalse(result.errors.isEmpty, "Accepted \(original) -> \(replacement)")
        }
        XCTAssertFalse(parse("compatibility-rules = {}").errors.isEmpty)
        XCTAssertFalse(parse("compatibility-rules = [1]").errors.isEmpty)
    }
}
