// Generated from YaaglGameCompatibilityTest.swift and the upstream AX fixture adapter.
// Regenerate with ../../zzz-compat-test/generate-offline-checks.py after changing tests.
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


final class YaaglGameOfflineCases {
    let checks: CheckRunner
    init(_ checks: CheckRunner) { self.checks = checks }
    private let wineURL = URL(filePath: "/fixture/Yaagl ZZZ OS/wine/lib/wine/x86_64-unix/wine")
    private let gameArgument = "Z:\\Users\\fixture\\Games\\ZZZ\\ZenlessZoneZero.exe"
    private let hsrWineURL = URL(filePath: "/fixture/Yaagl HSR/wine/lib/wine/x86_64-unix/wine")
    private let hsrGameArgument = "Z:\\Users\\fixture\\Games\\HSR\\StarRail.exe"

    private func profile(game: YaaglGameCompatibilityProfile.Game = .zzz) throws -> YaaglGameCompatibilityProfile {
        let wineURL = game == .zzz ? self.wineURL : hsrWineURL
        let argument = game == .zzz ? gameArgument : hsrGameArgument
        return try checks.require(YaaglGameCompatibilityProfile.detect(
            game: game,
            enabled: true,
            executableURL: wineURL,
            expectedWineExecutableURL: wineURL,
            arguments: { [argument, "-example-game-option"] },
        ))
    }

    func testOptInAndWinePathAreRequiredBeforeReadingArguments() {
        var reads = 0
        let arguments: () -> [String]? = { reads += 1; return [self.gameArgument] }
        checks.expectNil(YaaglGameCompatibilityProfile.detect(
            enabled: false, executableURL: wineURL,
            expectedWineExecutableURL: wineURL, arguments: arguments,
        ))
        checks.expectNil(YaaglGameCompatibilityProfile.detect(
            enabled: true, executableURL: URL(filePath: "/fixture/Yaagl HSR/wine/lib/wine/x86_64-unix/wine"),
            expectedWineExecutableURL: wineURL, arguments: arguments,
        ))
        checks.expectNil(YaaglGameCompatibilityProfile.detect(
            enabled: true, executableURL: nil,
            expectedWineExecutableURL: wineURL, arguments: arguments,
        ))
        checks.expectEqual(reads, 0)
    }

    func testFirstWindowsExecutableMustBeZZZ() {
        let rejectedArguments: [[String]?] = [
            ["wine", "wineserver.exe", gameArgument],
            ["wine", "StarRail.exe", gameArgument],
            ["wine", "ZenlessZoneZero.exe.helper"],
            ["wine", "OtherZenlessZoneZero.exe"],
            ["wine"],
            nil,
        ]
        for arguments in rejectedArguments {
            checks.expectNil(YaaglGameCompatibilityProfile.detect(
                enabled: true, executableURL: wineURL,
                expectedWineExecutableURL: wineURL, arguments: { arguments },
            ))
        }
        checks.expectNotNil(YaaglGameCompatibilityProfile.detect(
            enabled: true, executableURL: wineURL,
            expectedWineExecutableURL: wineURL, arguments: { ["wine", self.gameArgument] },
        ))
    }

    func testObservedMainWindowStaysFloatingWhenUnfocusedAndLevelChanges() throws {
        let profile = try profile()
        for focused in [true, false] {
            let window = fixtureWindow(focused: focused)
            for level in [MacOsWindowLevel.unknown(windowLevel: 26), .normalWindow] {
                checks.expectTrue(window.isWindowHeuristic(
                    axApp: FixtureAxElement(fields: [:]), nil, .regular, level,
                    yaaglGameCompatibility: profile,
                ))
                checks.expectEqual(window.getWindowType(
                    axApp: FixtureAxElement(fields: [:]), nil, .regular, level,
                    yaaglGameCompatibility: profile,
                ), .dialog)
            }
        }
    }

