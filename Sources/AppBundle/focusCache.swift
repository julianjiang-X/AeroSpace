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
            WorkspaceMinimizedRestore.noteNativeFocus(nativeFocused)
            // A restored native window may still be in the global minimized
            // container. Retry after normalization instead of caching failure.
            if nativeFocused.focusWindow() { lastKnownNativeFocusedWindowId = nativeFocused.windowId }
        } else {
            lastKnownNativeFocusedWindowId = nil
        }
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// `[[focus-rules]]` with `policy = 'ignore-activation'`: when macOS focuses a matching window
/// on another workspace (typically an app activating its own new window), keep AeroSpace's
/// focus and hand native focus back to the focused window. Call before updateFocusCache.
@MainActor func ignoresNativeActivation(_ nativeFocused: Window?) async -> Bool {
    guard let nativeFocused, nativeFocused.windowId != lastKnownNativeFocusedWindowId,
          let workspace = nativeFocused.nodeWorkspace, workspace != focus.workspace else { return false }
    for rule in config.focusRules where await rule.matcher.matches(nativeFocused) {
        switch rule.policy {
            case .ignoreActivation:
                focus.windowOrNil?.nativeFocus()
                return true
        }
    }
    return false
}
