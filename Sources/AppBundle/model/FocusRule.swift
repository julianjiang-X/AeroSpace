/// `[[focus-rules]]`: how AeroSpace reacts when macOS focuses a matching window.
/// Rules apply only to native focus changes (an app activating itself, Cmd-Tab, a Dock click).
/// AeroSpace's own focus commands (`workspace`, `focus --window-id`) are never filtered.
/// The first matching rule wins.
struct FocusRule: Equatable {
    enum Policy: String {
        /// A matching window focused natively on another workspace doesn't pull AeroSpace
        /// there. AeroSpace keeps its workspace and hands native focus back to its focused window.
        case ignoreActivation = "ignore-activation"
        /// Like ignoreActivation, but only while the window's app is launching (see
        /// `LaunchActivationPhase`): an app launching doesn't pull AeroSpace along, yet opening it
        /// again afterwards does, however soon.
        case ignoreLaunchActivation = "ignore-launch-activation"
    }

    var id: String
    var matcher: LegacyWindowDetectedCallbackMatcher
    var policy: Policy
}

/// Where an app is in its launch, for `ignore-launch-activation`. Every refresh session advances
/// it from macOS's activation reports and what holds native focus at that moment; no timers are
/// involved.
///
/// The launch ends the first time the app stops being the active app: macOS reports it deactivated
/// (AeroSpace handing focus back from the ignored activation counts, and so does you focusing
/// something else while the app is still loading, before it has shown a window). As a fallback for
/// apps that were never activated, it also ends when native focus moves to another app's window
/// while the app's window sits unfocused in the background.
enum LaunchActivationPhase: Equatable, Sendable {
    /// The process started while AeroSpace was running and hasn't been deactivated yet. Holding
    /// native focus without a window, or with a popup (a borderless splash screen), stays here.
    case launching
    /// One of its windows has held native focus (accepted, or ignored and handed back). The
    /// launch ends as soon as the app no longer holds native focus.
    case launchingFocused
    /// The launch is over, or the process was already running when AeroSpace started. Every
    /// activation is a regular one.
    case launched

    init(startedAfterServer: Bool) { self = startedAfterServer ? .launching : .launched }

    var isLaunching: Bool { self != .launched }

    /// - Parameters:
    ///   - deactivated: macOS has reported the app deactivated since its process started
    ///   - holdsNativeFocus: the app is the one macOS considers focused
    ///   - focusesWindow: the app's natively focused window is one AeroSpace manages on a workspace
    ///   - hasWindow: AeroSpace manages at least one window of the app on a workspace
    ///   - focusMovedToOtherWindow: native focus has just moved to another app's window
    func next(deactivated: Bool, holdsNativeFocus: Bool, focusesWindow: Bool, hasWindow: Bool, focusMovedToOtherWindow: Bool) -> Self {
        if deactivated { return .launched }
        switch self {
            case .launching:
                if holdsNativeFocus { return focusesWindow ? .launchingFocused : .launching }
                return hasWindow && focusMovedToOtherWindow ? .launched : .launching
            case .launchingFocused:
                return holdsNativeFocus ? .launchingFocused : .launched
            case .launched:
                return .launched
        }
    }
}
