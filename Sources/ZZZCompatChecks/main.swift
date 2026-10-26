// Generated from compatibility tests and the upstream AX fixture adapter.
// Regenerate with python3 script/generate-compatibility-checks.py <repo-root>.
// This is a focused offline runner, not the complete XCTest suite.
#if DEBUG
import AppKit
@testable import AppBundle
import Common
import Foundation

struct FailedCheck: Error { let message: String }

@MainActor
final class CheckRunner {
    var assertions = 0
    var failures = 0
    var groups = 0
    var fixtures = 0

    func expectNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(value == nil, "\(message) expected nil", file, line)
    }
    func expectNotNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(value != nil, "\(message) expected non-nil", file, line)
    }
    func expectTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(value, "\(message) expected true", file, line)
    }
    func expectFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        record(!value, "\(message) expected false", file, line)
    }
    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        record(actual == expected, "\(message) expected \(expected), got \(actual)", file, line)
    }
    func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        assertions += 1
        guard let value else { throw FailedCheck(message: "\(file):\(line): expected non-nil") }
        return value
    }
    private func record(_ passed: Bool, _ message: String, _ file: StaticString, _ line: UInt) {
        assertions += 1
        if !passed {
            failures += 1
            print("FAIL \(file):\(line): \(message)")
        }
    }
    func run(_ name: String, _ body: @MainActor () throws -> Void) {
        groups += 1
        let before = failures
        do { try body() }
        catch { failures += 1; print("FAIL \(name): \(error)") }
        print("\(failures == before ? "PASS" : "FAIL") \(name)")
    }
}

@MainActor
func checkUpstreamAxDumps(_ dir: URL, _ checks: CheckRunner) throws {
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .sorted { $0.path < $1.path }
    for file in files {
        if file.isDirectory { try checkUpstreamAxDumps(file, checks); continue }
        if file.pathExtension == "md" { continue }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: [.json5Allowed])
        guard let rawJson = raw as? [String: Any] else { throw FailedCheck(message: "Invalid fixture \(file.path)") }
        let json = Json.newOrDieRecursive(rawJson).asDictOrDie
        let app = json["Aero.AXApp"]!.asDictOrDie
        let appId = (rawJson["Aero.App.appBundleId"] as? String).flatMap { KnownBundleId(rawValue: $0) }
        let level = json["Aero.windowLevel"].map { MacOsWindowLevel.fromJson($0) ?? dieT() }
        let policy = NSApplication.ActivationPolicy.from(string: rawJson["Aero.App.nsApp.activationPolicy"] as! String)
        checks.expectEqual(
            json.getWindowType(axApp: app, appId, policy, level),
            AxUiElementWindowType(rawValue: rawJson["Aero.AxUiElementWindowType"] as? String ?? dieT()),
            file.lastPathComponent + " window type",
        )
        checks.expectEqual(
            json.isDialogHeuristic(appId, level),
            rawJson["Aero.AxUiElementWindowType_isDialogHeuristic"] as? Bool ?? dieT(),
            file.lastPathComponent + " dialog heuristic",
        )
        checks.fixtures += 1
    }
}


@MainActor
final class CompatibilityOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
    private let wrapperIdentity = CompatibilityProcessIdentity(
        appId: "org.fixture.wrapper", bundlePath: "/fixture/Wrapper.app",
        executablePath: "/fixture/Wrapper.app/Contents/MacOS/Wrapper",
    )
    private let clientIdentity = CompatibilityProcessIdentity(
        appId: nil, bundlePath: nil, executablePath: "/fixture/runtime/bin/loader",
    )

    private func applicationRule(_ id: String = "fixture-pid") -> CompatibilityRule {
        .init(id: id, phase: .application, match: .init(
            appId: wrapperIdentity.appId, bundlePath: wrapperIdentity.bundlePath,
            executablePath: wrapperIdentity.executablePath,
        ), action: .init(recoverPid: .windowOwner))
    }

    private func windowRule(_ id: String = "fixture-floating", match: CompatibilityRule.Match? = nil) -> CompatibilityRule {
        .init(id: id, phase: .window, match: match ?? .init(
            executablePath: clientIdentity.executablePath, appIdAbsent: true,
            firstExeArgument: ["Client.exe", "Client-CN.exe"], windowTitle: ["Example client", "示例客户端"],
            axRole: kAXWindowRole, axSubrole: kAXUnknownSubrole, activationPolicy: .regular,
            nativeFullscreen: false, windowLevel: [0, 26], minSize: [640, 360],
        ), action: .init(classify: .floating))
    }

    private func windowRules(_ rules: [CompatibilityRule]? = nil, arguments: [String]? = ["Z:\\Client\\Client.exe"]) -> CompatibilityWindowRules {
        CompatibilityRuleEngine.windowRules(rules: rules ?? [windowRule()], identity: clientIdentity, arguments: { arguments })
    }

    func testNativePositivePIDBypassesRecoveryAndNoRulesRejectInvalidPID() {
        var reads = 0
        let result = CompatibilityRuleEngine.resolveProcess(
            rules: [], reportedPID: 42, identity: wrapperIdentity,
            ownerPIDs: { reads += 1; return [] }, processPath: { _ in reads += 1; return nil },
        )
        checks.expectEqual(result?.pid, 42)
        checks.expectNil(result?.recoveryRule)
        let invalidPIDs: [Int32] = [-1, 0]
        for pid in invalidPIDs {
            checks.expectNil(CompatibilityRuleEngine.resolveProcess(
                rules: [], reportedPID: pid, identity: wrapperIdentity,
                ownerPIDs: { reads += 1; return [101] }, processPath: { _ in reads += 1; return self.wrapperIdentity.executablePath },
            ))
        }
        checks.expectEqual(reads, 0)
    }

    func testPIDRecoveryUsesExactConfiguredIdentityAndUniqueOwner() {
        let rule = applicationRule()
        let result = CompatibilityRuleEngine.resolveProcess(
            rules: [rule], reportedPID: -1, identity: wrapperIdentity,
            ownerPIDs: { [-1, 0, 101, 101, 202] },
            processPath: { $0 == 101 ? self.wrapperIdentity.executablePath : "/fixture/Other.app/Contents/MacOS/Other" },
        )
        checks.expectEqual(result?.pid, 101)
        checks.expectEqual(result?.recoveryRule?.id, rule.id)
        let cases: [([Int32], [Int32: String])] = [
            ([], [:]), ([-1, 0], [:]), ([101], [:]),
            ([101], [101: "/fixture/Other.app/Contents/MacOS/Other"]),
            ([101], [101: wrapperIdentity.executablePath! + "Helper"]),
            ([101, 202], [101: wrapperIdentity.executablePath!, 202: wrapperIdentity.executablePath!]),
        ]
        for (owners, paths) in cases {
            checks.expectNil(CompatibilityRuleEngine.resolveProcess(
                rules: [rule], reportedPID: -1, identity: wrapperIdentity,
                ownerPIDs: { owners }, processPath: { paths[$0] },
            ))
        }
    }

    func testRecoveryNeverBroadensMissingOrMismatchedMetadata() {
        var reads = 0
        let identities = [
            CompatibilityProcessIdentity(appId: nil, bundlePath: wrapperIdentity.bundlePath, executablePath: wrapperIdentity.executablePath),
            CompatibilityProcessIdentity(appId: "org.fixture.other", bundlePath: wrapperIdentity.bundlePath, executablePath: wrapperIdentity.executablePath),
            CompatibilityProcessIdentity(appId: wrapperIdentity.appId, bundlePath: "/tmp/Wrapper.app", executablePath: wrapperIdentity.executablePath),
            CompatibilityProcessIdentity(appId: wrapperIdentity.appId, bundlePath: wrapperIdentity.bundlePath, executablePath: "/bin/bash"),
        ]
        for identity in identities {
            checks.expectNil(CompatibilityRuleEngine.resolveProcess(
                rules: [applicationRule()], reportedPID: -1, identity: identity,
                ownerPIDs: { reads += 1; return [101] }, processPath: { _ in reads += 1; return self.wrapperIdentity.executablePath },
            ))
        }
        var incomplete = applicationRule().match
        incomplete.bundlePath = nil
        let malformed = CompatibilityRule(id: "incomplete", phase: .application, match: incomplete, action: .init(recoverPid: .windowOwner))
        checks.expectNil(CompatibilityRuleEngine.resolveProcess(
            rules: [malformed, windowRule()], reportedPID: -1, identity: wrapperIdentity,
            ownerPIDs: { reads += 1; return [101] }, processPath: { _ in reads += 1; return self.wrapperIdentity.executablePath },
        ))
        checks.expectEqual(reads, 0)
    }

    func testFirstExecutableArgumentIsGenericExactAndCaseInsensitive() {
        for arguments in [["loader", "Z:\\Client\\Client.exe"], ["/fixture/Client-CN.EXE"]] {
            checks.expectEqual(windowRules(arguments: arguments).rules.map(\.id), ["fixture-floating"])
        }
        let rejectedArguments: [[String]?] = [
            ["CrashReporter.exe", "Client.exe"], ["OtherClient.exe"], ["Client.exe.helper"], ["Client.exe Launcher.exe"], [], nil,
        ]
        for arguments in rejectedArguments {
            checks.expectEqual(windowRules(arguments: arguments).rules.count, 0)
        }
    }

    func testProcessPrefilterReadsArgumentsOnlyOnceAndNeverForUnmatchedRules() {
        var reads = 0
        let loaded = CompatibilityRuleEngine.windowRules(
            rules: [windowRule("one"), windowRule("two")], identity: clientIdentity,
            arguments: { reads += 1; return ["Client.exe"] },
        )
        checks.expectEqual(loaded.rules.map(\.id), ["one", "two"])
        checks.expectEqual(reads, 1)
        _ = CompatibilityRuleEngine.windowRules(
            rules: [windowRule()], identity: wrapperIdentity,
            arguments: { reads += 1; return ["Client.exe"] },
        )
        checks.expectEqual(reads, 1)
        var match = windowRule().match
        match.firstExeArgument = nil
        checks.expectEqual(CompatibilityRuleEngine.windowRules(
            rules: [windowRule(match: match)], identity: clientIdentity,
            arguments: { reads += 1; return nil },
        ).rules.count, 1)
        checks.expectEqual(reads, 1)
    }

    func testWindowRuleCanUseExactAppIDWithoutExecutablePath() {
        var match = windowRule().match
        match.executablePath = nil
        match.appIdAbsent = false
        match.appId = wrapperIdentity.appId
        match.firstExeArgument = nil
        let rules = CompatibilityRuleEngine.windowRules(rules: [windowRule(match: match)], identity: wrapperIdentity, arguments: { nil })
        checks.expectEqual(rules.rules.count, 1)
        checks.expectEqual(CompatibilityRuleEngine.windowRules(rules: [windowRule(match: match)], identity: clientIdentity, arguments: { nil }).rules.count, 0)
        match.appId = nil // No exact process identity: reject even if the window traits match.
        checks.expectEqual(CompatibilityRuleEngine.windowRules(rules: [windowRule(match: match)], identity: wrapperIdentity, arguments: { nil }).rules.count, 0)
    }

    func testMatchingWindowsStayFloatingAcrossFocusAndLevelChanges() {
        for title in ["Example client", "示例客户端"] {
            for focused in [false, true] {
                let window = fixtureWindow(title: title, focused: focused)
                for level in [MacOsWindowLevel.normalWindow, .unknown(windowLevel: 26)] {
                    checks.expectTrue(window.isWindowHeuristic(
                        axApp: FixtureAxElement(fields: [:]), nil, .regular, level, compatibilityRules: windowRules(),
                    ))
                    checks.expectEqual(window.getWindowType(
                        axApp: FixtureAxElement(fields: [:]), nil, .regular, level, compatibilityRules: windowRules(),
                    ), .dialog)
                    checks.expectEqual(window.matchedCompatibilityRule(windowRules(), .regular, level)?.id, "fixture-floating")
                }
            }
        }
    }

    func testFloatingActionOverridesOrdinaryNonDialogWindowAndNoMatchPreservesDefault() {
        var match = windowRule().match
        match.axSubrole = kAXStandardWindowSubrole
        let rules = windowRules([windowRule(match: match)])
        let ordinary = fixtureWindow(subrole: kAXStandardWindowSubrole, fullscreenButtonEnabled: true)
        checks.expectEqual(ordinary.getWindowType(axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow), .window)
        checks.expectEqual(ordinary.getWindowType(axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow, compatibilityRules: rules), .dialog)
        checks.expectEqual(fixtureWindow().getWindowType(axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow), .popup)
        checks.expectEqual(fixtureWindow(title: "Other window").getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow, compatibilityRules: windowRules(),
        ), .popup)
    }

    func testWindowTraitsRejectAuxiliaryAndUnverifiedWindows() {
        let cases: [(FixtureAxElement, NSApplication.ActivationPolicy, MacOsWindowLevel?)] = [
            (fixtureWindow(title: ""), .regular, .normalWindow),
            (fixtureWindow(title: "Example Client"), .regular, .normalWindow),
            (fixtureWindow(title: "Example client Launcher"), .regular, .normalWindow),
            (fixtureWindow(size: CGSize(width: 1920, height: 30)), .regular, .normalWindow),
            (fixtureWindow(size: CGSize(width: 64, height: 64)), .regular, .normalWindow),
            (fixtureWindow(size: CGSize(width: CGFloat.infinity, height: 1080)), .regular, .normalWindow),
            (fixtureWindow(size: CGSize(width: CGFloat.nan, height: 1080)), .regular, .normalWindow),
            (fixtureWindow(fullscreen: true), .regular, .normalWindow),
            (fixtureWindow(fullscreen: nil), .regular, .normalWindow),
            (fixtureWindow(role: kAXButtonRole), .regular, .normalWindow),
            (fixtureWindow(subrole: kAXDialogSubrole), .regular, .normalWindow),
            (fixtureWindow(), .accessory, .normalWindow),
            (fixtureWindow(), .regular, .alwaysOnTopWindow),
            (fixtureWindow(), .regular, nil),
        ]
        for (window, policy, level) in cases {
            checks.expectNil(window.matchedCompatibilityRule(windowRules(), policy, level))
        }
    }

    func testRuleOrderSelectsTheFirstMatchingWindowID() {
        var unmatched = windowRule().match
        unmatched.windowTitle = ["Different window"]
        let rules = windowRules([windowRule("unmatched", match: unmatched), windowRule("first"), windowRule("second")])
        checks.expectEqual(fixtureWindow().matchedCompatibilityRule(rules, .regular, .normalWindow)?.id, "first")
    }

    func testEmptyCompatibilityRulesDoNotReadExtraAXAttributes() {
        let window = CountingAxElement()
        checks.expectNil(window.matchedCompatibilityRule(.empty, .regular, .normalWindow))
        checks.expectEqual(window.reads, 0)
    }

    func testMalformedWindowRulesFallBackToDefaultHeuristics() {
        var missingRole = windowRule().match; missingRole.axRole = nil
        var emptyRole = windowRule().match; emptyRole.axRole = ""
        var emptySubrole = windowRule().match; emptySubrole.axSubrole = " "
        var missingTitles = windowRule().match; missingTitles.windowTitle = nil
        var emptyTitles = windowRule().match; emptyTitles.windowTitle = []
        var blankTitle = windowRule().match; blankTitle.windowTitle = ["Example client", ""]
        var noIdentity = windowRule().match; noIdentity.executablePath = nil
        for match in [missingRole, emptyRole, emptySubrole, missingTitles, emptyTitles, blankTitle, noIdentity] {
            let rule = windowRule(match: match)
            checks.expectEqual(rule.isValidFloatingWindowRule, false)
            checks.expectEqual(windowRules([rule]).rules.count, 0)
            checks.expectEqual(fixtureWindow().getWindowType(
                axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
                compatibilityRules: .init(rules: [rule]),
            ), .popup)
        }
    }

    func testArgumentParserStopsBeforeEnvironmentAndRejectsTruncation() {
        let arguments = ["Z:\\Client\\Client.exe", "-example-option"]
        var argc = Int32(arguments.count)
        var data = unsafe withUnsafeBytes(of: &argc) { unsafe Data($0) }
        data.append(contentsOf: Array("/fixture/loader".utf8) + [0, 0, 0])
        for argument in arguments { data.append(contentsOf: Array(argument.utf8) + [0]) }
        data.append(contentsOf: Array("DO_NOT_PARSE=Other.exe".utf8) + [0, 0])
        checks.expectEqual(CompatibilityProcessAccess.parseArguments(data), arguments)
        checks.expectNil(CompatibilityProcessAccess.parseArguments(Data()))
        checks.expectNil(CompatibilityProcessAccess.parseArguments(data.prefix(8)))
        checks.expectNil(CompatibilityProcessAccess.parseArguments(Data([1, 0, 0])))
    }

    func testFilesystemIdentityIgnoresDirectoryURLHintAndTrailingSlash() {
        let directoryURL = URL(filePath: "/fixture/Wrapper.app", directoryHint: .isDirectory)
        let fileURL = URL(filePath: "/fixture/Wrapper.app", directoryHint: .notDirectory)
        checks.expectTrue(CompatibilityRuleEngine.pathsMatch(directoryURL.path, fileURL.path))
        checks.expectTrue(CompatibilityRuleEngine.pathsMatch("/fixture/Wrapper.app/", "/fixture/Wrapper.app"))
        let identity = CompatibilityProcessIdentity(
            appId: wrapperIdentity.appId, bundlePath: directoryURL.path,
            executablePath: wrapperIdentity.executablePath,
        )
        checks.expectEqual(CompatibilityRuleEngine.resolveProcess(
            rules: [applicationRule()], reportedPID: -1, identity: identity,
            ownerPIDs: { [101] }, processPath: { _ in self.wrapperIdentity.executablePath },
        )?.pid, 101)
        checks.expectEqual(CompatibilityRuleEngine.pathsMatch("/fixture/Wrapper.app.other", "/fixture/Wrapper.app"), false)
        checks.expectEqual(CompatibilityRuleEngine.pathsMatch("relative/Wrapper.app", "/fixture/Wrapper.app"), false)
    }

    private func fixtureWindow(
        title: String = "Example client", role: String = kAXWindowRole, subrole: String = kAXUnknownSubrole,
        size: CGSize = CGSize(width: 1920, height: 1080), focused: Bool = false, fullscreen: Bool? = false,
        fullscreenButtonEnabled: Bool = false,
    ) -> FixtureAxElement {
        var fields: [String: Any] = [
            kAXRoleAttribute: role, kAXSubroleAttribute: subrole, kAXTitleAttribute: title,
            kAXSizeAttribute: size, kAXFocusedAttribute: focused, kAXMainAttribute: focused,
        ]
        if let fullscreen { fields["AXFullScreen"] = fullscreen }
        if fullscreenButtonEnabled {
            fields[kAXFullScreenButtonAttribute] = FixtureAxElement(fields: [kAXEnabledAttribute: true])
        }
        return FixtureAxElement(fields: fields)
    }
}

