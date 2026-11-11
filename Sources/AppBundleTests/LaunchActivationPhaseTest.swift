@testable import AppBundle
import Common
import Foundation
import XCTest

/// `ignore-launch-activation`: the launch phase follows native focus events, never time.
@MainActor
final class LaunchActivationPhaseTest: XCTestCase {
    private struct Observation {
        var holds = false
        var focusesWindow = false
        var hasWindow = false
        var focusMoved = false
    }

    private func run(_ start: LaunchActivationPhase, _ observations: [Observation]) -> [LaunchActivationPhase] {
        var phase = start
        return observations.map {
            phase = phase.next(holdsNativeFocus: $0.holds, focusesWindow: $0.focusesWindow,
                               hasWindow: $0.hasWindow, focusMovedToOtherWindow: $0.focusMoved)
            return phase
        }
    }

    func testOnlyProcessesStartedAfterAeroSpaceAreLaunching() {
        XCTAssertEqual(LaunchActivationPhase(startedAfterServer: true), .launching)
        XCTAssertEqual(LaunchActivationPhase(startedAfterServer: false), .launched)
        XCTAssertTrue(LaunchActivationPhase.launching.isLaunching)
        XCTAssertTrue(LaunchActivationPhase.launchingFocused.isLaunching)
        XCTAssertFalse(LaunchActivationPhase.launched.isLaunching)
    }

    func testLaunchEndsWhenAeroSpaceHandsFocusBack() {
        let phases = run(.launching, [
            // Launched from a launcher: frontmost before its window exists
            .init(holds: true),
            // Its window appears and is natively focused: the activation that gets ignored
            .init(holds: true, focusesWindow: true, hasWindow: true),
            // AeroSpace handed native focus back to the previously focused window
            .init(holds: false, hasWindow: true),
            // Opened again right away: an ordinary activation
            .init(holds: true, focusesWindow: true, hasWindow: true),
        ])
        XCTAssertEqual(phases, [.launching, .launchingFocused, .launched, .launched])
    }

    func testRepeatedActivationsBeforeHandBackStayLaunching() {
        let phases = run(.launching, [
            .init(holds: true, focusesWindow: true, hasWindow: true),
            // Another refresh before the hand-back took effect
            .init(holds: true, focusesWindow: true, hasWindow: true),
            // Still frontmost through a popup (no managed window focused)
            .init(holds: true, hasWindow: true),
        ])
        XCTAssertEqual(phases, [.launchingFocused, .launchingFocused, .launchingFocused])
    }

    func testBorderlessSplashKeepsLaunchUntilMainWindow() {
        let phases = run(.launching, [
            // A popup splash holds native focus: AeroSpace doesn't manage it as a window
            .init(holds: true),
            .init(holds: true),
            // The main window takes native focus: still the launch activation
            .init(holds: true, focusesWindow: true, hasWindow: true),
        ])
        XCTAssertEqual(phases, [.launching, .launching, .launchingFocused])
    }

    func testFocusingAwayBeforeAnyWindowKeepsLaunching() {
        let phases = run(.launching, [
            .init(holds: true),
            // The user clicks another app while the launching app shows no window yet
            .init(holds: false, focusMoved: true),
            .init(holds: false),
            // Its first window then activates itself: still the launch
            .init(holds: true, focusesWindow: true, hasWindow: true),
        ])
        XCTAssertEqual(phases, [.launching, .launching, .launching, .launchingFocused])
    }

    func testBackgroundWindowEndsLaunchOnNextFocusChange() {
        let phases = run(.launching, [
            // The window appeared without activating its app; native focus stays put
            .init(hasWindow: true),
            // Native focus moves between other windows: the app had its launch
            .init(hasWindow: true, focusMoved: true),
            .init(holds: true, focusesWindow: true, hasWindow: true),
        ])
        XCTAssertEqual(phases, [.launching, .launched, .launched])
    }

    func testEmptyWorkspaceLeavesAppFocusedUntilUserMovesOn() {
        let phases = run(.launching, [
            .init(holds: true, focusesWindow: true, hasWindow: true),
            // Nothing to hand focus back to: the app stays frontmost across refreshes
            .init(holds: true, focusesWindow: true, hasWindow: true),
            // The user focuses something else (for example the desktop)
            .init(holds: false, hasWindow: true),
        ])
        XCTAssertEqual(phases, [.launchingFocused, .launchingFocused, .launched])
    }

    func testLaunchedNeverGoesBack() {
        let phases = run(.launched, [
            .init(holds: true, focusesWindow: true, hasWindow: true),
            .init(holds: false, hasWindow: true, focusMoved: true),
            .init(holds: true),
        ])
        XCTAssertEqual(phases, [.launched, .launched, .launched])
    }
}