    func testDefaultClassificationRemainsPopupWithoutVerifiedProcess() {
        let window = fixtureWindow(focused: true)
        checks.expectEqual(window.getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .unknown(windowLevel: 26),
        ), .popup)
    }

    func testUnrelatedAXUnknownWindowsAreNotAdmitted() throws {
        let profile = try profile()
        let cases: [(FixtureAxElement, NSApplication.ActivationPolicy, MacOsWindowLevel?)] = [
            (fixtureWindow(title: "Wine dialog"), .regular, .normalWindow),
            (fixtureWindow(size: CGSize(width: 320, height: 200)), .regular, .normalWindow),
            (fixtureWindow(size: CGSize(width: CGFloat.infinity, height: 1080)), .regular, .normalWindow),
            (fixtureWindow(nativeFullscreen: true), .regular, .normalWindow),
            (fixtureWindow(), .accessory, .normalWindow),
            (fixtureWindow(), .regular, .alwaysOnTopWindow),
            (fixtureWindow(), .regular, nil),
        ]
        for (window, policy, level) in cases {
            checks.expectEqual(window.getWindowType(
                axApp: FixtureAxElement(fields: [:]), nil, policy, level,
                yaaglGameCompatibility: profile,
            ), .popup)
        }
        checks.expectEqual(fixtureWindow().getWindowType(
            axApp: FixtureAxElement(fields: [:]), .chrome, .regular, .unknown(windowLevel: 26),
            yaaglGameCompatibility: profile,
        ), .popup)
    }

    func testProcessArgumentsParserStopsBeforeEnvironment() {
        let arguments = [gameArgument, "-example-game-option"]
        checks.expectEqual(YaaglGameCompatibilityProfile.parseProcessArguments(processArgumentsFixture(arguments)), arguments)
        checks.expectNil(YaaglGameCompatibilityProfile.parseProcessArguments(Data()))
        checks.expectNil(YaaglGameCompatibilityProfile.parseProcessArguments(Data([1, 0, 0])))
        checks.expectNil(YaaglGameCompatibilityProfile.parseProcessArguments(processArgumentsFixture(arguments).prefix(8)))
        checks.expectNil(YaaglGameCompatibilityProfile.detect(
            enabled: true, executableURL: wineURL,
            expectedWineExecutableURL: wineURL,
            arguments: { YaaglGameCompatibilityProfile.parseProcessArguments(self.processArgumentsFixture(["wine"])) },
        ))
    }

    func testHSRMainWindowStaysFloatingWhenUnfocusedAndLevelChanges() throws {
        let profile = try profile(game: .hsr)
        checks.expectEqual(profile.identifier, "yaagl-hsr-main-v1")
        for title in ["Honkai: Star Rail", "崩坏：星穹铁道"] {
            for focused in [true, false] {
                let window = fixtureWindow(title: title, focused: focused)
                for level in [MacOsWindowLevel.unknown(windowLevel: 26), .normalWindow] {
                    checks.expectTrue(window.isWindowHeuristic(
                        axApp: FixtureAxElement(fields: [:]), nil, .regular, level,
                        yaaglGameCompatibility: profile,
                    ))
                    checks.expectEqual(window.getWindowType(
                        axApp: FixtureAxElement(fields: [:]), nil, .regular, level,
                        yaaglGameCompatibility: profile,
                    ), .dialog)
                }
            }
        }
    }

    func testHSRRejectsThinAndUnnamedAuxiliaryWindows() throws {
        let profile = try profile(game: .hsr)
        for window in [
            fixtureWindow(title: "", size: CGSize(width: 1920, height: 30)),
            fixtureWindow(title: "", size: CGSize(width: 64, height: 64)),
            fixtureWindow(title: "", size: CGSize(width: 1920, height: 1080)),
            fixtureWindow(title: "Honkai: Star Rail", size: CGSize(width: 1920, height: 30)),
            fixtureWindow(title: "Honkai: Star Rail", size: CGSize(width: 64, height: 64)),
            fixtureWindow(title: "Honkai: Star Rail", nativeFullscreen: true),
            fixtureWindow(title: "崩坏:星穹铁道"),
            fixtureWindow(title: "崩坏：星穹铁道 Launcher"),
            fixtureWindow(title: "崩坏：星穹铁道", size: CGSize(width: 64, height: 64)),
        ] {
            checks.expectEqual(window.getWindowType(
                axApp: FixtureAxElement(fields: [:]), nil, .regular, .unknown(windowLevel: 26),
                yaaglGameCompatibility: profile,
            ), .popup)
        }
        checks.expectEqual(fixtureWindow(title: "Honkai: Star Rail").getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .unknown(windowLevel: 26),
        ), .popup)
    }

    func testGameProfilesCannotCrossMatch() throws {
        let zzz = try profile()
        let hsr = try profile(game: .hsr)
        checks.expectEqual(zzz.identifier, "yaagl-zzz-main-v1")
        checks.expectEqual(fixtureWindow(title: "Honkai: Star Rail").getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
            yaaglGameCompatibility: zzz,
        ), .popup)
        checks.expectEqual(fixtureWindow(title: "崩坏：星穹铁道").getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
            yaaglGameCompatibility: zzz,
        ), .popup)
        checks.expectEqual(fixtureWindow().getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
            yaaglGameCompatibility: hsr,
        ), .popup)
        for (game, wine, wrongArgument) in [
            (YaaglGameCompatibilityProfile.Game.hsr, hsrWineURL, gameArgument),
            (.zzz, wineURL, hsrGameArgument),
        ] {
            checks.expectNil(YaaglGameCompatibilityProfile.detect(
                game: game, enabled: true, executableURL: wine,
                expectedWineExecutableURL: wine, arguments: { [wrongArgument] },
            ))
        }
        checks.expectNil(YaaglGameCompatibilityProfile.detect(
            game: .hsr, enabled: false, executableURL: hsrWineURL,
            expectedWineExecutableURL: hsrWineURL, arguments: { [self.hsrGameArgument] },
        ))
        checks.expectNil(YaaglGameCompatibilityProfile.detect(
            game: .hsr, enabled: true, executableURL: wineURL,
            expectedWineExecutableURL: hsrWineURL, arguments: { [self.hsrGameArgument] },
        ))
        checks.expectNil(YaaglGameCompatibilityProfile.detect(
            game: .hsr, enabled: true, executableURL: hsrWineURL,
            expectedWineExecutableURL: hsrWineURL, arguments: { ["UnityCrashHandler64.exe", self.hsrGameArgument] },
        ))
    }

    private func processArgumentsFixture(_ arguments: [String]) -> Data {
        var argc = Int32(arguments.count)
        var result = unsafe withUnsafeBytes(of: &argc) { unsafe Data($0) }
        result.append(contentsOf: Array("/fixture/wine".utf8) + [0, 0, 0])
        for argument in arguments { result.append(contentsOf: Array(argument.utf8) + [0]) }
        result.append(contentsOf: Array("DO_NOT_PARSE=ZenlessZoneZero.exe".utf8) + [0, 0])
        return result
    }

    private func fixtureWindow(
        title: String = "ZenlessZoneZero",
        size: CGSize = CGSize(width: 1920, height: 1080),
        focused: Bool = false,
        nativeFullscreen: Bool = false,
    ) -> FixtureAxElement {
        FixtureAxElement(fields: [
            kAXRoleAttribute: kAXWindowRole,
            kAXSubroleAttribute: kAXUnknownSubrole,
            kAXTitleAttribute: title,
            kAXSizeAttribute: size,
            "AXFullScreen": nativeFullscreen,
            kAXFocusedAttribute: focused,
            kAXMainAttribute: focused,
        ])
    }
}