private struct FixtureAxElement: AxUiElementMock {
    let fields: [String: Any]
    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? { fields[attr.key] as? Attr.T }
    func containingWindowId() -> CGWindowID? { 42 }
}

private final class CountingAxElement: AxUiElementMock {
    var reads = 0
    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? { reads += 1; return nil }
    func containingWindowId() -> CGWindowID? { nil }
}


@MainActor
final class CompatibilityConfigOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
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
        checks.expectTrue(result.errors.isEmpty, "\(result.errors)")
        checks.expectEqual(result.config.compatibilityRules.count, 2)
        guard result.config.compatibilityRules.count == 2 else { return }
        let app = result.config.compatibilityRules[0]
        checks.expectEqual(app.id, "wrapped-launcher")
        checks.expectEqual(app.phase, .application)
        checks.expectEqual(app.match.appId, "example.launcher")
        checks.expectEqual(app.match.bundlePath, "/Applications/Launcher.app")
        checks.expectEqual(app.match.executablePath, "/Applications/Launcher.app/Contents/MacOS/Launcher")
        checks.expectEqual(app.action.recoverPid, .windowOwner)
        checks.expectNil(app.action.classify)
        checks.expectNil(app.action.restoreMinimized)
        let window = result.config.compatibilityRules[1]
        checks.expectEqual(window.phase, .window)
        checks.expectEqual(window.match.firstExeArgument, ["Game.exe"])
        checks.expectEqual(window.match.windowTitle, ["Game"])
        checks.expectEqual(window.match.axRole, "AXWindow")
        checks.expectEqual(window.match.axSubrole, "AXUnknown")
        checks.expectEqual(window.match.activationPolicy, .regular)
        checks.expectEqual(window.match.nativeFullscreen, false)
        checks.expectEqual(window.match.appIdAbsent, true)
        checks.expectEqual(window.match.windowLevel, [0, 26])
        checks.expectEqual(window.match.minSize, [640.0, 360.0])
        checks.expectEqual(window.action.classify, .floating)
        checks.expectNil(window.action.recoverPid)
        checks.expectNil(window.action.restoreMinimized)
    }

    func testWorkspaceFocusMinimizedRestoreIsOptInAndKeepsExactMatch() {
        let oldRules = parse(appRule + "\n" + windowRule)
        let restoringWindowRule = windowRule.replacingOccurrences(
            of: "classify = 'floating'",
            with: "classify = 'floating', restore-minimized = 'on-workspace-focus'",
        )
        let result = parse(appRule + "\n" + restoringWindowRule)
        checks.expectTrue(result.errors.isEmpty, "\(result.errors)")
        checks.expectEqual(result.config.compatibilityRules.count, 2)
        guard result.config.compatibilityRules.count == 2,
              oldRules.config.compatibilityRules.count == 2 else { return }
        checks.expectEqual(result.config.compatibilityRules[0], oldRules.config.compatibilityRules[0])
        let window = result.config.compatibilityRules[1]
        checks.expectEqual(window.action.restoreMinimized, .onWorkspaceFocus)
        checks.expectEqual(window.action.classify, .floating)
        checks.expectNil(window.action.recoverPid)
        checks.expectEqual(window.match, oldRules.config.compatibilityRules[1].match)
        checks.expectTrue(window.isValidFloatingWindowRule)
    }

    func testMinimizedRestoreRejectsUnknownValuesTypesAndMissingClassification() {
        for raw in ["'always'", "'on-window-focus'", "'ON-WORKSPACE-FOCUS'", "''", "' '", "true", "1", "['on-workspace-focus']", "{}"] {
            let rules = windowRule.replacingOccurrences(
                of: "classify = 'floating'",
                with: "classify = 'floating', restore-minimized = \(raw)",
            )
            let result = parse(rules)
            checks.expectFalse(result.errors.isEmpty, "Accepted restore-minimized = \(raw)")
            checks.expectTrue(result.config.compatibilityRules.isEmpty)
        }
        for classification in ["", "classify = 'tiled', "] {
            let rules = windowRule.replacingOccurrences(
                of: "classify = 'floating'",
                with: classification + "restore-minimized = 'on-workspace-focus'",
            )
            let result = parse(rules)
            checks.expectFalse(result.errors.isEmpty, "Accepted restore without floating classification")
            checks.expectTrue(result.config.compatibilityRules.isEmpty)
        }
        let app = parse(appRule.replacingOccurrences(
            of: "recover-pid = 'window-owner'",
            with: "recover-pid = 'window-owner', restore-minimized = 'on-workspace-focus'",
        ))
        checks.expectTrue(app.errors.contains { $0.message == "Unknown key" }, "\(app.errors)")
        checks.expectTrue(app.config.compatibilityRules.isEmpty)
    }

    func testMinimizedRestoreCannotBypassWindowIdentityRequirements() {
        let restoringRule = windowRule.replacingOccurrences(
            of: "classify = 'floating'",
            with: "classify = 'floating', restore-minimized = 'on-workspace-focus'",
        )
        for removed in ["executable-path = '/opt/game/wine', ", "window-title = ['Game'], ", "ax-role = 'AXWindow', ", "ax-subrole = 'AXUnknown', "] {
            let result = parse(restoringRule.replacingOccurrences(of: removed, with: ""))
            checks.expectFalse(result.errors.isEmpty, "Accepted restore after removing \(removed)")
            checks.expectTrue(result.config.compatibilityRules.isEmpty)
        }
    }

    func testOptionalWindowFieldsAndEmptyRuleList() {
        let minimal = """
        [[compatibility-rules]]
        id = 'identified-window'
        phase = 'window'
        match = { app-id = 'example.app', window-title = ['Main'], ax-role = 'AXWindow', ax-subrole = 'AXUnknown' }
        action = { classify = 'floating' }
        """
        checks.expectTrue(parse(minimal).errors.isEmpty)
        checks.expectTrue(parse("compatibility-rules = []").errors.isEmpty)
        checks.expectEqual(parse("").config.compatibilityRules, [])
    }

    func testHomePathsExpandButOtherRelativePathsAreRejected() {
        let result = parse(appRule.replacingOccurrences(of: "'/Applications/Launcher.app'", with: "'~/Applications/Launcher.app'"))
        checks.expectTrue(result.errors.isEmpty)
        checks.expectEqual(result.config.compatibilityRules.first?.match.bundlePath, NSHomeDirectory() + "/Applications/Launcher.app")
        let homeWindow = parse(windowRule.replacingOccurrences(of: "'/opt/game/wine'", with: "'~/Games/wine'"))
        checks.expectTrue(homeWindow.errors.isEmpty)
        checks.expectEqual(homeWindow.config.compatibilityRules.first?.match.executablePath, NSHomeDirectory() + "/Games/wine")
    }

    func testRejectsUnknownKeysAtEveryRuleTable() {
        for (original, replacement) in [
            ("phase = 'application'", "phase = 'application'\nunknown = true"),
            ("match = { app-id", "match = { mystery = true, app-id"),
            ("action = { recover-pid", "action = { mystery = true, recover-pid"),
        ] {
            let result = parse(appRule.replacingOccurrences(of: original, with: replacement))
            checks.expectTrue(result.errors.contains { $0.message == "Unknown key" }, "\(result.errors)")
            checks.expectTrue(result.config.compatibilityRules.isEmpty)
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
            checks.expectFalse(result.errors.isEmpty, rules)
            checks.expectTrue(result.config.compatibilityRules.isEmpty, rules)
        }
        checks.expectFalse(parse(appRule + "\n" + appRule).errors.isEmpty)
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
            checks.expectFalse(result.errors.isEmpty, "Accepted \(original) -> \(replacement)")
        }
        checks.expectFalse(parse("compatibility-rules = {}").errors.isEmpty)
        checks.expectFalse(parse("compatibility-rules = [1]").errors.isEmpty)
    }
}


