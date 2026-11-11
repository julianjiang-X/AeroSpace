@testable import AppBundle
import Common
import Foundation
import XCTest

/// `%{window-x}`, `%{window-y}`, `%{window-width}`, `%{window-height}` in `list-windows --format`.
@MainActor
final class WindowGeometryFormatTest: XCTestCase {
    private let geometry: [FormatVar.WindowFormatVar] = [.windowX, .windowY, .windowWidth, .windowHeight]

    func testVariablesParse() {
        XCTAssertEqual(geometry.map(\.rawValue), ["window-x", "window-y", "window-width", "window-height"])
        for variable in geometry {
            XCTAssertEqual(FormatVar(rawValue: variable.rawValue), .window(variable))
            XCTAssertTrue(FormatVar.window(variable).isWindowGeometry)
        }
        for other in [FormatVar.window(.windowId), .window(.windowTitle), .app(.appPid), .workspace(.workspaceName)] {
            XCTAssertFalse(other.isWindowGeometry)
        }
    }

    func testListWindowsAcceptsGeometryInFormatAndJson() throws {
        let format = "%{window-id} %{window-x} %{window-y} %{window-width} %{window-height}"
        let plain = try XCTUnwrap(parseCmdArgs(["list-windows", "--all", "--format", format].slice).cmdOrNil as? ListWindowsCmdArgs)
        XCTAssertEqual(plain.format.count, 9)
        let json = try XCTUnwrap(parseCmdArgs(["list-windows", "--all", "--json", "--format", format].slice).cmdOrNil as? ListWindowsCmdArgs)
        XCTAssertTrue(json.json)
        XCTAssertEqual(json.format.compactMap { if case .interVar(let it) = $0 { it.rawValue } else { nil } },
                       ["window-id", "window-x", "window-y", "window-width", "window-height"])
    }

    func testValuesAreIntegerPointsOfTheAxFrame() {
        // A window on a secondary monitor left of and above the main one has negative coordinates
        let rect = Rect(topLeftX: -1512, topLeftY: -38.4, width: 1440.6, height: 875)
        XCTAssertEqual(geometry.map { $0.geometryValue(rect)?.toString() }, ["-1512", "-38", "1441", "875"])
        XCTAssertEqual(geometry.map { $0.geometryValue(rect)?.kind }, [.int, .int, .int, .int])
    }

    func testMissingFrameIsNullString() {
        XCTAssertEqual(geometry.map { $0.geometryValue(nil)?.toString() },
                       ["NULL-WINDOW-X", "NULL-WINDOW-Y", "NULL-WINDOW-WIDTH", "NULL-WINDOW-HEIGHT"])
        XCTAssertNil(FormatVar.WindowFormatVar.windowId.geometryValue(nil))
        XCTAssertNil(FormatVar.WindowFormatVar.windowTitle.geometryValue(Rect(topLeftX: 0, topLeftY: 0, width: 1, height: 1)))
    }
}
