// Generated from compatibility tests and the upstream AX fixture adapter.
// Regenerate with ../../compatibility-rules/generate-offline-checks.py after changing tests.
// This is a focused offline runner, not the complete XCTest suite.
#if DEBUG
import AppKit
@testable import AppBundle
import Common
import Foundation

struct FailedCheck: Error { let message: String }

final class CheckRunner {
    var assertions = 0
    var failures = 0
    var groups = 0
    var fixtures = 0

    func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        record(value == nil, "expected nil", file, line)
    }
    func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        record(value != nil, "expected non-nil", file, line)
    }
    func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        record(value, "expected true", file, line)
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
    func run(_ name: String, _ body: () throws -> Void) {
        groups += 1
        let before = failures
        do { try body() }
        catch { failures += 1; print("FAIL \(name): \(error)") }
        print("\(failures == before ? "PASS" : "FAIL") \(name)")
    }
}

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


let checks = CheckRunner()
let cases = CompatibilityOfflineCases(checks)
checks.run("testNativePositivePIDBypassesRecoveryAndNoRulesRejectInvalidPID") { cases.testNativePositivePIDBypassesRecoveryAndNoRulesRejectInvalidPID() }
checks.run("testPIDRecoveryUsesExactConfiguredIdentityAndUniqueOwner") { cases.testPIDRecoveryUsesExactConfiguredIdentityAndUniqueOwner() }
checks.run("testRecoveryNeverBroadensMissingOrMismatchedMetadata") { cases.testRecoveryNeverBroadensMissingOrMismatchedMetadata() }
checks.run("testFirstExecutableArgumentIsGenericExactAndCaseInsensitive") { cases.testFirstExecutableArgumentIsGenericExactAndCaseInsensitive() }
checks.run("testProcessPrefilterReadsArgumentsOnlyOnceAndNeverForUnmatchedRules") { cases.testProcessPrefilterReadsArgumentsOnlyOnceAndNeverForUnmatchedRules() }
checks.run("testWindowRuleCanUseExactAppIDWithoutExecutablePath") { cases.testWindowRuleCanUseExactAppIDWithoutExecutablePath() }
checks.run("testMatchingWindowsStayFloatingAcrossFocusAndLevelChanges") { cases.testMatchingWindowsStayFloatingAcrossFocusAndLevelChanges() }
checks.run("testFloatingActionOverridesOrdinaryNonDialogWindowAndNoMatchPreservesDefault") { cases.testFloatingActionOverridesOrdinaryNonDialogWindowAndNoMatchPreservesDefault() }
checks.run("testWindowTraitsRejectAuxiliaryAndUnverifiedWindows") { cases.testWindowTraitsRejectAuxiliaryAndUnverifiedWindows() }
checks.run("testRuleOrderSelectsTheFirstMatchingWindowID") { cases.testRuleOrderSelectsTheFirstMatchingWindowID() }
checks.run("testEmptyCompatibilityRulesDoNotReadExtraAXAttributes") { cases.testEmptyCompatibilityRulesDoNotReadExtraAXAttributes() }
checks.run("testMalformedWindowRulesFallBackToDefaultHeuristics") { cases.testMalformedWindowRulesFallBackToDefaultHeuristics() }
checks.run("testArgumentParserStopsBeforeEnvironmentAndRejectsTruncation") { cases.testArgumentParserStopsBeforeEnvironmentAndRejectsTruncation() }
checks.run("testFilesystemIdentityIgnoresDirectoryURLHintAndTrailingSlash") { cases.testFilesystemIdentityIgnoresDirectoryURLHintAndTrailingSlash() }
let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
checks.run("upstream axDumps corpus") { try checkUpstreamAxDumps(repoRoot.appending(path: "axDumps"), checks) }
print("Offline checks: \(checks.groups) groups, \(checks.assertions) assertions, \(checks.fixtures) upstream fixtures, \(checks.failures) failures")
exit(checks.failures == 0 ? 0 : 1)
#else
import Foundation
print("zzz-compat-checks requires a debug build (swift run -c debug zzz-compat-checks)")
exit(2)
#endif