@MainActor
final class CompatibilityReloadOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
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
        checks.expectTrue(current.errors.isEmpty)
        let changedLayout = parse("accordion-padding = 44\n" + appRule)
        checks.expectTrue(configReloadErrors(changedLayout, currentRules: current.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false).isEmpty)

        for candidate in [parse(""), parse(windowRule), parse(appRule + "\n" + windowRule)] {
            let errors = configReloadErrors(candidate, currentRules: current.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false)
            checks.expectEqual(errors.count, 1)
            checks.expectTrue(errors[0].message.contains("requires an AeroSpace restart"))
            checks.expectTrue(errors[0].preventConfigReload)
        }
        let ordered = parse(appRule + "\n" + windowRule)
        let reordered = parse(windowRule + "\n" + appRule)
        checks.expectFalse(configReloadErrors(reordered, currentRules: ordered.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false).isEmpty)
        checks.expectTrue(configReloadErrors(ordered, currentRules: [], rulesLocked: false, warningsAsErrors: false).isEmpty)
    }

    func testInvalidCandidateAndWarningsCannotPublishPartialConfig() {
        let currentRules = parse(appRule).config.compatibilityRules
        for candidate in [parse("accordion-padding = 'invalid'"), parse(windowRule.replacingOccurrences(of: "'floating'", with: "'invalid'"))] {
            checks.expectFalse(candidate.errors.isEmpty)
            let errors = configReloadErrors(candidate, currentRules: currentRules, rulesLocked: true, warningsAsErrors: false)
            checks.expectEqual(errors.count, candidate.errors.count)
            checks.expectFalse(errors.contains { $0.message.contains("requires an AeroSpace restart") })
        }
        let warning = parseConfig("config-version = 1")
        checks.expectTrue(warning.errors.isEmpty)
        checks.expectFalse(warning.warnings.isEmpty)
        checks.expectTrue(configReloadErrors(warning, currentRules: [], rulesLocked: true, warningsAsErrors: false).isEmpty)
        checks.expectFalse(configReloadErrors(warning, currentRules: [], rulesLocked: true, warningsAsErrors: true).isEmpty)
    }

    func testMinimizedRestoreChangeRequiresRestartAndLeavesOrdinaryReloadAvailable() {
        let oldRules = parse(windowRule)
        let restoringRule = windowRule.replacingOccurrences(
            of: "classify = 'floating'",
            with: "classify = 'floating', restore-minimized = 'on-workspace-focus'",
        )
        let restoring = parse(restoringRule)
        checks.expectTrue(restoring.errors.isEmpty)
        for (current, candidate) in [(oldRules, restoring), (restoring, oldRules)] {
            let errors = configReloadErrors(candidate, currentRules: current.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false)
            checks.expectEqual(errors.count, 1)
            checks.expectTrue(errors.first?.message.contains("requires an AeroSpace restart") == true)
            checks.expectTrue(errors.first?.preventConfigReload == true)
        }
        let changedLayout = parse("accordion-padding = 44\n" + restoringRule)
        checks.expectTrue(configReloadErrors(changedLayout, currentRules: restoring.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false).isEmpty)
        checks.expectTrue(configReloadErrors(restoring, currentRules: oldRules.config.compatibilityRules, rulesLocked: false, warningsAsErrors: false).isEmpty)
    }

    func testInvalidMinimizedRestoreCannotPublishPartialConfigOrMaskItsError() {
        let current = parse(windowRule)
        let invalid = parse("accordion-padding = 44\n" + windowRule.replacingOccurrences(
            of: "classify = 'floating'",
            with: "classify = 'floating', restore-minimized = true",
        ))
        checks.expectFalse(invalid.errors.isEmpty)
        let errors = configReloadErrors(invalid, currentRules: current.config.compatibilityRules, rulesLocked: true, warningsAsErrors: false)
        checks.expectEqual(errors, invalid.errors)
        checks.expectFalse(errors.contains { $0.message.contains("requires an AeroSpace restart") })
    }
}


@MainActor
final class WorkspaceRestoreOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
    func testDefaultAndNonFloatingWindowsNeverOptIn() {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: nil, floating: true)
        state.remember(windowID: 2, pid: 102, workspace: "A", ruleID: "precise-rule", floating: false)
        checks.expectTrue(state.entries.isEmpty)
        checks.expectNil(state.begin(workspace: "A", readOnly: false))
        checks.expectTrue(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: true, minimized: nil, nativeFullscreen: false))
        checks.expectFalse(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: false, minimized: nil, nativeFullscreen: false))
        checks.expectFalse(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: true, minimized: false, nativeFullscreen: false))
        checks.expectFalse(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: true, minimized: true, nativeFullscreen: false))
        checks.expectFalse(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: true, minimized: nil, nativeFullscreen: true))
    }

    func testOnlyExplicitSelectionStartsRestoreAndPreservesOrigin() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.noteFocused(1)
        state.remember(windowID: 1, pid: 101, workspace: "Origin", ruleID: "precise-rule", floating: true)
        checks.expectNil(state.request)
        checks.expectEqual(state.entries[1]?.workspace, "Origin")
        checks.expectNil(state.begin(workspace: "Other", readOnly: false))
        let request = try checks.require(state.begin(workspace: "Origin", readOnly: false))
        checks.expectEqual(request.entry.workspace, "Origin")
        checks.expectEqual(request.entry.ruleID, "precise-rule")
        checks.expectTrue(state.isCurrent(request, workspace: "Origin"))
        checks.expectFalse(state.isCurrent(request, workspace: "Other"))
    }

    func testMostRecentEligibleWindowWinsWithinRequestedWorkspace() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.noteFocused(2)
        state.noteFocused(1)
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        state.remember(windowID: 2, pid: 102, workspace: "A", ruleID: "two", floating: true)
        state.noteFocused(3)
        state.remember(windowID: 3, pid: 103, workspace: "B", ruleID: "three", floating: true)
        let request = try checks.require(state.begin(workspace: "A", readOnly: false))
        checks.expectEqual(request.entry.windowID, 1)
        checks.expectEqual(state.entries.count, 3)
    }

    func testReadOnlySelectionDoesNotStartOrCancelARequest() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        checks.expectNil(state.begin(workspace: "A", readOnly: true))
        checks.expectNil(state.request)
        let request = try checks.require(state.begin(workspace: "A", readOnly: false))
        checks.expectNil(state.begin(workspace: "B", readOnly: true))
        checks.expectEqual(state.request, request)
    }

    func testSameWorkspaceRetryIsExplicitAndSuccessIsNotRepeated() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        let first = try checks.require(state.begin(workspace: "A", readOnly: false))
        state.finish(first, outcome: .timeout)
        checks.expectNil(state.request)
        checks.expectEqual(state.entries[1]?.minimized, true)
        checks.expectEqual(state.outcomes[1], .timeout)
        let retry = try checks.require(state.begin(workspace: "A", readOnly: false))
        checks.expectFalse(state.isCurrent(first, workspace: "A"))
        checks.expectTrue(state.isCurrent(retry, workspace: "A"))
        state.finish(retry, outcome: .success)
        checks.expectEqual(state.entries[1]?.workspace, "A")
        checks.expectEqual(state.entries[1]?.minimized, false)
        checks.expectNil(state.begin(workspace: "A", readOnly: false))
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        checks.expectNotNil(state.begin(workspace: "A", readOnly: false))
    }

    func testLatestRequestCancelsOldAndStaleCompletionCannotWin() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        state.remember(windowID: 2, pid: 102, workspace: "B", ruleID: "two", floating: true)
        let old = try checks.require(state.begin(workspace: "A", readOnly: false))
        let latest = try checks.require(state.begin(workspace: "B", readOnly: false))
        checks.expectFalse(state.isCurrent(old, workspace: "A"))
        checks.expectEqual(state.outcomes[1], .cancelled)
        state.finish(old, outcome: .success)
        checks.expectEqual(state.request, latest)
        checks.expectEqual(state.entries[1]?.minimized, true)
        state.cancel()
        checks.expectFalse(state.isCurrent(latest, workspace: "B"))
        checks.expectEqual(state.outcomes[2], .cancelled)
    }

    func testFailedIdentityRetainsMinimizedOriginAndNoAutomaticRetry() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "Origin", ruleID: "one", floating: true)
        let request = try checks.require(state.begin(workspace: "Origin", readOnly: false))
        state.finish(request, outcome: .identityMismatch)
        checks.expectEqual(state.entries[1]?.minimized, true)
        checks.expectEqual(state.entries[1]?.workspace, "Origin")
        checks.expectEqual(state.outcomes[1], .identityMismatch)
        checks.expectNil(state.request)
    }

    func testDestroyedOrReusedWindowInvalidatesRequest() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        let request = try checks.require(state.begin(workspace: "A", readOnly: false))
        state.forget(1)
        checks.expectNil(state.request)
        checks.expectNil(state.entries[1])
        state.remember(windowID: 1, pid: 999, workspace: "A", ruleID: "new-process", floating: true)
        checks.expectFalse(state.isCurrent(request, workspace: "A"))
        let new = try checks.require(state.begin(workspace: "A", readOnly: false))
        checks.expectEqual(new.entry.pid, 999)
        checks.expectEqual(new.entry.ruleID, "new-process")
    }

    func testExternalRestoreSkipsRecentWindowWithoutInventingSuccess() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.noteFocused(1)
        state.noteFocused(2)
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        state.remember(windowID: 2, pid: 102, workspace: "A", ruleID: "two", floating: true)
        state.noteNotMinimized(2)
        checks.expectNil(state.outcomes[2])
        let older = try checks.require(state.begin(workspace: "A", readOnly: false))
        checks.expectEqual(older.entry.windowID, 1)
        state.finish(older, outcome: .timeout)
        state.remember(windowID: 2, pid: 102, workspace: "A", ruleID: "two", floating: true)
        let minimizedAgain = try checks.require(state.begin(workspace: "A", readOnly: false))
        checks.expectEqual(minimizedAgain.entry.windowID, 2)
        checks.expectEqual(state.entries[2]?.workspace, "A")
    }
}


