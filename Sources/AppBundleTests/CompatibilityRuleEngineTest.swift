import AppKit
@testable import AppBundle
import Foundation
import XCTest

final class CompatibilityRuleEngineTest: XCTestCase {
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
        XCTAssertEqual(result?.pid, 42)
        XCTAssertNil(result?.recoveryRule)
        let invalidPIDs: [Int32] = [-1, 0]
        for pid in invalidPIDs {
            XCTAssertNil(CompatibilityRuleEngine.resolveProcess(
                rules: [], reportedPID: pid, identity: wrapperIdentity,
                ownerPIDs: { reads += 1; return [101] }, processPath: { _ in reads += 1; return self.wrapperIdentity.executablePath },
            ))
        }
        XCTAssertEqual(reads, 0)
    }

    func testPIDRecoveryUsesExactConfiguredIdentityAndUniqueOwner() {
        let rule = applicationRule()
        let result = CompatibilityRuleEngine.resolveProcess(
            rules: [rule], reportedPID: -1, identity: wrapperIdentity,
            ownerPIDs: { [-1, 0, 101, 101, 202] },
            processPath: { $0 == 101 ? self.wrapperIdentity.executablePath : "/fixture/Other.app/Contents/MacOS/Other" },
        )
        XCTAssertEqual(result?.pid, 101)
        XCTAssertEqual(result?.recoveryRule?.id, rule.id)
        let cases: [([Int32], [Int32: String])] = [
            ([], [:]), ([-1, 0], [:]), ([101], [:]),
            ([101], [101: "/fixture/Other.app/Contents/MacOS/Other"]),
            ([101], [101: wrapperIdentity.executablePath! + "Helper"]),
            ([101, 202], [101: wrapperIdentity.executablePath!, 202: wrapperIdentity.executablePath!]),
        ]
        for (owners, paths) in cases {
            XCTAssertNil(CompatibilityRuleEngine.resolveProcess(
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
            XCTAssertNil(CompatibilityRuleEngine.resolveProcess(
                rules: [applicationRule()], reportedPID: -1, identity: identity,
                ownerPIDs: { reads += 1; return [101] }, processPath: { _ in reads += 1; return self.wrapperIdentity.executablePath },
            ))
        }
        var incomplete = applicationRule().match
        incomplete.bundlePath = nil
        let malformed = CompatibilityRule(id: "incomplete", phase: .application, match: incomplete, action: .init(recoverPid: .windowOwner))
        XCTAssertNil(CompatibilityRuleEngine.resolveProcess(
            rules: [malformed, windowRule()], reportedPID: -1, identity: wrapperIdentity,
            ownerPIDs: { reads += 1; return [101] }, processPath: { _ in reads += 1; return self.wrapperIdentity.executablePath },
        ))
        XCTAssertEqual(reads, 0)
    }

    func testFirstExecutableArgumentIsGenericExactAndCaseInsensitive() {
        for arguments in [["loader", "Z:\\Client\\Client.exe"], ["/fixture/Client-CN.EXE"]] {
            XCTAssertEqual(windowRules(arguments: arguments).rules.map(\.id), ["fixture-floating"])
        }
        let rejectedArguments: [[String]?] = [
            ["CrashReporter.exe", "Client.exe"], ["OtherClient.exe"], ["Client.exe.helper"], ["Client.exe Launcher.exe"], [], nil,
        ]
        for arguments in rejectedArguments {
            XCTAssertEqual(windowRules(arguments: arguments).rules.count, 0)
        }
    }

    func testProcessPrefilterReadsArgumentsOnlyOnceAndNeverForUnmatchedRules() {
        var reads = 0
        let loaded = CompatibilityRuleEngine.windowRules(
            rules: [windowRule("one"), windowRule("two")], identity: clientIdentity,
            arguments: { reads += 1; return ["Client.exe"] },
        )
        XCTAssertEqual(loaded.rules.map(\.id), ["one", "two"])
        XCTAssertEqual(reads, 1)
        _ = CompatibilityRuleEngine.windowRules(
            rules: [windowRule()], identity: wrapperIdentity,
            arguments: { reads += 1; return ["Client.exe"] },
        )
        XCTAssertEqual(reads, 1)
        var match = windowRule().match
        match.firstExeArgument = nil
        XCTAssertEqual(CompatibilityRuleEngine.windowRules(
            rules: [windowRule(match: match)], identity: clientIdentity,
            arguments: { reads += 1; return nil },
        ).rules.count, 1)
        XCTAssertEqual(reads, 1)
    }

    func testWindowRuleCanUseExactAppIDWithoutExecutablePath() {
        var match = windowRule().match
        match.executablePath = nil
        match.appIdAbsent = false
        match.appId = wrapperIdentity.appId
        match.firstExeArgument = nil
        let rules = CompatibilityRuleEngine.windowRules(rules: [windowRule(match: match)], identity: wrapperIdentity, arguments: { nil })
        XCTAssertEqual(rules.rules.count, 1)
        XCTAssertEqual(CompatibilityRuleEngine.windowRules(rules: [windowRule(match: match)], identity: clientIdentity, arguments: { nil }).rules.count, 0)
        match.appId = nil // No exact process identity: reject even if the window traits match.
        XCTAssertEqual(CompatibilityRuleEngine.windowRules(rules: [windowRule(match: match)], identity: wrapperIdentity, arguments: { nil }).rules.count, 0)
    }

    func testMatchingWindowsStayFloatingAcrossFocusAndLevelChanges() {
        for title in ["Example client", "示例客户端"] {
            for focused in [false, true] {
                let window = fixtureWindow(title: title, focused: focused)
                for level in [MacOsWindowLevel.normalWindow, .unknown(windowLevel: 26)] {
                    XCTAssertTrue(window.isWindowHeuristic(
                        axApp: FixtureAxElement(fields: [:]), nil, .regular, level, compatibilityRules: windowRules(),
                    ))
                    XCTAssertEqual(window.getWindowType(
                        axApp: FixtureAxElement(fields: [:]), nil, .regular, level, compatibilityRules: windowRules(),
                    ), .dialog)
                    XCTAssertEqual(window.matchedCompatibilityRule(windowRules(), .regular, level)?.id, "fixture-floating")
                }
            }
        }
    }

    func testFloatingActionOverridesOrdinaryNonDialogWindowAndNoMatchPreservesDefault() {
        var match = windowRule().match
        match.axSubrole = kAXStandardWindowSubrole
        let rules = windowRules([windowRule(match: match)])
        let ordinary = fixtureWindow(subrole: kAXStandardWindowSubrole, fullscreenButtonEnabled: true)
        XCTAssertEqual(ordinary.getWindowType(axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow), .window)
        XCTAssertEqual(ordinary.getWindowType(axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow, compatibilityRules: rules), .dialog)
        XCTAssertEqual(fixtureWindow().getWindowType(axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow), .popup)
        XCTAssertEqual(fixtureWindow(title: "Other window").getWindowType(
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
            XCTAssertNil(window.matchedCompatibilityRule(windowRules(), policy, level))
        }
    }

    func testRuleOrderSelectsTheFirstMatchingWindowID() {
        var unmatched = windowRule().match
        unmatched.windowTitle = ["Different window"]
        let rules = windowRules([windowRule("unmatched", match: unmatched), windowRule("first"), windowRule("second")])
        XCTAssertEqual(fixtureWindow().matchedCompatibilityRule(rules, .regular, .normalWindow)?.id, "first")
    }

    func testEmptyCompatibilityRulesDoNotReadExtraAXAttributes() {
        let window = CountingAxElement()
        XCTAssertNil(window.matchedCompatibilityRule(.empty, .regular, .normalWindow))
        XCTAssertEqual(window.reads, 0)
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
            XCTAssertEqual(rule.isValidFloatingWindowRule, false)
            XCTAssertEqual(windowRules([rule]).rules.count, 0)
            XCTAssertEqual(fixtureWindow().getWindowType(
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
        XCTAssertEqual(CompatibilityProcessAccess.parseArguments(data), arguments)
        XCTAssertNil(CompatibilityProcessAccess.parseArguments(Data()))
        XCTAssertNil(CompatibilityProcessAccess.parseArguments(data.prefix(8)))
        XCTAssertNil(CompatibilityProcessAccess.parseArguments(Data([1, 0, 0])))
    }

    func testFilesystemIdentityIgnoresDirectoryURLHintAndTrailingSlash() {
        let directoryURL = URL(filePath: "/fixture/Wrapper.app", directoryHint: .isDirectory)
        let fileURL = URL(filePath: "/fixture/Wrapper.app", directoryHint: .notDirectory)
        XCTAssertTrue(CompatibilityRuleEngine.pathsMatch(directoryURL.path, fileURL.path))
        XCTAssertTrue(CompatibilityRuleEngine.pathsMatch("/fixture/Wrapper.app/", "/fixture/Wrapper.app"))
        let identity = CompatibilityProcessIdentity(
            appId: wrapperIdentity.appId, bundlePath: directoryURL.path,
            executablePath: wrapperIdentity.executablePath,
        )
        XCTAssertEqual(CompatibilityRuleEngine.resolveProcess(
            rules: [applicationRule()], reportedPID: -1, identity: identity,
            ownerPIDs: { [101] }, processPath: { _ in self.wrapperIdentity.executablePath },
        )?.pid, 101)
        XCTAssertEqual(CompatibilityRuleEngine.pathsMatch("/fixture/Wrapper.app.other", "/fixture/Wrapper.app"), false)
        XCTAssertEqual(CompatibilityRuleEngine.pathsMatch("relative/Wrapper.app", "/fixture/Wrapper.app"), false)
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
