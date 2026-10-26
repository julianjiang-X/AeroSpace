@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        if let nativeFocused {
            MacApp.cancelPendingNativeFocus()
            // A restored native window may still be in the global minimized
            // container. Retry after normalization instead of caching failure.
            if nativeFocused.focusWindow() { lastKnownNativeFocusedWindowId = nativeFocused.windowId }
        } else {
            lastKnownNativeFocusedWindowId = nil
        }
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