private struct FixtureAxElement: AxUiElementMock {
    let fields: [String: Any]

    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? { fields[attr.key] as? Attr.T }
    func containingWindowId() -> CGWindowID? { 42 }
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
let cases = YaaglGameOfflineCases(checks)
checks.run("testOptInAndWinePathAreRequiredBeforeReadingArguments") { cases.testOptInAndWinePathAreRequiredBeforeReadingArguments() }
checks.run("testFirstWindowsExecutableMustBeZZZ") { cases.testFirstWindowsExecutableMustBeZZZ() }
checks.run("testObservedMainWindowStaysFloatingWhenUnfocusedAndLevelChanges") { try cases.testObservedMainWindowStaysFloatingWhenUnfocusedAndLevelChanges() }
checks.run("testDefaultClassificationRemainsPopupWithoutVerifiedProcess") { cases.testDefaultClassificationRemainsPopupWithoutVerifiedProcess() }
checks.run("testUnrelatedAXUnknownWindowsAreNotAdmitted") { try cases.testUnrelatedAXUnknownWindowsAreNotAdmitted() }
checks.run("testProcessArgumentsParserStopsBeforeEnvironment") { cases.testProcessArgumentsParserStopsBeforeEnvironment() }
checks.run("testHSRMainWindowStaysFloatingWhenUnfocusedAndLevelChanges") { try cases.testHSRMainWindowStaysFloatingWhenUnfocusedAndLevelChanges() }
checks.run("testHSRRejectsThinAndUnnamedAuxiliaryWindows") { try cases.testHSRRejectsThinAndUnnamedAuxiliaryWindows() }
checks.run("testGameProfilesCannotCrossMatch") { try cases.testGameProfilesCannotCrossMatch() }
let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
checks.run("upstream axDumps corpus") { try checkUpstreamAxDumps(repoRoot.appending(path: "axDumps"), checks) }
print("Offline checks: \(checks.groups) groups, \(checks.assertions) assertions, \(checks.fixtures) upstream fixtures, \(checks.failures) failures")
exit(checks.failures == 0 ? 0 : 1)
#else
import Foundation
print("zzz-compat-checks requires a debug build (swift run -c debug zzz-compat-checks)")
exit(2)
#endif
