/// `[[focus-rules]]`: how AeroSpace reacts when macOS focuses a matching window.
/// Rules apply only to native focus changes (an app activating itself, Cmd-Tab, a Dock click).
/// AeroSpace's own focus commands (`workspace`, `focus --window-id`) are never filtered.
/// The first matching rule wins.
struct FocusRule: Equatable {
    enum Policy: String {
        /// A matching window focused natively on another workspace doesn't pull AeroSpace
        /// there. AeroSpace keeps its workspace and hands native focus back to its focused window.
        case ignoreActivation = "ignore-activation"
    }

    var id: String
    var matcher: LegacyWindowDetectedCallbackMatcher
    var policy: Policy
}