@MainActor
final class WorkspaceRulesConfigOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
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
        checks.expectTrue(old.errors.isEmpty)
        checks.expectFalse(old.config.workspaceRulesEnabled)
        checks.expectTrue(old.config.workspaceRules.isEmpty)
        let result = parse("workspace-rules-enabled = true\n" + launcherRule + "\n" + gameRule)
        checks.expectTrue(result.errors.isEmpty, "\(result.errors)")
        checks.expectTrue(result.config.workspaceRulesEnabled)
        checks.expectEqual(result.config.workspaceRules.count, 2)
        guard result.config.workspaceRules.count == 2 else { return }
        let launcher = result.config.workspaceRules[0]
        checks.expectEqual(launcher.id, "launcher-home")
        checks.expectEqual(launcher.match.appId, "example.launcher")
        checks.expectEqual(launcher.workspace, "HOME")
        checks.expectEqual(launcher.policy, .enforce)
        let game = result.config.workspaceRules[1]
        checks.expectEqual(game.match.executablePath, "/opt/game/wine")
        checks.expectEqual(game.match.firstExeArgument, ["Game.exe"])
        checks.expectEqual(game.match.windowTitle, ["Game", "Localized Game"])
        checks.expectEqual(game.match.axRole, "AXWindow")
        checks.expectEqual(game.match.axSubrole, "AXUnknown")
        checks.expectEqual(game.match.appIdAbsent, true)
        checks.expectEqual(game.policy, .observe)
        checks.expectTrue(parse("workspace-rules = []").errors.isEmpty)
    }

    func testRequiredFieldsAndRuleIDsAreStrict() {
        for field in ["id = 'launcher-home'\n", "match = { app-id = 'example.launcher' }\n", "workspace = 'HOME'\n", "policy = 'enforce'"] {
            let result = parse(launcherRule.replacingOccurrences(of: field, with: ""))
            checks.expectFalse(result.errors.isEmpty, "Accepted missing \(field)")
            checks.expectTrue(result.config.workspaceRules.isEmpty)
        }
        let duplicate = parse(launcherRule + "\n" + launcherRule)
        checks.expectFalse(duplicate.errors.isEmpty)
        checks.expectTrue(duplicate.errors.contains { $0.message.contains("ids must be unique") })
        for value in ["''", "' '", "1", "false", "[]", "{}"] {
            let result = parse(launcherRule.replacingOccurrences(of: "id = 'launcher-home'", with: "id = \(value)"))
            checks.expectFalse(result.errors.isEmpty, "Accepted id \(value)")
            checks.expectTrue(result.config.workspaceRules.isEmpty)
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
            checks.expectFalse(result.errors.isEmpty, "Accepted \(to)")
            checks.expectTrue(result.config.workspaceRules.isEmpty)
        }
        for raw in ["workspace-rules = {}", "workspace-rules = [1]", "workspace-rules-enabled = 1", "workspace-rules-enabled = 'true'", "workspace-rules-enabled = []"] {
            checks.expectFalse(parse(raw).errors.isEmpty, "Accepted \(raw)")
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
            checks.expectFalse(result.errors.isEmpty, "Accepted match \(raw)")
            checks.expectTrue(result.config.workspaceRules.isEmpty)
        }
        let home = parse(gameRule.replacingOccurrences(of: "'/opt/game/wine'", with: "'~/Games/wine'"))
        checks.expectTrue(home.errors.isEmpty)
        checks.expectEqual(home.config.workspaceRules.first?.match.executablePath, NSHomeDirectory() + "/Games/wine")
        let paths = parse(launcherRule.replacingOccurrences(of: "app-id = 'example.launcher'", with: "app-id = 'example.launcher', bundle-path = '/Applications/Launcher.app', executable-path = '/Applications/Launcher.app/Contents/MacOS/Launcher'"))
        checks.expectTrue(paths.errors.isEmpty)
    }

    func testWorkspaceAndOptionalMatchFieldsAreStrict() {
        for value in ["''", "' '", "'next'", "'_reserved'", "'-option'", "'two words'", "'a,b'", "1", "false", "[]"] {
            let result = parse(launcherRule.replacingOccurrences(of: "workspace = 'HOME'", with: "workspace = \(value)"))
            checks.expectFalse(result.errors.isEmpty, "Accepted workspace \(value)")
        }
        for (from, to) in [
            ("window-title = ['Game', 'Localized Game']", "window-title = []"),
            ("window-title = ['Game', 'Localized Game']", "window-title = ['']"),
            ("window-title = ['Game', 'Localized Game']", "window-title = [1]"),
            ("ax-role = 'AXWindow'", "ax-role = false"),
            ("ax-subrole = 'AXUnknown'", "ax-subrole = []"),
            ("app-id-absent = true", "app-id-absent = 1"),
        ] {
            checks.expectFalse(parse(gameRule.replacingOccurrences(of: from, with: to)).errors.isEmpty, "Accepted \(to)")
        }
    }

    func testWorkspaceRuleUpdatesDoNotAcquireCompatibilityRestartLock() {
        let original = parse(launcherRule)
        let changed = parse("workspace-rules-enabled = true\n" + launcherRule.replacingOccurrences(of: "'HOME'", with: "'OTHER'"))
        checks.expectTrue(configReloadErrors(changed, currentRules: original.config.compatibilityRules, rulesLocked: true, warningsAsErrors: true).isEmpty)
        checks.expectEqual(changed.config.workspaceRules.first?.workspace, "OTHER")
        checks.expectTrue(changed.config.workspaceRulesEnabled)
    }
}


@MainActor
final class WorkspaceRuleEngineOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
    private func identity(appId: String? = "example.app", path: String? = "/opt/game/wine", guest: String? = "Game.exe", role: String? = "AXWindow", subrole: String? = "AXUnknown", title: String? = "Game") -> WorkspaceRuleWindowIdentity {
        .init(process: .init(appId: appId, bundlePath: "/Applications/Example.app", executablePath: path), firstExeArgument: guest, role: role, subrole: subrole, title: title)
    }

    func testExactAppIDAndFirstMatchingRuleWin() {
        let first = WorkspaceRule(id: "observe", match: .init(appId: "example.app"), workspace: "A", policy: .observe)
        let second = WorkspaceRule(id: "enforce", match: .init(appId: "example.app"), workspace: "B", policy: .enforce)
        checks.expectEqual(WorkspaceRuleEngine.firstMatch(rules: [first, second], identity: identity())?.id, "observe")
        checks.expectEqual(WorkspaceRuleEngine.firstMatch(rules: [second, first], identity: identity())?.workspace, "B")
        checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [first], identity: identity(appId: "example.other")))
        checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [first], identity: identity(appId: nil)))
        checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [], identity: identity()))
    }

    func testGuestIdentityIsExactAndCaseInsensitiveWithoutMatchingOtherGuests() {
        let rule = WorkspaceRule(id: "game", match: .init(executablePath: "/opt/game/wine", appIdAbsent: true, firstExeArgument: ["Game.exe"], windowTitle: ["Game"], axRole: "AXWindow", axSubrole: "AXUnknown"), workspace: "GAME", policy: .enforce)
        checks.expectNotNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil)))
        checks.expectNotNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, path: "/opt/game/../game/wine", guest: "C:\\Games\\GAME.EXE")))
        for guest in [nil, "Other.exe", "Game.exe.backup", "not-executable"] {
            checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, guest: guest)))
        }
        checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity()))
        checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, path: "/opt/other/wine")))
        checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, role: "AXSheet")))
        checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, subrole: nil)))
        checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [rule], identity: identity(appId: nil, title: "Other Game")))
    }

    func testBundlePathAndMissingFieldsDoNotBroadenIdentity() {
        let exact = WorkspaceRule(id: "exact", match: .init(appId: "example.app", bundlePath: "/Applications/Example.app", executablePath: "/opt/game/wine"), workspace: "A", policy: .enforce)
        checks.expectNotNil(WorkspaceRuleEngine.firstMatch(rules: [exact], identity: identity()))
        let otherBundle = WorkspaceRuleWindowIdentity(process: .init(appId: "example.app", bundlePath: "/Applications/Other.app", executablePath: "/opt/game/wine"), firstExeArgument: "Game.exe", role: "AXWindow", subrole: "AXUnknown", title: "Game")
        checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [exact], identity: otherBundle))
        for match in [WorkspaceRule.Match(), .init(windowTitle: ["Game"]), .init(executablePath: "/opt/game/wine"), .init(executablePath: "wine", firstExeArgument: ["Game.exe"]), .init(appId: "example.app", appIdAbsent: true)] {
            let malformed = WorkspaceRule(id: "bad", match: match, workspace: "A", policy: .enforce)
            checks.expectNil(WorkspaceRuleEngine.firstMatch(rules: [malformed], identity: identity()))
        }
    }
}


