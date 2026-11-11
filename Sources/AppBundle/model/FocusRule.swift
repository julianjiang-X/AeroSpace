/// `[[focus-rules]]`: how AeroSpace reacts when macOS focuses a matching window.
/// Rules apply only to native focus changes (an app activating itself, Cmd-Tab, a Dock click).
/// AeroSpace's own focus commands (`workspace`, `focus --window-id`) are never filtered.
/// The first matching rule wins.
struct FocusRule: Equatable {
    enum Policy: String {
        /// A matching window focused natively on another workspace doesn't pull AeroSpace
        /// there. AeroSpace keeps its workspace and hands native focus back to its focused window.
        case ignoreActivation = "ignore-activation"
        /// Like ignoreActivation, but only while the window is new (`launchActivationGrace` after
        /// AeroSpace first saw it): an app launching doesn't pull AeroSpace along, yet opening it
        /// again later does.
        case ignoreLaunchActivation = "ignore-launch-activation"
    }

    var id: String
    var matcher: LegacyWindowDetectedCallbackMatcher
    var policy: Policy
}
