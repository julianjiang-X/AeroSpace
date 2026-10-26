import AppKit
import Common

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
private var focusedApp: (any AbstractApp)? {
    get async throws {
        if isUnitTest {
            return appForTests
        } else {
            check(appForTests == nil)
            return switch NSWorkspace.shared.frontmostApplication {
                case let frontmostApplication?: try await MacApp.getOrRegister(frontmostApplication)
                case nil: nil
            }
        }
    }
}

@MainActor
func getNativeFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
    let window = try await focusedApp?.getFocusedWindow(cm)
    // AX reads can suspend while another app becomes active. Never publish an
    // old app's focus after the native foreground has already moved elsewhere.
    if !isUnitTest, let window,
       MacApp.resolvedNativePID(NSWorkspace.shared.frontmostApplication) != window.app.pid { return nil }
    return window
}