@MainActor
final class WorkspaceAffinityPolicyOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
    private func key(generation: UInt64 = 1, windowID: UInt32 = 1, pid: Int32 = 100, ruleID: String = "home", expected: String = "HOME", observed: String = "OTHER") -> WorkspaceAffinityStability.Key {
        .init(generation: generation, windowID: windowID, pid: pid, ruleID: ruleID, expected: expected, observed: observed)
    }

    func testStableMismatchNeedsARepeatedSettledObservation() {
        var gate = WorkspaceAffinityStability()
        checks.expectFalse(gate.observe(key: key(), now: 10))
        checks.expectFalse(gate.observe(key: key(), now: 10.249))
        checks.expectTrue(gate.observe(key: key(), now: 10.25))
        checks.expectTrue(gate.observe(key: key(), now: 10.3))
        gate.forget(windowID: 1)
        checks.expectFalse(gate.observe(key: key(), now: 11))
        gate.reset()
        checks.expectFalse(gate.observe(key: key(), now: 12))
    }

    func testChangedGenerationIdentityRuleOrWorkspaceStartsNewConfirmation() {
        for changed in [key(generation: 2), key(pid: 101), key(ruleID: "different"), key(expected: "NEW"), key(observed: "THIRD")] {
            var gate = WorkspaceAffinityStability()
            checks.expectFalse(gate.observe(key: key(), now: 0))
            checks.expectFalse(gate.observe(key: changed, now: 1))
            checks.expectTrue(gate.observe(key: changed, now: 1.25))
        }
        var gate = WorkspaceAffinityStability()
        checks.expectFalse(gate.observe(key: key(windowID: 1), now: 0))
        checks.expectFalse(gate.observe(key: key(windowID: 2), now: 1))
        checks.expectTrue(gate.observe(key: key(windowID: 1), now: 1))
    }

    func testClockRegressionAndInvalidTimeNeverImmediatelyConfirm() {
        var gate = WorkspaceAffinityStability()
        checks.expectFalse(gate.observe(key: key(), now: 10))
        checks.expectFalse(gate.observe(key: key(), now: 9))
        checks.expectFalse(gate.observe(key: key(), now: .infinity))
        checks.expectFalse(gate.observe(key: key(), now: .nan))
        checks.expectFalse(gate.observe(key: key(), now: 9.1))
        checks.expectTrue(gate.observe(key: key(), now: 9.25))
    }

    func testCorrectionConflictsBlockUntilExplicitResetOrDeath() {
        var budget = WorkspaceAffinityCorrectionBudget()
        checks.expectTrue(budget.allowAndRecord(windowID: 1, now: 0))
        checks.expectTrue(budget.allowAndRecord(windowID: 1, now: 1))
        checks.expectTrue(budget.allowAndRecord(windowID: 1, now: 2))
        checks.expectTrue(budget.isBlocked(windowID: 1))
        checks.expectFalse(budget.allowAndRecord(windowID: 1, now: 3))
        checks.expectFalse(budget.allowAndRecord(windowID: 1, now: 100))
        checks.expectTrue(budget.allowAndRecord(windowID: 2, now: 3))
        budget.reset(windowID: 1)
        checks.expectFalse(budget.isBlocked(windowID: 1))
        checks.expectTrue(budget.allowAndRecord(windowID: 1, now: 101))
        budget.prune(alive: [2])
        checks.expectTrue(budget.allowAndRecord(windowID: 1, now: 102))
    }

    func testSpreadOutCorrectionsExpireButBackwardsTimeCannotBypassBudget() {
        var budget = WorkspaceAffinityCorrectionBudget()
        checks.expectTrue(budget.allowAndRecord(windowID: 1, now: 0))
        checks.expectTrue(budget.allowAndRecord(windowID: 1, now: 31))
        checks.expectFalse(budget.allowAndRecord(windowID: 1, now: 30))
        checks.expectTrue(budget.allowAndRecord(windowID: 1, now: 62))
        checks.expectTrue(budget.allowAndRecord(windowID: 1, now: 93))
        checks.expectFalse(budget.isBlocked(windowID: 1))
        checks.expectFalse(budget.allowAndRecord(windowID: 2, now: .nan))
        checks.expectFalse(budget.allowAndRecord(windowID: 2, now: .infinity))
    }
}


@MainActor
final class WorkspaceAffinityRuntimeOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
    func testNativeFocusFallbackOnlyUsesCapturedPositivePIDAfterSystemWideFailure() {
        checks.expectEqual(WorkspaceAffinityNativeFocusPolicy.fallbackPID(systemWidePID: nil, capturedFrontmostPID: 81651), 81651)
        checks.expectEqual(WorkspaceAffinityNativeFocusPolicy.fallbackPID(systemWidePID: 0, capturedFrontmostPID: 81651), 81651)
        checks.expectNil(WorkspaceAffinityNativeFocusPolicy.fallbackPID(systemWidePID: 42, capturedFrontmostPID: 81651))
        checks.expectNil(WorkspaceAffinityNativeFocusPolicy.fallbackPID(systemWidePID: nil, capturedFrontmostPID: nil))
        checks.expectNil(WorkspaceAffinityNativeFocusPolicy.fallbackPID(systemWidePID: nil, capturedFrontmostPID: -1))
        checks.expectNil(WorkspaceAffinityNativeFocusPolicy.fallbackPID(systemWidePID: nil, capturedFrontmostPID: 0))
    }

    func testNativeFocusFallbackLosesPermissionWhenForegroundChangesDuringAXRead() {
        checks.expectTrue(WorkspaceAffinityNativeFocusPolicy.isCurrent(capturedFrontmostPID: 81651, currentFrontmostPID: 81651, snapshotPID: 81651))
        checks.expectFalse(WorkspaceAffinityNativeFocusPolicy.isCurrent(capturedFrontmostPID: 81651, currentFrontmostPID: 7445, snapshotPID: 81651))
        checks.expectFalse(WorkspaceAffinityNativeFocusPolicy.isCurrent(capturedFrontmostPID: 81651, currentFrontmostPID: 81651, snapshotPID: 7445))
        checks.expectFalse(WorkspaceAffinityNativeFocusPolicy.isCurrent(capturedFrontmostPID: nil, currentFrontmostPID: 81651, snapshotPID: 81651))
        checks.expectFalse(WorkspaceAffinityNativeFocusPolicy.isCurrent(capturedFrontmostPID: 81651, currentFrontmostPID: nil, snapshotPID: 81651))
        checks.expectFalse(WorkspaceAffinityNativeFocusPolicy.isCurrent(capturedFrontmostPID: -1, currentFrontmostPID: -1, snapshotPID: -1))
    }

    func testQueuedFrameDequeuedAfterFenceInvalidationNeverStarts() {
        let fence = WorkspaceAffinityFrameFence()
        let job = RunLoopJob(.cancellable)
        fence.invalidate()
        checks.expectFalse(fence.register(job))
        checks.expectTrue(job.isCancelled)
        var writes = 0
        if !job.isCancelled { writes += 1 }
        checks.expectEqual(writes, 0)
    }

    func testNewSessionFenceCancelsOnlyItsAlreadyDequeuedFrameJobs() {
        let fence = WorkspaceAffinityFrameFence()
        let position = RunLoopJob(.cancellable)
        let size = RunLoopJob(.cancellable)
        let ordinaryLayout = RunLoopJob(.cancellable)
        checks.expectTrue(fence.register(position))
        checks.expectTrue(fence.register(size))
        checks.expectFalse(position.isCancelled)
        fence.invalidate()
        checks.expectTrue(position.isCancelled)
        checks.expectTrue(size.isCancelled)
        checks.expectFalse(ordinaryLayout.isCancelled)
        // Idempotent invalidation does not reach unrelated native jobs.
        fence.invalidate()
        checks.expectFalse(ordinaryLayout.isCancelled)
    }

    func testFenceStaysValidAfterEnqueueUntilSupersededAndForgetsCompletedJobs() {
        let fence = WorkspaceAffinityFrameFence()
        let completed = RunLoopJob(.cancellable)
        checks.expectTrue(fence.register(completed))
        fence.unregister(completed)
        let queuedLater = RunLoopJob(.cancellable)
        checks.expectTrue(fence.register(queuedLater))
        checks.expectFalse(queuedLater.isCancelled)
        fence.invalidate()
        checks.expectFalse(completed.isCancelled)
        checks.expectTrue(queuedLater.isCancelled)
    }

    func testChangedOldPassCannotLayoutAfterNewSessionInterruptsNativeRead() {
        var gate = WorkspaceAffinitySessionGate()
        let oldPass = gate.begin()
        let changedEarlierWindow = true
        checks.expectTrue(gate.allowsLayout(oldPass, activeDepth: 1, independent: true, cancelled: false))

        // The old pass changed A and then suspended while reading B. A newer
        // session is now temporarily rebuilding the model at nested depth.
        let newSession = gate.begin()
        checks.expectFalse(changedEarlierWindow && gate.allowsLayout(oldPass, activeDepth: 2, independent: true, cancelled: false))
        // Returning to exclusive depth does not make the old token current.
        checks.expectFalse(gate.allowsLayout(oldPass, activeDepth: 1, independent: true, cancelled: false))
        checks.expectTrue(gate.allowsLayout(newSession, activeDepth: 1, independent: true, cancelled: false))
    }

    func testLatestUserSessionKeepsLayoutPermissionWhileOldPassUnwinds() {
        var gate = WorkspaceAffinitySessionGate()
        _ = gate.begin()
        let latestUserSession = gate.begin()
        // New automatic enforcement must wait, but a priority user command's
        // ordinary layout must not disappear while the canceled task unwinds.
        checks.expectFalse(gate.allowsLayout(latestUserSession, activeDepth: 2, independent: true, cancelled: false))
        checks.expectTrue(gate.allowsLayout(latestUserSession, activeDepth: 2, independent: false, cancelled: false))
        checks.expectFalse(gate.allowsLayout(latestUserSession, activeDepth: 1, independent: false, cancelled: true))
    }

    func testIndependentFrameContinuationRejectsEveryPostAwaitStaleWrite() {
        var gate = WorkspaceAffinitySessionGate()
        let token = gate.begin()
        var writes = 0
        let canContinue = { gate.allowsLayout(token, activeDepth: 1, independent: true, cancelled: false) }
        if canContinue() { writes += 1 }
        // Models a newer session beginning during an awaited native frame read.
        _ = gate.begin()
        if canContinue() { writes += 1 }
        if canContinue() { writes += 1 }
        checks.expectEqual(writes, 1)
    }

    func testExplicitInvalidationCancelsEvenAnOtherwiseExclusivePass() {
        var gate = WorkspaceAffinitySessionGate()
        let token = gate.begin()
        gate.invalidate()
        checks.expectFalse(gate.allowsLayout(token, activeDepth: 1, independent: true, cancelled: false))
    }

    func testEveryQueryEntryStaysObservationOnly() throws {
        let queries: [[String]] = [
            ["list-windows", "--all"], ["list-workspaces", "--all"],
            ["list-apps"], ["list-monitors"], ["config", "--config-path"],
            ["debug-windows", "--window-id", "123"],
            ["workspace-rule", "status"], ["workspace-rule", "status", "--window-id", "123", "--json"],
            ["reload-config", "--dry-run", "--no-gui"],
            ["eval", "list-windows --all"],
        ]
        for raw in queries {
            let args = try checks.require(parseCmdArgs(raw.slice).cmdOrNil)
            checks.expectFalse(WorkspaceAffinity.eventAllowsCorrection(.socketServer(args)), raw.joined(separator: " "))
        }
        checks.expectFalse(WorkspaceAffinity.eventAllowsCorrection(.hotkeyBinding))
        checks.expectFalse(WorkspaceAffinity.eventAllowsCorrection(.menuBarButton))
    }

    func testExplicitMutationsAndIndependentEventsCanObserveOwnership() throws {
        let mutations: [[String]] = [
            ["move-node-to-workspace", "--window-id", "123", "Home"],
            ["workspace", "Home"], ["reload-config", "--no-gui"],
            ["workspace-rule", "pause", "--window-id", "123"],
            ["workspace-rule", "resume"],
        ]
        for raw in mutations {
            let args = try checks.require(parseCmdArgs(raw.slice).cmdOrNil)
            checks.expectTrue(WorkspaceAffinity.eventAllowsCorrection(.socketServer(args)), raw.joined(separator: " "))
        }
        checks.expectTrue(WorkspaceAffinity.eventAllowsCorrection(.ax("AXWindowCreated")))
        checks.expectTrue(WorkspaceAffinity.eventAllowsCorrection(.globalObserver("workspace-affinity")))
    }

    func testWorkspaceRuleCommandHasExplicitControlAndReadOnlyStatus() throws {
        let status = try checks.require(parseCmdArgs(["workspace-rule", "status"].slice).cmdOrNil as? WorkspaceRuleCmdArgs)
        checks.expectEqual(status.action.val, .status)
        checks.expectNil(status.windowId)
        let pause = try checks.require(parseCmdArgs(["workspace-rule", "pause", "--window-id", "987"].slice).cmdOrNil as? WorkspaceRuleCmdArgs)
        checks.expectEqual(pause.action.val, .pause)
        checks.expectEqual(pause.windowId, 987)
        checks.expectNil(parseCmdArgs(["workspace-rule", "force"].slice).cmdOrNil)
        checks.expectNil(parseCmdArgs(["workspace-rule", "pause", "--window-id", "invalid"].slice).cmdOrNil)
    }
}


