import AppKit
import Common

@TaskLocal private var workspaceRestoreSessionID: UInt64? = nil
@TaskLocal private var workspaceRestoreExplicitBody = false

/// Opt-in restoration runs only after an explicit workspace selection. Merely
/// observing native focus, enumerating windows, or normalizing cannot start it.
@MainActor
enum WorkspaceMinimizedRestore {
    private static var policy = WorkspaceMinimizedRestorePolicy()
    private static var pendingWorkspace: String?
    private static var sourcePID: pid_t?
    private static var sawTargetFocus = false
    private static var lastRequest: [UInt32: UInt64] = [:]
    private static var activeToken: RunLoopJob?
    private struct QualifiedWindow {
        let window: MacWindow
        let ruleID: String
    }
    private static var qualified: [UInt32: QualifiedWindow] = [:]
    private static var sessionCounter: UInt64 = 0
    private static var ownerSession: UInt64?

    static func withSelectionSession<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        sessionCounter &+= 1
        let session = sessionCounter
        defer { if ownerSession == session && (policy.request != nil || pendingWorkspace != nil) { cancel() } }
        return try await $workspaceRestoreSessionID.withValue(session) {
            try await $workspaceRestoreExplicitBody.withValue(false) { try await body() }
        }
    }

    static func withExplicitBody<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        try await $workspaceRestoreExplicitBody.withValue(true) { try await body() }
    }

    static var suppressAutomaticFocus: Bool { policy.request != nil || pendingWorkspace != nil }

    static func noteNativeFocus(_ window: Window) {
        policy.noteFocused(window.windowId)
        guard let request = policy.request else { return }
        if window.windowId == request.entry.windowID && window.app.pid == request.entry.pid {
            sawTargetFocus = true
        } else if sawTargetFocus || window.app.pid != sourcePID {
            cancel()
        }
    }

    static func focusWillChange(workspace: String, windowID: UInt32?) {
        if let pendingWorkspace, pendingWorkspace != workspace { cancel() }
        if let request = policy.request,
           request.entry.workspace != workspace || (windowID != nil && windowID != request.entry.windowID) { cancel() }
    }

    static func observeEligibility(_ window: MacWindow) async throws {
        if qualified[window.windowId]?.window === window { return }
        guard let rule = try await window.macApp.minimizedRestoreRule(window.windowId, .cancellable),
              MacWindow.allWindowsMap[window.windowId] === window else { return }
        qualified[window.windowId] = QualifiedWindow(window: window, ruleID: rule.id)
    }

    static func remember(_ window: MacWindow, workspace: Workspace, parentKind: NonLeafTreeNodeKind) async throws {
        guard parentKind == .floatingWindowsContainer else { return }
        try await observeEligibility(window)
        guard window.nodeWorkspace === workspace, window.parent?.kind == parentKind else { return }
        let ruleID = qualified[window.windowId].flatMap { $0.window === window ? $0.ruleID : nil }
        policy.remember(windowID: window.windowId, pid: window.app.pid, workspace: workspace.name,
            ruleID: ruleID, floating: true)
    }

    static func rememberedWorkspace(for window: Window) -> Workspace? {
        guard let entry = policy.entries[window.windowId], entry.pid == window.app.pid else { return nil }
        return Workspace.get(byName: entry.workspace)
    }

    static func noteNotMinimized(_ window: Window) {
        guard policy.entries[window.windowId]?.pid == window.app.pid else { return }
        policy.noteNotMinimized(window.windowId)
    }

    static func hasQualification(_ window: MacWindow) -> Bool {
        qualified[window.windowId]?.window === window
    }

    static func forget(_ windowID: UInt32) {
        if policy.request?.entry.windowID == windowID { cancel() }
        policy.forget(windowID)
        lastRequest[windowID] = nil
        qualified[windowID] = nil
    }

    static func request(workspace: Workspace) {
        guard !serverArgs.isReadOnly, workspaceRestoreExplicitBody, let session = workspaceRestoreSessionID else { return }
        activeToken?.cancel()
        policy.cancel()
        // Capture the intent before consulting minimized state. A just-hidden
        // native window may not have reached normalizeLayoutReason yet.
        pendingWorkspace = qualified.values.contains { qualification in
            let window = qualification.window
            return MacWindow.allWindowsMap[window.windowId] === window &&
                (window.nodeWorkspace?.name == workspace.name || policy.entries[window.windowId]?.workspace == workspace.name)
        } ? workspace.name : nil
        ownerSession = session
        sourcePID = MacApp.resolvedNativePID(NSWorkspace.shared.frontmostApplication)
        sawTargetFocus = false
        if pendingWorkspace != nil { MacApp.cancelPendingNativeFocus() }
    }

    static func takePendingRequest() async throws -> WorkspaceMinimizedRestorePolicy.Request? {
        guard ownerSession == workspaceRestoreSessionID, let workspace = pendingWorkspace else { return nil }
        try await normalizeLayoutReason()
        guard ownerSession == workspaceRestoreSessionID, pendingWorkspace == workspace,
              focus.workspace.name == workspace, !serverArgs.isReadOnly else { return nil }
        let value = policy.begin(workspace: workspace, readOnly: false)
        pendingWorkspace = nil
        if let value { lastRequest[value.entry.windowID] = value.generation }
        return value
    }

    private static func cancel() {
        pendingWorkspace = nil
        policy.cancel()
        activeToken?.cancel()
        MacApp.cancelPendingNativeFocus()
    }

    private static func isCurrent(_ request: WorkspaceMinimizedRestorePolicy.Request, _ window: MacWindow) -> Bool {
        !serverArgs.isReadOnly && TrayMenuModel.shared.isEnabled &&
            policy.isCurrent(request, workspace: focus.workspace.name) &&
            MacWindow.allWindowsMap[window.windowId] === window && window.app.pid == request.entry.pid &&
            MacApp.allAppsMap[request.entry.pid] === window.macApp &&
            qualified[window.windowId]?.window === window && qualified[window.windowId]?.ruleID == request.entry.ruleID
    }

    /// This request owns the native-focus decision even on timeout. The caller
    /// must not immediately activate a fallback behind a partially restored app.
    static func restore(_ request: WorkspaceMinimizedRestorePolicy.Request) async {
        guard let window = MacWindow.allWindowsMap[request.entry.windowID], isCurrent(request, window) else {
            policy.finish(request, outcome: .identityMismatch)
            return
        }
        MacApp.cancelPendingNativeFocus()
        let token = RunLoopJob(.cancellable)
        activeToken = token
        defer { if activeToken === token { activeToken = nil } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        func valid() async -> Bool {
            guard !token.isCancelled, isCurrent(request, window), ContinuousClock.now < deadline else { return false }
            let identity = try? await window.macApp.hasMinimizedRestoreIdentity(window.windowId, ruleID: request.entry.ruleID)
            return !token.isCancelled && ContinuousClock.now < deadline && isCurrent(request, window) && identity == true
        }
        func validationFailure() -> WorkspaceMinimizedRestorePolicy.Outcome {
            if token.isCancelled || !policy.isCurrent(request, workspace: focus.workspace.name) { return .cancelled }
            return ContinuousClock.now >= deadline ? .timeout : .identityMismatch
        }
        do {
            guard await valid() else { policy.finish(request, outcome: validationFailure()); return }
            try await window.macApp.prepareMinimizedRestore(window.windowId, token, deadline: deadline)
            try await Task.sleep(for: .milliseconds(400))
            guard await valid() else { policy.finish(request, outcome: validationFailure()); return }
            // Wine may acknowledge AXMinimized=false without actually restoring
            // until the native application is activated as well.
            guard window.macApp.activateForMinimizedRestore(token) else {
                policy.finish(request, outcome: .identityMismatch); return
            }
            try await window.macApp.raiseForMinimizedRestore(window.windowId, token, deadline: deadline)
            try await Task.sleep(for: .milliseconds(400))
            guard await valid() else { policy.finish(request, outcome: validationFailure()); return }
            try await window.macApp.frontmostForMinimizedRestore(token, deadline: deadline)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(150))
                guard await valid() else { policy.finish(request, outcome: validationFailure()); return }
                let restored = try await window.macApp.minimizedRestoreReadback(window.windowId)
                guard isCurrent(request, window) else { policy.finish(request, outcome: .cancelled); return }
                guard ContinuousClock.now < deadline else { policy.finish(request, outcome: .timeout); return }
                if restored {
                    window.layoutReason = .standard
                    window.bindAsFloatingWindow(to: Workspace.get(byName: request.entry.workspace))
                    _ = window.focusWindow()
                    updateFocusCache(window)
                    policy.finish(request, outcome: .success)
                    return
                }
            }
            policy.finish(request, outcome: .timeout)
        } catch {
            policy.finish(request, outcome: error is CancellationError ? .cancelled : .timeout)
        }
    }

    static func diagnostics(windowID: UInt32, pid: pid_t) -> Json {
        let entry = policy.entries[windowID].flatMap { $0.pid == pid ? $0 : nil }
        return .dict([
            "windowID": .int(Int(windowID)),
            "ruleID": .stringOrNull(entry?.ruleID ?? qualified[windowID]?.ruleID),
            "rememberedWorkspace": .stringOrNull(entry?.workspace),
            "lastRequest": lastRequest[windowID].map { .int(Int($0)) } ?? .null,
            "lastResult": .stringOrNull(policy.outcomes[windowID]?.rawValue),
        ])
    }
}
