import AppKit
@testable import AppBundle
import Foundation
import XCTest

final class YaaglGameCompatibilityTest: XCTestCase {
    private let wineURL = URL(filePath: "/fixture/Yaagl ZZZ OS/wine/lib/wine/x86_64-unix/wine")
    private let gameArgument = "Z:\\Users\\fixture\\Games\\ZZZ\\ZenlessZoneZero.exe"
    private let hsrWineURL = URL(filePath: "/fixture/Yaagl HSR/wine/lib/wine/x86_64-unix/wine")
    private let hsrGameArgument = "Z:\\Users\\fixture\\Games\\HSR\\StarRail.exe"
    private let giWineURL = URL(filePath: "/fixture/Yaagl/wine/lib/wine/x86_64-unix/wine")
    private let giGameArgument = "Z:\\Users\\fixture\\Games\\GI\\YuanShen.exe"

    private func profile(game: YaaglGameCompatibilityProfile.Game = .zzz) throws -> YaaglGameCompatibilityProfile {
        let (wineURL, argument) = switch game {
            case .zzz: (self.wineURL, gameArgument)
            case .hsr: (hsrWineURL, hsrGameArgument)
            case .gi: (giWineURL, giGameArgument)
        }
        return try XCTUnwrap(YaaglGameCompatibilityProfile.detect(
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
        XCTAssertNil(YaaglGameCompatibilityProfile.detect(
            enabled: false, executableURL: wineURL,
            expectedWineExecutableURL: wineURL, arguments: arguments,
        ))
        XCTAssertNil(YaaglGameCompatibilityProfile.detect(
            enabled: true, executableURL: URL(filePath: "/fixture/Yaagl HSR/wine/lib/wine/x86_64-unix/wine"),
            expectedWineExecutableURL: wineURL, arguments: arguments,
        ))
        XCTAssertNil(YaaglGameCompatibilityProfile.detect(
            enabled: true, executableURL: nil,
            expectedWineExecutableURL: wineURL, arguments: arguments,
        ))
        XCTAssertEqual(reads, 0)
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
            XCTAssertNil(YaaglGameCompatibilityProfile.detect(
                enabled: true, executableURL: wineURL,
                expectedWineExecutableURL: wineURL, arguments: { arguments },
            ))
        }
        XCTAssertNotNil(YaaglGameCompatibilityProfile.detect(
            enabled: true, executableURL: wineURL,
            expectedWineExecutableURL: wineURL, arguments: { ["wine", self.gameArgument] },
        ))
    }

    func testObservedMainWindowStaysFloatingWhenUnfocusedAndLevelChanges() throws {
        let profile = try profile()
        for focused in [true, false] {
            let window = fixtureWindow(focused: focused)
            for level in [MacOsWindowLevel.unknown(windowLevel: 26), .normalWindow] {
                XCTAssertTrue(window.isWindowHeuristic(
                    axApp: FixtureAxElement(fields: [:]), nil, .regular, level,
                    yaaglGameCompatibility: profile,
                ))
                XCTAssertEqual(window.getWindowType(
                    axApp: FixtureAxElement(fields: [:]), nil, .regular, level,
                    yaaglGameCompatibility: profile,
                ), .dialog)
            }
        }
    }

    func testDefaultClassificationRemainsPopupWithoutVerifiedProcess() {
        let window = fixtureWindow(focused: true)
        XCTAssertEqual(window.getWindowType(
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
            XCTAssertEqual(window.getWindowType(
                axApp: FixtureAxElement(fields: [:]), nil, policy, level,
                yaaglGameCompatibility: profile,
            ), .popup)
        }
        XCTAssertEqual(fixtureWindow().getWindowType(
            axApp: FixtureAxElement(fields: [:]), .chrome, .regular, .unknown(windowLevel: 26),
            yaaglGameCompatibility: profile,
        ), .popup)
    }

    func testProcessArgumentsParserStopsBeforeEnvironment() {
        let arguments = [gameArgument, "-example-game-option"]
        XCTAssertEqual(YaaglGameCompatibilityProfile.parseProcessArguments(processArgumentsFixture(arguments)), arguments)
        XCTAssertNil(YaaglGameCompatibilityProfile.parseProcessArguments(Data()))
        XCTAssertNil(YaaglGameCompatibilityProfile.parseProcessArguments(Data([1, 0, 0])))
        XCTAssertNil(YaaglGameCompatibilityProfile.parseProcessArguments(processArgumentsFixture(arguments).prefix(8)))
        XCTAssertNil(YaaglGameCompatibilityProfile.detect(
            enabled: true, executableURL: wineURL,
            expectedWineExecutableURL: wineURL,
            arguments: { YaaglGameCompatibilityProfile.parseProcessArguments(self.processArgumentsFixture(["wine"])) },
        ))
    }

    func testHSRMainWindowStaysFloatingWhenUnfocusedAndLevelChanges() throws {
        let profile = try profile(game: .hsr)
        XCTAssertEqual(profile.identifier, "yaagl-hsr-main-v1")
        for title in ["Honkai: Star Rail", "崩坏：星穹铁道"] {
            for focused in [true, false] {
                let window = fixtureWindow(title: title, focused: focused)
                for level in [MacOsWindowLevel.unknown(windowLevel: 26), .normalWindow] {
                    XCTAssertTrue(window.isWindowHeuristic(
                        axApp: FixtureAxElement(fields: [:]), nil, .regular, level,
                        yaaglGameCompatibility: profile,
                    ))
                    XCTAssertEqual(window.getWindowType(
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
            XCTAssertEqual(window.getWindowType(
                axApp: FixtureAxElement(fields: [:]), nil, .regular, .unknown(windowLevel: 26),
                yaaglGameCompatibility: profile,
            ), .popup)
        }
        XCTAssertEqual(fixtureWindow(title: "Honkai: Star Rail").getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .unknown(windowLevel: 26),
        ), .popup)
    }

    func testGameProfilesCannotCrossMatch() throws {
        let zzz = try profile()
        let hsr = try profile(game: .hsr)
        XCTAssertEqual(zzz.identifier, "yaagl-zzz-main-v1")
        XCTAssertEqual(fixtureWindow(title: "Honkai: Star Rail").getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
            yaaglGameCompatibility: zzz,
        ), .popup)
        XCTAssertEqual(fixtureWindow(title: "崩坏：星穹铁道").getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
            yaaglGameCompatibility: zzz,
        ), .popup)
        XCTAssertEqual(fixtureWindow().getWindowType(
            axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
            yaaglGameCompatibility: hsr,
        ), .popup)
        for (game, wine, wrongArgument) in [
            (YaaglGameCompatibilityProfile.Game.hsr, hsrWineURL, gameArgument),
            (.zzz, wineURL, hsrGameArgument),
        ] {
            XCTAssertNil(YaaglGameCompatibilityProfile.detect(
                game: game, enabled: true, executableURL: wine,
                expectedWineExecutableURL: wine, arguments: { [wrongArgument] },
            ))
        }
        XCTAssertNil(YaaglGameCompatibilityProfile.detect(
            game: .hsr, enabled: false, executableURL: hsrWineURL,
            expectedWineExecutableURL: hsrWineURL, arguments: { [self.hsrGameArgument] },
        ))
        XCTAssertNil(YaaglGameCompatibilityProfile.detect(
            game: .hsr, enabled: true, executableURL: wineURL,
            expectedWineExecutableURL: hsrWineURL, arguments: { [self.hsrGameArgument] },
        ))
        XCTAssertNil(YaaglGameCompatibilityProfile.detect(
            game: .hsr, enabled: true, executableURL: hsrWineURL,
            expectedWineExecutableURL: hsrWineURL, arguments: { ["UnityCrashHandler64.exe", self.hsrGameArgument] },
        ))
    }

    func testGIAcceptsOnlyKnownClientExecutables() {
        for executable in ["YuanShen.exe", "GenshinImpact.exe"] {
            XCTAssertNotNil(YaaglGameCompatibilityProfile.detect(
                game: .gi, enabled: true, executableURL: giWineURL,
                expectedWineExecutableURL: giWineURL,
                arguments: { ["wine", "Z:\\Games\\GI\\\(executable)"] },
            ))
        }
        for arguments in [
            ["UnityCrashHandler64.exe", giGameArgument],
            ["StarRail.exe"], [gameArgument], ["OtherGenshinImpact.exe"],
            ["GenshinImpact.exe.helper"], ["YuanShen.exe Launcher.exe"],
        ] {
            XCTAssertNil(YaaglGameCompatibilityProfile.detect(
                game: .gi, enabled: true, executableURL: giWineURL,
                expectedWineExecutableURL: giWineURL, arguments: { arguments },
            ))
        }
        XCTAssertNil(YaaglGameCompatibilityProfile.detect(
            game: .gi, enabled: false, executableURL: giWineURL,
            expectedWineExecutableURL: giWineURL, arguments: { [self.giGameArgument] },
        ))
        XCTAssertNil(YaaglGameCompatibilityProfile.detect(
            game: .gi, enabled: true, executableURL: hsrWineURL,
            expectedWineExecutableURL: giWineURL, arguments: { [self.giGameArgument] },
        ))
        for game in [YaaglGameCompatibilityProfile.Game.zzz, .hsr] {
            XCTAssertNil(YaaglGameCompatibilityProfile.detect(
                game: game, enabled: true, executableURL: giWineURL,
                expectedWineExecutableURL: giWineURL, arguments: { [self.giGameArgument] },
            ))
        }
    }

    func testGIKnownMainWindowTitlesStayFloatingWithoutFocus() throws {
        let profile = try profile(game: .gi)
        XCTAssertEqual(profile.identifier, "yaagl-gi-main-v1")
        for title in ["原神", "Genshin Impact"] {
            for focused in [true, false] {
                let window = fixtureWindow(title: title, focused: focused)
                for level in [MacOsWindowLevel.unknown(windowLevel: 26), .normalWindow] {
                    XCTAssertTrue(window.isWindowHeuristic(
                        axApp: FixtureAxElement(fields: [:]), nil, .regular, level,
                        yaaglGameCompatibility: profile,
                    ))
                    XCTAssertEqual(window.getWindowType(
                        axApp: FixtureAxElement(fields: [:]), nil, .regular, level,
                        yaaglGameCompatibility: profile,
                    ), .dialog)
                }
            }
        }
    }

    func testGIRejectsUnverifiedAndAuxiliaryWindows() throws {
        let profile = try profile(game: .gi)
        for window in [
            fixtureWindow(title: ""),
            fixtureWindow(title: "原神 Launcher"),
            fixtureWindow(title: "Genshin Impact Launcher"),
            fixtureWindow(title: "genshin impact"),
            fixtureWindow(title: "Honkai: Star Rail"),
            fixtureWindow(title: "ZenlessZoneZero"),
            fixtureWindow(title: "原神", size: CGSize(width: 1920, height: 30)),
            fixtureWindow(title: "Genshin Impact", size: CGSize(width: 64, height: 64)),
            fixtureWindow(title: "原神", nativeFullscreen: true),
        ] {
            XCTAssertEqual(window.getWindowType(
                axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
                yaaglGameCompatibility: profile,
            ), .popup)
        }
        for title in ["原神", "Genshin Impact"] {
            XCTAssertEqual(fixtureWindow(title: title).getWindowType(
                axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
            ), .popup)
            for otherGame in [YaaglGameCompatibilityProfile.Game.zzz, .hsr] {
                XCTAssertEqual(fixtureWindow(title: title).getWindowType(
                    axApp: FixtureAxElement(fields: [:]), nil, .regular, .normalWindow,
                    yaaglGameCompatibility: try self.profile(game: otherGame),
                ), .popup)
            }
        }
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