@MainActor
final class WorkspaceJournalStoreOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
    func testWritesMetadataAsJSONLinesWithPrivatePermissions() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = WorkspaceJournalStore(options: .init(root: root), clock: { now })
        checks.expectTrue(store.enqueue(.init(timestamp: now, sequence: 1, kind: "window-moved",
            transactionID: "test-transaction", source: "external-command", command: "move-node-to-workspace",
            reason: "terminal-snapshot", windowID: 9, pid: 22, ruleID: "hsr-home",
            oldWorkspace: "6", newWorkspace: "HSR")))
        checks.expectTrue(store.enqueue(.init(timestamp: now, sequence: 2, kind: "correction-success", windowID: 9)))
        store.flushForTesting()
        let events = try records(root)
        checks.expectEqual(events.count, 2)
        checks.expectEqual(events.first?.oldWorkspace, "6")
        checks.expectEqual(events.first?.newWorkspace, "HSR")
        checks.expectEqual(events.first?.command, "move-node-to-workspace")
        checks.expectEqual(store.status.writtenRecords, 2)
        checks.expectEqual(store.status.pendingRecords, 0)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        checks.expectEqual(permissions?.intValue, 0o600)
    }

    func testRotationAndTotalBudgetKeepNewestRecords() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = WorkspaceJournalEvent(timestamp: now, sequence: 1, kind: "test", source: "unknown")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(sample).count + 1
        let store = WorkspaceJournalStore(options: .init(root: root, maxTotalBytes: bytes * 3,
            maxFileBytes: bytes + 8), clock: { now })
        for i in 1...8 {
            var event = sample
            event.sequence = UInt64(i)
            checks.expectTrue(store.enqueue(event))
            store.flushForTesting()
        }
        let events = try records(root)
        checks.expectTrue(events.count <= 3)
        checks.expectTrue(events.contains { $0.sequence == 8 })
        checks.expectFalse(events.contains { $0.sequence == 1 })
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        checks.expectTrue(total <= bytes * 3)
    }

    func testRetentionRemovesOnlyOwnedOldRegularFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = root.appendingPathComponent("workspace-old.jsonl")
        let unrelated = root.appendingPathComponent("unrelated.jsonl")
        try Data("old\n".utf8).write(to: old)
        try Data("keep\n".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: unrelated.path)
        let store = WorkspaceJournalStore(options: .init(root: root, retention: 20), clock: { now })
        checks.expectTrue(store.enqueue(.init(timestamp: now, kind: "test")))
        store.flushForTesting()
        checks.expectFalse(FileManager.default.fileExists(atPath: old.path))
        checks.expectTrue(FileManager.default.fileExists(atPath: unrelated.path))
        checks.expectEqual(store.status.writtenRecords, 1)
    }

    func testQueueAndRecordBoundsDropWithoutBlockingOrThrowing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disabledQueue = WorkspaceJournalStore(options: .init(root: root, maxPendingRecords: 0))
        checks.expectFalse(disabledQueue.enqueue(.init(kind: "test")))
        checks.expectEqual(disabledQueue.status.droppedRecords, 1)
        checks.expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace-never.jsonl").path))
        let tinyBudget = WorkspaceJournalStore(options: .init(root: root, maxTotalBytes: 10, maxFileBytes: 10))
        checks.expectFalse(tinyBudget.enqueue(.init(kind: "larger-than-ten-bytes")))
        checks.expectEqual(tinyBudget.status.droppedRecords, 1)
    }

    func testUnwritableDestinationCountsFailureWithoutThrowing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("regular-file")
        try Data().write(to: file)
        let store = WorkspaceJournalStore(options: .init(root: file))
        checks.expectTrue(store.enqueue(.init(kind: "test")))
        store.flushForTesting()
        checks.expectEqual(store.status.writeFailures, 1)
        checks.expectEqual(store.status.pendingRecords, 0)
    }

    func testFixedSchemaAndBoundedStringsExcludeContentFields() throws {
        let event = WorkspaceJournalEvent(kind: String(repeating: "k", count: 2_000), source: "external-command",
            command: "exec-and-forget", windowID: 2, pid: 3)
        let data = try JSONEncoder().encode(event)
        let object = try checks.require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        checks.expectEqual((object["kind"] as? String)?.count, 160)
        checks.expectNil(object["windowTitle"])
        checks.expectNil(object["body"])
        checks.expectNil(object["argv"])
        checks.expectNil(object["stdin"])
        checks.expectNil(object["clipboard"])
        checks.expectNil(object["environment"])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aerospace-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func records(_ root: URL) throws -> [WorkspaceJournalEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("workspace-") && $0.pathExtension == "jsonl" }
        return try files.flatMap { url in
            try Data(contentsOf: url).split(separator: 0x0a).map { try decoder.decode(WorkspaceJournalEvent.self, from: Data($0)) }
        }.sorted { $0.sequence < $1.sequence }
    }
}


@MainActor
final class WorkspaceJournalSnapshotOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
    func testTerminalDiffCatchesIndirectContainerMoves() {
        let before: [UInt32: WorkspaceJournalWindowState] = [1: state(1, workspace: "6"), 2: state(2, workspace: "6")]
        let after: [UInt32: WorkspaceJournalWindowState] = [1: state(1, workspace: "HSR"), 2: state(2, workspace: "HSR")]
        let changes = WorkspaceJournalTransition.diff(before: before, after: after)
        checks.expectEqual(changes.count, 2)
        checks.expectTrue(changes.allSatisfy { $0.kind == .moved })
        checks.expectTrue(changes.allSatisfy { $0.before?.workspace == "6" && $0.after?.workspace == "HSR" })
    }

    func testTemporaryRebindingWithSameTerminalStateHasNoDrift() {
        let before: [UInt32: WorkspaceJournalWindowState] = [1: state(1, workspace: "HSR")]
        let intermediate: [UInt32: WorkspaceJournalWindowState] = [1: state(1, workspace: "6")]
        checks.expectEqual(WorkspaceJournalTransition.diff(before: before, after: intermediate).count, 1)
        checks.expectTrue(WorkspaceJournalTransition.diff(before: before, after: before).isEmpty)
    }

    func testNewDestroyedAndReusedWindowIdentitiesAreDistinct() {
        let old = state(1, pid: 10, workspace: "A")
        let reused = state(1, pid: 11, workspace: "A")
        checks.expectEqual(WorkspaceJournalTransition.diff(before: [:], after: [1: old]).first?.kind, .appeared)
        checks.expectEqual(WorkspaceJournalTransition.diff(before: [1: old], after: [:]).first?.kind, .disappeared)
        checks.expectEqual(WorkspaceJournalTransition.diff(before: [1: old], after: [1: reused]).first?.kind, .identityReplaced)
        let restarted = state(1, pid: 10, start: 200, workspace: "A")
        checks.expectEqual(WorkspaceJournalTransition.diff(before: [1: old], after: [1: restarted]).first?.kind, .identityReplaced)
    }

    func testParentChangeWithinWorkspaceIsNotWorkspaceMove() {
        let before = state(1, workspace: "A", parent: "FloatingWindowsContainer")
        let after = state(1, workspace: "A", parent: "TilingContainer")
        let change = WorkspaceJournalTransition.diff(before: [1: before], after: [1: after]).first
        checks.expectEqual(change?.kind, .reparented)
        checks.expectEqual(change?.before?.workspace, change?.after?.workspace)
    }

    func testWorkspaceMoveCauseSurvivesInterleavedParentOnlyRebinds() {
        var tracker = WorkspaceJournalProvenanceTracker<String>()
        let original = state(1, workspace: "HSR")
        let moved = state(1, workspace: "6")
        let tiling = state(1, workspace: "6", parent: "TilingContainer")
        let transactionAStart = tracker.revision
        tracker.record(transition(original, moved), cause: "transaction-A-move")
        // A yields. B performs a legal focus helper round trip inside workspace6.
        tracker.record(transition(moved, tiling), cause: "transaction-B-focus")
        tracker.record(transition(tiling, moved), cause: "transaction-B-focus")
        checks.expectEqual(tracker.cause(for: transition(original, moved), since: transactionAStart), "transaction-A-move")
        checks.expectFalse(tracker.cause(for: transition(original, moved), since: transactionAStart) == "transaction-B-focus")
    }

    func testProvenanceRequiresCompleteWorkspacePairAndFreshRevision() {
        var tracker = WorkspaceJournalProvenanceTracker<String>()
        let home = state(1, workspace: "HSR")
        let middle = state(1, workspace: "6")
        let final = state(1, workspace: "ZZZ")
        let beginning = tracker.revision
        tracker.record(transition(home, middle), cause: "A")
        tracker.record(transition(middle, final), cause: "B")
        // A terminal HSR→ZZZ delta cannot be attributed to B's 6→ZZZ hop.
        checks.expectNil(tracker.cause(for: transition(home, final), since: beginning))
        checks.expectEqual(tracker.cause(for: transition(middle, final), since: beginning), "B")
        let afterMove = tracker.revision
        checks.expectNil(tracker.cause(for: transition(middle, final), since: afterMove))
    }

    func testProvenanceRejectsReusedIdentityAndForgetsRemovedWindows() {
        var tracker = WorkspaceJournalProvenanceTracker<String>()
        let home = state(1, workspace: "HSR")
        let moved = state(1, workspace: "6")
        tracker.record(transition(home, moved), cause: "old-process")
        let newHome = state(1, pid: 99, start: 200, workspace: "HSR")
        let newMoved = state(1, pid: 99, start: 200, workspace: "6")
        checks.expectNil(tracker.cause(for: transition(newHome, newMoved), since: 0))
        tracker.retainWindowIDs([])
        checks.expectNil(tracker.cause(for: transition(home, moved), since: 0))
    }

    func testEndedInheritedTransactionIsNotReusedByConfirmationSession() {
        var registry = WorkspaceJournalTransactionRegistry()
        registry.begin("move-command")
        checks.expectTrue(registry.mayReuse("move-command", forceNew: false))
        registry.end("move-command")
        // Task.init can still inherit this value after the parent logged end.
        checks.expectFalse(registry.mayReuse("move-command", forceNew: false))
        checks.expectFalse(registry.mayReuse("move-command", forceNew: true))
        registry.begin("confirmation")
        checks.expectTrue(registry.mayReuse("confirmation", forceNew: false))
        checks.expectFalse(registry.mayReuse("move-command", forceNew: false))
        registry.end("confirmation")
        checks.expectFalse(registry.mayReuse("confirmation", forceNew: false))
    }

    func testIndependentEntryAlwaysStartsNewWhileInternalHelpersReuseCurrent() {
        var registry = WorkspaceJournalTransactionRegistry()
        registry.begin("light-session")
        // A scheduled heavy refresh can start while its parent is still active.
        checks.expectFalse(registry.mayReuse("light-session", forceNew: true))
        registry.begin("heavy-session")
        checks.expectTrue(registry.mayReuse("heavy-session", forceNew: false))
        registry.end("light-session")
        // Ending the parent cannot close or steal the child's transaction.
        checks.expectTrue(registry.mayReuse("heavy-session", forceNew: false))
        registry.end("heavy-session")
        checks.expectFalse(registry.mayReuse("heavy-session", forceNew: false))
        checks.expectFalse(registry.mayReuse(nil, forceNew: false))
    }

    @MainActor
    func testConfigSourceFingerprintIncludesNonAffinityConfiguration() {
        let tiles = parseConfig("default-root-container-layout = 'tiles'").config.sourceFingerprint
        let accordion = parseConfig("default-root-container-layout = 'accordion'").config.sourceFingerprint
        let repeated = parseConfig("default-root-container-layout = 'tiles'").config.sourceFingerprint
        checks.expectEqual(tiles.count, 64)
        checks.expectEqual(tiles, repeated)
        checks.expectFalse(tiles == accordion)
    }

    private func transition(_ before: WorkspaceJournalWindowState, _ after: WorkspaceJournalWindowState) -> WorkspaceJournalTransition {
        .init(kind: before.workspace == after.workspace ? .reparented : .moved, before: before, after: after)
    }

    private func state(_ id: UInt32, pid: Int32 = 10, start: Double = 100,
                       workspace: String, parent: String = "FloatingWindowsContainer") -> WorkspaceJournalWindowState {
        .init(windowID: id, pid: pid, processStart: start, appID: "test.app", workspace: workspace, parent: parent)
    }
}


