import AppKit

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
/// focus and hand native focus back to the focused window. `ignore-launch-activation` does the
/// same only while the window's app is launching. Call before updateFocusCache.
@MainActor func ignoresNativeActivation(_ nativeFocused: Window?) async -> Bool {
    advanceLaunchActivationPhases(nativeFocused)
    guard let nativeFocused, nativeFocused.windowId != lastKnownNativeFocusedWindowId,
          let workspace = nativeFocused.nodeWorkspace, workspace != focus.workspace else { return false }
    for rule in config.focusRules where await rule.matcher.matches(nativeFocused) {
        switch rule.policy {
            case .ignoreActivation:
                focus.windowOrNil?.nativeFocus()
                return true
            case .ignoreLaunchActivation:
                guard (nativeFocused.app as? MacApp)?.launchActivationPhase.isLaunching == true else { return false }
                focus.windowOrNil?.nativeFocus()
                return true
        }
    }
    return false
}

/// Feeds the current native focus to every launching app (see `LaunchActivationPhase`).
/// Runs on every refresh session, before the focus-rules check and before updateFocusCache
/// updates lastKnownNativeFocusedWindowId.
@MainActor private func advanceLaunchActivationPhases(_ nativeFocused: Window?) {
    let launching = MacApp.allAppsMap.values.filter { $0.launchActivationPhase.isLaunching }
    if launching.isEmpty { return }
    // Without a focused window, ask macOS which app is frontmost. Only needed to end a launch
    // whose window already held native focus
    let focusedPid: pid_t? = nativeFocused?.app.pid ??
        (launching.contains { $0.launchActivationPhase == .launchingFocused }
            ? MacApp.resolvedNativePID(NSWorkspace.shared.frontmostApplication) : nil)
    let focusMoved = nativeFocused.map { $0.windowId != lastKnownNativeFocusedWindowId && $0.nodeWorkspace != nil } ?? false
    let appsWithWindows = Set(MacWindow.allWindows.filter { $0.nodeWorkspace != nil }.map { $0.app.pid })
    for app in launching {
        let holdsNativeFocus = app.pid == focusedPid
        app.launchActivationPhase = app.launchActivationPhase.next(
            holdsNativeFocus: holdsNativeFocus,
            focusesWindow: holdsNativeFocus && nativeFocused?.nodeWorkspace != nil,
            hasWindow: appsWithWindows.contains(app.pid),
            focusMovedToOtherWindow: !holdsNativeFocus && focusMoved,
        )
    }
}