extension [String: Json]: AxUiElementMock {
    public func get<Attr>(_ attr: Attr) -> Attr.T? where Attr: ReadableAttr {
        guard let value = self[attr.key] else {
            return isSynthetic ? dieT("\(self) doesn't contain \(attr.key)") : nil
        }
        if attr.key == kAXFocusedWindowAttribute {
            guard let object = fixtureAxObject(value), let id = object["Aero.axWindowId"]?.asInt64OrNil,
                  let windowId = UInt32(exactly: id) else { return nil }
            let focused: WindowIdAndAxUiElementMock = (windowId, object)
            return focused as? Attr.T
        }
        if [kAXCloseButtonAttribute, kAXFullScreenButtonAttribute, kAXZoomButtonAttribute, kAXMinimizeButtonAttribute].contains(attr.key) {
            return fixtureAxObject(value) as? Attr.T
        }
        if let value = value.rawValue {
            return attr.getter(value as AnyObject)
                ?? dieT("Value \(value) (of type \(Swift.type(of: value))) isn't convertible to \(attr.key)")
        } else {
            return nil
        }
    }

    private var isSynthetic: Bool { self[kAXAeroSynthetic] != nil }

    public func containingWindowId() -> CGWindowID? { _containingWindowId() }

    private func _containingWindowId() -> CGWindowID {
        let windowId = self["Aero.axWindowId"]?.asInt64OrNil ?? dieT()
        return UInt32.init(exactly: windowId).orDie()
    }
}

extension NSApplication.ActivationPolicy {
    static func from(string: String) -> NSApplication.ActivationPolicy {
        switch string {
            case "regular": .regular
            case "accessory": .accessory
            case "prohibited": .prohibited
            default: dieT("Unknown ActivationPolicy \(string)")
        }
    }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

// Equivalent to the upstream castToAxUiElementMock fixture branch, without
// invoking native AX calls or depending on XCTest's runtime class registration.
private func fixtureAxObject(_ value: Json) -> [String: Json]? {
    if case .null = value { return nil }
    if let object = value.asDictOrNil { return object }
    if let text = value.rawValue as? String, let comma = text.firstIndex(of: ","),
       let id = UInt32(String(text[..<comma]).removePrefix("AXUIElement(AxWindowId=")) {
        return ["Aero.axWindowId": .int(id), kAXAeroSynthetic: .bool(true)]
    }
    fatalError("Unsupported fixture AX object: \(value)")
}


MainActor.assumeIsolated {
if let index = CommandLine.arguments.firstIndex(of: "--validate-config") {
    guard index + 1 < CommandLine.arguments.count else { exit(2) }
    do {
        let source = try String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8)
        let parsed = parseConfig(source)
        let diagnostics = parsed.errors.map { $0.description(.error) } + parsed.warnings.map { $0.description(.warning) }
        for diagnostic in diagnostics { print(diagnostic) }
        print("Config validation: \(parsed.errors.count) errors, \(parsed.warnings.count) warnings; workspace rules: \(parsed.config.workspaceRules.count)")
        exit(diagnostics.isEmpty ? 0 : 1)
    } catch { print("Config validation failed: \(error)"); exit(1) }
}
let checks = CheckRunner()
let engineCases = CompatibilityOfflineCases(checks)
let configCases = CompatibilityConfigOfflineCases(checks)
let reloadCases = CompatibilityReloadOfflineCases(checks)
let restoreCases = WorkspaceRestoreOfflineCases(checks)
let workspaceConfigCases = WorkspaceRulesConfigOfflineCases(checks)
let workspaceEngineCases = WorkspaceRuleEngineOfflineCases(checks)
let workspacePolicyCases = WorkspaceAffinityPolicyOfflineCases(checks)
let workspaceRuntimeCases = WorkspaceAffinityRuntimeOfflineCases(checks)
let workspaceJournalCases = WorkspaceJournalStoreOfflineCases(checks)
let workspaceSnapshotCases = WorkspaceJournalSnapshotOfflineCases(checks)
checks.run("testNativePositivePIDBypassesRecoveryAndNoRulesRejectInvalidPID") { engineCases.testNativePositivePIDBypassesRecoveryAndNoRulesRejectInvalidPID() }
checks.run("testPIDRecoveryUsesExactConfiguredIdentityAndUniqueOwner") { engineCases.testPIDRecoveryUsesExactConfiguredIdentityAndUniqueOwner() }
checks.run("testRecoveryNeverBroadensMissingOrMismatchedMetadata") { engineCases.testRecoveryNeverBroadensMissingOrMismatchedMetadata() }
checks.run("testFirstExecutableArgumentIsGenericExactAndCaseInsensitive") { engineCases.testFirstExecutableArgumentIsGenericExactAndCaseInsensitive() }
checks.run("testProcessPrefilterReadsArgumentsOnlyOnceAndNeverForUnmatchedRules") { engineCases.testProcessPrefilterReadsArgumentsOnlyOnceAndNeverForUnmatchedRules() }
checks.run("testWindowRuleCanUseExactAppIDWithoutExecutablePath") { engineCases.testWindowRuleCanUseExactAppIDWithoutExecutablePath() }
checks.run("testMatchingWindowsStayFloatingAcrossFocusAndLevelChanges") { engineCases.testMatchingWindowsStayFloatingAcrossFocusAndLevelChanges() }
checks.run("testFloatingActionOverridesOrdinaryNonDialogWindowAndNoMatchPreservesDefault") { engineCases.testFloatingActionOverridesOrdinaryNonDialogWindowAndNoMatchPreservesDefault() }
checks.run("testWindowTraitsRejectAuxiliaryAndUnverifiedWindows") { engineCases.testWindowTraitsRejectAuxiliaryAndUnverifiedWindows() }
checks.run("testRuleOrderSelectsTheFirstMatchingWindowID") { engineCases.testRuleOrderSelectsTheFirstMatchingWindowID() }
checks.run("testEmptyCompatibilityRulesDoNotReadExtraAXAttributes") { engineCases.testEmptyCompatibilityRulesDoNotReadExtraAXAttributes() }
checks.run("testMalformedWindowRulesFallBackToDefaultHeuristics") { engineCases.testMalformedWindowRulesFallBackToDefaultHeuristics() }
checks.run("testArgumentParserStopsBeforeEnvironmentAndRejectsTruncation") { engineCases.testArgumentParserStopsBeforeEnvironmentAndRejectsTruncation() }
checks.run("testFilesystemIdentityIgnoresDirectoryURLHintAndTrailingSlash") { engineCases.testFilesystemIdentityIgnoresDirectoryURLHintAndTrailingSlash() }
checks.run("testValidRuleTypesAndExactValues") { configCases.testValidRuleTypesAndExactValues() }
checks.run("testWorkspaceFocusMinimizedRestoreIsOptInAndKeepsExactMatch") { configCases.testWorkspaceFocusMinimizedRestoreIsOptInAndKeepsExactMatch() }
checks.run("testMinimizedRestoreRejectsUnknownValuesTypesAndMissingClassification") { configCases.testMinimizedRestoreRejectsUnknownValuesTypesAndMissingClassification() }
checks.run("testMinimizedRestoreCannotBypassWindowIdentityRequirements") { configCases.testMinimizedRestoreCannotBypassWindowIdentityRequirements() }
checks.run("testOptionalWindowFieldsAndEmptyRuleList") { configCases.testOptionalWindowFieldsAndEmptyRuleList() }
checks.run("testHomePathsExpandButOtherRelativePathsAreRejected") { configCases.testHomePathsExpandButOtherRelativePathsAreRejected() }
checks.run("testRejectsUnknownKeysAtEveryRuleTable") { configCases.testRejectsUnknownKeysAtEveryRuleTable() }
checks.run("testApplicationIdentityAndPhaseAreStrict") { configCases.testApplicationIdentityAndPhaseAreStrict() }
checks.run("testWindowMatchAndActionsAreStrict") { configCases.testWindowMatchAndActionsAreStrict() }
checks.run("testRuntimeRuleChangeRequiresRestartButOrdinaryReloadIsAllowed") { reloadCases.testRuntimeRuleChangeRequiresRestartButOrdinaryReloadIsAllowed() }
checks.run("testInvalidCandidateAndWarningsCannotPublishPartialConfig") { reloadCases.testInvalidCandidateAndWarningsCannotPublishPartialConfig() }
checks.run("testMinimizedRestoreChangeRequiresRestartAndLeavesOrdinaryReloadAvailable") { reloadCases.testMinimizedRestoreChangeRequiresRestartAndLeavesOrdinaryReloadAvailable() }
checks.run("testInvalidMinimizedRestoreCannotPublishPartialConfigOrMaskItsError") { reloadCases.testInvalidMinimizedRestoreCannotPublishPartialConfigOrMaskItsError() }
checks.run("testDefaultAndNonFloatingWindowsNeverOptIn") { restoreCases.testDefaultAndNonFloatingWindowsNeverOptIn() }
checks.run("testOnlyExplicitSelectionStartsRestoreAndPreservesOrigin") { try restoreCases.testOnlyExplicitSelectionStartsRestoreAndPreservesOrigin() }
checks.run("testMostRecentEligibleWindowWinsWithinRequestedWorkspace") { try restoreCases.testMostRecentEligibleWindowWinsWithinRequestedWorkspace() }
checks.run("testReadOnlySelectionDoesNotStartOrCancelARequest") { try restoreCases.testReadOnlySelectionDoesNotStartOrCancelARequest() }
checks.run("testSameWorkspaceRetryIsExplicitAndSuccessIsNotRepeated") { try restoreCases.testSameWorkspaceRetryIsExplicitAndSuccessIsNotRepeated() }
checks.run("testLatestRequestCancelsOldAndStaleCompletionCannotWin") { try restoreCases.testLatestRequestCancelsOldAndStaleCompletionCannotWin() }
checks.run("testFailedIdentityRetainsMinimizedOriginAndNoAutomaticRetry") { try restoreCases.testFailedIdentityRetainsMinimizedOriginAndNoAutomaticRetry() }
checks.run("testDestroyedOrReusedWindowInvalidatesRequest") { try restoreCases.testDestroyedOrReusedWindowInvalidatesRequest() }
checks.run("testExternalRestoreSkipsRecentWindowWithoutInventingSuccess") { try restoreCases.testExternalRestoreSkipsRecentWindowWithoutInventingSuccess() }
checks.run("testOldConfigurationIsDisabledAndRulesAreExplicit") { workspaceConfigCases.testOldConfigurationIsDisabledAndRulesAreExplicit() }
checks.run("testRequiredFieldsAndRuleIDsAreStrict") { workspaceConfigCases.testRequiredFieldsAndRuleIDsAreStrict() }
checks.run("testUnknownKeysTypesAndPoliciesAreRejected") { workspaceConfigCases.testUnknownKeysTypesAndPoliciesAreRejected() }
checks.run("testOnlyExactIdentityAnchorsAreAccepted") { workspaceConfigCases.testOnlyExactIdentityAnchorsAreAccepted() }
checks.run("testWorkspaceAndOptionalMatchFieldsAreStrict") { workspaceConfigCases.testWorkspaceAndOptionalMatchFieldsAreStrict() }
checks.run("testWorkspaceRuleUpdatesDoNotAcquireCompatibilityRestartLock") { workspaceConfigCases.testWorkspaceRuleUpdatesDoNotAcquireCompatibilityRestartLock() }
checks.run("testExactAppIDAndFirstMatchingRuleWin") { workspaceEngineCases.testExactAppIDAndFirstMatchingRuleWin() }
checks.run("testGuestIdentityIsExactAndCaseInsensitiveWithoutMatchingOtherGuests") { workspaceEngineCases.testGuestIdentityIsExactAndCaseInsensitiveWithoutMatchingOtherGuests() }
checks.run("testBundlePathAndMissingFieldsDoNotBroadenIdentity") { workspaceEngineCases.testBundlePathAndMissingFieldsDoNotBroadenIdentity() }
checks.run("testStableMismatchNeedsARepeatedSettledObservation") { workspacePolicyCases.testStableMismatchNeedsARepeatedSettledObservation() }
checks.run("testChangedGenerationIdentityRuleOrWorkspaceStartsNewConfirmation") { workspacePolicyCases.testChangedGenerationIdentityRuleOrWorkspaceStartsNewConfirmation() }
checks.run("testClockRegressionAndInvalidTimeNeverImmediatelyConfirm") { workspacePolicyCases.testClockRegressionAndInvalidTimeNeverImmediatelyConfirm() }
checks.run("testCorrectionConflictsBlockUntilExplicitResetOrDeath") { workspacePolicyCases.testCorrectionConflictsBlockUntilExplicitResetOrDeath() }
checks.run("testSpreadOutCorrectionsExpireButBackwardsTimeCannotBypassBudget") { workspacePolicyCases.testSpreadOutCorrectionsExpireButBackwardsTimeCannotBypassBudget() }
checks.run("testNativeFocusFallbackOnlyUsesCapturedPositivePIDAfterSystemWideFailure") { workspaceRuntimeCases.testNativeFocusFallbackOnlyUsesCapturedPositivePIDAfterSystemWideFailure() }
checks.run("testNativeFocusFallbackLosesPermissionWhenForegroundChangesDuringAXRead") { workspaceRuntimeCases.testNativeFocusFallbackLosesPermissionWhenForegroundChangesDuringAXRead() }
checks.run("testQueuedFrameDequeuedAfterFenceInvalidationNeverStarts") { workspaceRuntimeCases.testQueuedFrameDequeuedAfterFenceInvalidationNeverStarts() }
checks.run("testNewSessionFenceCancelsOnlyItsAlreadyDequeuedFrameJobs") { workspaceRuntimeCases.testNewSessionFenceCancelsOnlyItsAlreadyDequeuedFrameJobs() }
checks.run("testFenceStaysValidAfterEnqueueUntilSupersededAndForgetsCompletedJobs") { workspaceRuntimeCases.testFenceStaysValidAfterEnqueueUntilSupersededAndForgetsCompletedJobs() }
checks.run("testChangedOldPassCannotLayoutAfterNewSessionInterruptsNativeRead") { workspaceRuntimeCases.testChangedOldPassCannotLayoutAfterNewSessionInterruptsNativeRead() }
checks.run("testLatestUserSessionKeepsLayoutPermissionWhileOldPassUnwinds") { workspaceRuntimeCases.testLatestUserSessionKeepsLayoutPermissionWhileOldPassUnwinds() }
checks.run("testIndependentFrameContinuationRejectsEveryPostAwaitStaleWrite") { workspaceRuntimeCases.testIndependentFrameContinuationRejectsEveryPostAwaitStaleWrite() }
checks.run("testExplicitInvalidationCancelsEvenAnOtherwiseExclusivePass") { workspaceRuntimeCases.testExplicitInvalidationCancelsEvenAnOtherwiseExclusivePass() }
checks.run("testEveryQueryEntryStaysObservationOnly") { try workspaceRuntimeCases.testEveryQueryEntryStaysObservationOnly() }
checks.run("testExplicitMutationsAndIndependentEventsCanObserveOwnership") { try workspaceRuntimeCases.testExplicitMutationsAndIndependentEventsCanObserveOwnership() }
checks.run("testWorkspaceRuleCommandHasExplicitControlAndReadOnlyStatus") { try workspaceRuntimeCases.testWorkspaceRuleCommandHasExplicitControlAndReadOnlyStatus() }
checks.run("testWritesMetadataAsJSONLinesWithPrivatePermissions") { try workspaceJournalCases.testWritesMetadataAsJSONLinesWithPrivatePermissions() }
checks.run("testRotationAndTotalBudgetKeepNewestRecords") { try workspaceJournalCases.testRotationAndTotalBudgetKeepNewestRecords() }
checks.run("testRetentionRemovesOnlyOwnedOldRegularFiles") { try workspaceJournalCases.testRetentionRemovesOnlyOwnedOldRegularFiles() }
checks.run("testQueueAndRecordBoundsDropWithoutBlockingOrThrowing") { try workspaceJournalCases.testQueueAndRecordBoundsDropWithoutBlockingOrThrowing() }
checks.run("testUnwritableDestinationCountsFailureWithoutThrowing") { try workspaceJournalCases.testUnwritableDestinationCountsFailureWithoutThrowing() }
checks.run("testFixedSchemaAndBoundedStringsExcludeContentFields") { try workspaceJournalCases.testFixedSchemaAndBoundedStringsExcludeContentFields() }
checks.run("testTerminalDiffCatchesIndirectContainerMoves") { workspaceSnapshotCases.testTerminalDiffCatchesIndirectContainerMoves() }
checks.run("testTemporaryRebindingWithSameTerminalStateHasNoDrift") { workspaceSnapshotCases.testTemporaryRebindingWithSameTerminalStateHasNoDrift() }
checks.run("testNewDestroyedAndReusedWindowIdentitiesAreDistinct") { workspaceSnapshotCases.testNewDestroyedAndReusedWindowIdentitiesAreDistinct() }
checks.run("testParentChangeWithinWorkspaceIsNotWorkspaceMove") { workspaceSnapshotCases.testParentChangeWithinWorkspaceIsNotWorkspaceMove() }
checks.run("testWorkspaceMoveCauseSurvivesInterleavedParentOnlyRebinds") { workspaceSnapshotCases.testWorkspaceMoveCauseSurvivesInterleavedParentOnlyRebinds() }
checks.run("testProvenanceRequiresCompleteWorkspacePairAndFreshRevision") { workspaceSnapshotCases.testProvenanceRequiresCompleteWorkspacePairAndFreshRevision() }
checks.run("testProvenanceRejectsReusedIdentityAndForgetsRemovedWindows") { workspaceSnapshotCases.testProvenanceRejectsReusedIdentityAndForgetsRemovedWindows() }
checks.run("testEndedInheritedTransactionIsNotReusedByConfirmationSession") { workspaceSnapshotCases.testEndedInheritedTransactionIsNotReusedByConfirmationSession() }
checks.run("testIndependentEntryAlwaysStartsNewWhileInternalHelpersReuseCurrent") { workspaceSnapshotCases.testIndependentEntryAlwaysStartsNewWhileInternalHelpersReuseCurrent() }
checks.run("testConfigSourceFingerprintIncludesNonAffinityConfiguration") { workspaceSnapshotCases.testConfigSourceFingerprintIncludesNonAffinityConfiguration() }
let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
checks.run("upstream axDumps corpus") { try checkUpstreamAxDumps(repoRoot.appending(path: "axDumps"), checks) }
print("Offline checks: \(checks.groups) groups, \(checks.assertions) assertions, \(checks.fixtures) upstream fixtures, \(checks.failures) failures")
exit(checks.failures == 0 ? 0 : 1)
}
#else
import Foundation
print("zzz-compat-checks requires a debug build (swift run -c debug zzz-compat-checks)")
exit(2)
#endif
