import AppKit
import Common
import Foundation

/// Continuous workspace ownership is independent of first-detection callbacks.
/// All writes are synchronous model binds after native and session revalidation;
/// this coordinator never activates an app or changes the selected workspace.
@MainActor
enum WorkspaceAffinity {
    private struct Lifetime {
        let window: MacWindow
        let stamp: WorkspaceAffinityNativeSnapshot.ProcessStamp
    }
    private struct WindowState {
        let pid: pid_t
        let ruleID: String?
        let expected: String?
        let observed: String?
        let result: String
    }

    private static var configurationGeneration: UInt64 = 0
    private static var sessions = WorkspaceAffinitySessionGate()
    private static var stability = WorkspaceAffinityStability()
    private static var budget = WorkspaceAffinityCorrectionBudget()
    private static var lifetimes: [UInt32: Lifetime] = [:]
    private static var pausedWindows: [UInt32: MacWindow] = [:]
    private static var states: [UInt32: WindowState] = [:]
    private static var runtimePaused = false
    private static var timer: Task<Void, Never>?
    private static var debounce: Task<Void, Never>?
    private static var debounceSerial: UInt64 = 0
    private static var reconciling = false
    private static var dedicatedFrameFence: WorkspaceAffinityFrameFence?

    static func start() {
        guard timer == nil, !isUnitTest else { return }
        timer = Task.startUnstructured { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await runWorkspaceAffinitySession()
            }
        }
    }

    static func configurationDidChange() {
        invalidateDedicatedFrames()
        configurationGeneration &+= 1
        sessions.invalidate()
        debounce?.cancel()
        debounce = nil
        stability.reset()
        budget = WorkspaceAffinityCorrectionBudget()
        states.removeAll()
        WorkspaceJournal.record("configuration-changed", reason: "workspace-rules-reloaded")
    }

    /// Every refresh invalidates in-flight native reads. Query sessions also
    /// cancel any event debounce rather than inheriting its permission to repair.
    @discardableResult
    static func sessionWillStart(_ event: RefreshSessionEvent) -> WorkspaceAffinitySessionGate.Token {
        invalidateDedicatedFrames()
        let token = sessions.begin()
        if !eventAllowsCorrection(event) {
            debounce?.cancel()
            debounce = nil
            debounceSerial &+= 1
        }
        return token
    }

    /// Only layouts that apply an affinity correction install this fence.
    /// It intentionally outlives the async layout body: normal queued
    /// writes may finish while the model is idle. The next session invalidates
    /// them before beginning any new model work.
    static func withCorrectionFrameFence<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        invalidateDedicatedFrames()
        let fence = WorkspaceAffinityFrameFence()
        dedicatedFrameFence = fence
        return try await WorkspaceAffinityFrameContext.$current.withValue(fence) { try await body() }
    }

    private static func invalidateDedicatedFrames() {
        dedicatedFrameFence?.invalidate()
        dedicatedFrameFence = nil
    }

    static func allowsPostObservationLayout(_ token: WorkspaceAffinitySessionGate.Token, activeDepth: Int, independent: Bool) -> Bool {
        sessions.allowsLayout(token, activeDepth: activeDepth, independent: independent, cancelled: Task.isCancelled) &&
            (!independent || enabled)
    }

    static func eventAllowsCorrection(_ event: RefreshSessionEvent) -> Bool {
        switch event {
            case .socketServer(let args):
                switch type(of: args).info.kind {
                    case .listApps, .listExecEnvVars, .listModes, .listMonitors,
                         .listWindows, .listWorkspaces, .config, .debugWindows,
                         .echo, .test, .testNot, .subscribe, ._true, ._false,
                         .eval, .volume:
                        return false
                    case .workspaceRule:
                        return (args as? WorkspaceRuleCmdArgs)?.action.val != .status
                    case .reloadConfig:
                        return (args as? ReloadConfigCmdArgs)?.dryRun == false
                    default:
                        return true
                }
            case .hotkeyBinding, .menuBarButton:
                // These entry points do not carry the command that ran. A
                // binding/menu can execute a query, so leave enforcement to a
                // later native event or the independent watchdog.
                return false
            default:
                return true
        }
    }

    private static var enabled: Bool {
        config.workspaceRulesEnabled && !runtimePaused && !serverArgs.isReadOnly &&
            TrayMenuModel.shared.isEnabled
    }

    static func observeStableBoundary(_ event: RefreshSessionEvent) async -> Bool {
        guard eventAllowsCorrection(event), enabled, !Task.isCancelled, !reconciling else { return false }
        reconciling = true
        defer { reconciling = false }
        let generation = configurationGeneration
        let session = sessions.generation
        let alive = Set(MacWindow.allWindowsMap.keys)
        budget.prune(alive: alive)
        for id in Set(lifetimes.keys).union(pausedWindows.keys).union(states.keys).subtracting(alive) {
            lifetimes[id] = nil
            pausedWindows[id] = nil
            states[id] = nil
            stability.forget(windowID: id)
        }

        var changed = false
        var needsConfirmation = false
        for window in MacWindow.allWindows.sorted(by: { $0.windowId < $1.windowId }) {
            guard isCurrent(window, generation: generation, session: session) else { return changed }
            let rules = processCandidates(window)
            guard !rules.isEmpty else { continue }
            guard case .standard = window.layoutReason,
                  window.parent?.kind == .floatingWindowsContainer || window.parent?.kind == .tilingContainer,
                  let actual = window.nodeWorkspace?.name else {
                setState(window, rule: nil, result: "deferred-unconventional-state")
                stability.forget(windowID: window.windowId)
                continue
            }
            guard !window.macApp.nsApp.isHidden else {
                setState(window, rule: nil, result: "deferred-hidden-app")
                stability.forget(windowID: window.windowId)
                continue
            }
            let pid = window.app.pid
            let id = window.windowId
            let readTitle = rules.contains { $0.match.windowTitle != nil }
            let native = await Task.detached(priority: .utility) {
                WorkspaceAffinityNativeSnapshot.read(pid: pid, windowID: id, readTitle: readTitle)
            }.value
            guard isCurrent(window, generation: generation, session: session) else { return changed }
            guard let native, native.minimized == false, native.fullscreen == false,
                  native.role == kAXWindowRole, native.subrole != nil,
                  let processIdentity = verifiedProcessIdentity(window, snapshot: native) else {
                setState(window, rule: nil, result: "deferred-native-state-unavailable-or-unconventional")
                stability.forget(windowID: id)
                continue
            }
            if lifetimes[id]?.window !== window || lifetimes[id]?.stamp != native.stamp {
                lifetimes[id] = .init(window: window, stamp: native.stamp)
                stability.forget(windowID: id)
                budget.reset(windowID: id)
                if pausedWindows[id] !== window { pausedWindows[id] = nil }
            }

            let firstExe = rules.contains { $0.match.firstExeArgument != nil }
                ? CompatibilityProcessAccess.arguments(pid)?.first(where: { $0.lowercased().hasSuffix(".exe") }) : nil
            let identity = WorkspaceRuleWindowIdentity(
                process: processIdentity,
                firstExeArgument: firstExe, role: native.role, subrole: native.subrole, title: native.title)
            guard let rule = WorkspaceRuleEngine.firstMatch(rules: rules, identity: identity) else {
                setState(window, rule: nil, result: "unmatched-window")
                stability.forget(windowID: id)
                continue
            }
            if actual == rule.workspace {
                setState(window, rule: rule, result: "consistent")
                stability.forget(windowID: id)
                continue
            }
            if pausedWindows[id] === window {
                setState(window, rule: rule, result: "paused-window")
                stability.forget(windowID: id)
                continue
            }
            if budget.isBlocked(windowID: id) {
                setState(window, rule: rule, result: "paused-conflict-budget")
                stability.forget(windowID: id)
                continue
            }
            let capturedFrontPID = MacApp.resolvedNativePID(NSWorkspace.shared.frontmostApplication)
            let nativeFocus = await Task.detached(priority: .utility) {
                WorkspaceAffinityNativeFocus.read(fallbackPID: capturedFrontPID)
            }.value
            guard isCurrent(window, generation: generation, session: session) else { return changed }
            guard let nativeFocus, let frontPID = MacApp.resolvedNativePID(NSWorkspace.shared.frontmostApplication),
                  WorkspaceAffinityNativeFocusPolicy.isCurrent(capturedFrontmostPID: capturedFrontPID,
                      currentFrontmostPID: frontPID, snapshotPID: nativeFocus.pid) else {
                setState(window, rule: rule, result: "deferred-native-focus-unknown")
                stability.forget(windowID: id)
                continue
            }
            guard frontPID != pid, nativeFocus.windowID != id else {
                setState(window, rule: rule, result: "deferred-foreground-app")
                stability.forget(windowID: id)
                continue
            }
            if rule.policy == .observe {
                setState(window, rule: rule, result: "observed-drift")
                stability.forget(windowID: id)
                continue
            }
            let key = WorkspaceAffinityStability.Key(generation: generation, windowID: id, pid: pid,
                ruleID: rule.id, expected: rule.workspace, observed: actual)
            guard stability.observe(key: key, now: ProcessInfo.processInfo.systemUptime) else {
                setState(window, rule: rule, result: "confirming-drift")
                needsConfirmation = true
                continue
            }

            // A second native snapshot is intentional: a minimize/fullscreen,
            // replacement process or focus change after the first await must
            // invalidate the correction rather than be overwritten.
            let finalNative = await Task.detached(priority: .utility) {
                WorkspaceAffinityNativeSnapshot.read(pid: pid, windowID: id, readTitle: readTitle)
            }.value
            let capturedFinalFrontPID = MacApp.resolvedNativePID(NSWorkspace.shared.frontmostApplication)
            let finalFocus = await Task.detached(priority: .utility) {
                WorkspaceAffinityNativeFocus.read(fallbackPID: capturedFinalFrontPID)
            }.value
            guard isCurrent(window, generation: generation, session: session) else { return changed }
            guard let finalNative, finalNative.stamp == native.stamp,
                  verifiedProcessIdentity(window, snapshot: finalNative) == processIdentity,
                  finalNative.minimized == false, finalNative.fullscreen == false,
                  finalNative.role == native.role, finalNative.subrole == native.subrole,
                  finalNative.title == native.title,
                  let finalFocus, let currentPID = MacApp.resolvedNativePID(NSWorkspace.shared.frontmostApplication),
                  WorkspaceAffinityNativeFocusPolicy.isCurrent(capturedFrontmostPID: capturedFinalFrontPID,
                      currentFrontmostPID: currentPID, snapshotPID: finalFocus.pid),
                  currentPID != pid, finalFocus.windowID != id,
                  !window.macApp.nsApp.isHidden, window.nodeWorkspace?.name == actual,
                  case .standard = window.layoutReason,
                  window.parent?.kind == .floatingWindowsContainer || window.parent?.kind == .tilingContainer,
                  pausedWindows[id] !== window else {
                setState(window, rule: rule, result: "deferred-preflight-changed")
                stability.forget(windowID: id)
                continue
            }
            if workspaceCreationError(rule.workspace) != nil {
                setState(window, rule: rule, result: "blocked-workspace-not-persistent")
                continue
            }
            guard budget.allowAndRecord(windowID: id, now: ProcessInfo.processInfo.systemUptime) else {
                setState(window, rule: rule, result: "paused-conflict-budget")
                continue
            }
            let selectedWorkspace = focus.workspace
            let wasFloating = window.isFloating
            let destination = Workspace.get(byName: rule.workspace)
            WorkspaceJournal.record("correction-planned", window: window, ruleID: rule.id,
                                    expectedWorkspace: rule.workspace, result: "ready")
            // No await is permitted between the last guard and this model write.
            window.bind(to: wasFloating ? destination.floatingWindowsContainer : destination.rootTilingContainer,
                        adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            changed = true
            stability.forget(windowID: id)
            let result = window.nodeWorkspace === destination && window.isFloating == wasFloating &&
                focus.workspace === selectedWorkspace ? "corrected" : "correction-model-readback-failed"
            setState(window, rule: rule, result: result)
            WorkspaceJournal.record("correction-result", window: window, ruleID: rule.id,
                                    expectedWorkspace: rule.workspace, result: result)
        }
        if needsConfirmation { scheduleConfirmation() }
        return changed
    }

    private static func processCandidates(_ window: MacWindow) -> [WorkspaceRule] {
        let identity = CompatibilityProcessIdentity(window.macApp.nsApp)
        return config.workspaceRules.filter { rule in
            let m = rule.match
            if let value = m.appId, value != identity.appId { return false }
            if let value = m.appIdAbsent, value != (identity.appId == nil) { return false }
            if let value = m.bundlePath, !CompatibilityRuleEngine.pathsMatch(identity.bundlePath, value) { return false }
            if let value = m.executablePath, !CompatibilityRuleEngine.pathsMatch(identity.executablePath, value) { return false }
            return true
        }
    }

    /// NSRunningApplication metadata may outlive a process. Kernel path and
    /// start stamp must prove it still names the registered executable before
    /// metadata-derived app/bundle identity is accepted by the matcher.
    private static func verifiedProcessIdentity(_ window: MacWindow, snapshot: WorkspaceAffinityNativeSnapshot) -> CompatibilityProcessIdentity? {
        guard let metadataPath = window.macApp.execPath,
              CompatibilityRuleEngine.pathsMatch(snapshot.stamp.executablePath, metadataPath) else { return nil }
        return .init(appId: window.app.rawAppBundleId, bundlePath: window.macApp.bundlePath,
                     executablePath: snapshot.stamp.executablePath)
    }

    private static func isCurrent(_ window: MacWindow, generation: UInt64, session: UInt64) -> Bool {
        enabled && !Task.isCancelled && configurationGeneration == generation && sessions.generation == session &&
            MacWindow.allWindowsMap[window.windowId] === window && MacApp.allAppsMap[window.app.pid] === window.macApp &&
            !window.macApp.nsApp.isTerminated
    }

    private static func scheduleConfirmation() {
        guard debounce == nil, enabled else { return }
        debounceSerial &+= 1
        let serial = debounceSerial
        let generation = configurationGeneration
        debounce = Task.startUnstructured { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard serial == debounceSerial, generation == configurationGeneration, enabled else { return }
            debounce = nil
            await runWorkspaceAffinitySession()
        }
    }

    private static func setState(_ window: MacWindow, rule: WorkspaceRule?, result: String) {
        let state = WindowState(pid: window.app.pid, ruleID: rule?.id, expected: rule?.workspace,
                                observed: window.nodeWorkspace?.name, result: result)
        let previous = states[window.windowId]
        states[window.windowId] = state
        if previous?.pid != state.pid || previous?.ruleID != state.ruleID || previous?.expected != state.expected ||
            previous?.observed != state.observed || previous?.result != state.result {
            WorkspaceJournal.record("affinity-state", window: window, ruleID: rule?.id,
                                    expectedWorkspace: rule?.workspace, result: result)
        }
    }

    static func setPaused(_ paused: Bool, windowID: UInt32?) -> Bool {
        invalidateDedicatedFrames()
        if let windowID {
            guard let window = MacWindow.allWindowsMap[windowID] else { return false }
            pausedWindows[windowID] = paused ? window : nil
            stability.forget(windowID: windowID)
            if !paused { budget.reset(windowID: windowID) }
            WorkspaceJournal.record(paused ? "window-paused" : "window-resumed", window: window)
        } else {
            runtimePaused = paused
            stability.reset()
            WorkspaceJournal.record(paused ? "runtime-paused" : "runtime-resumed")
        }
        sessions.invalidate()
        debounce?.cancel()
        debounce = nil
        return true
    }

    static func diagnostics(windowID: UInt32? = nil) -> Json {
        let journal = WorkspaceJournal.status
        let ids = windowID.map { [$0] } ?? MacWindow.allWindowsMap.keys.sorted()
        let windows: [Json] = ids.compactMap { id in
            guard let window = MacWindow.allWindowsMap[id] else { return nil }
            let state = states[id]
            return .dict([
                "windowID": .int(Int(id)), "pid": .int(Int(window.app.pid)),
                "ruleID": .stringOrNull(state?.ruleID), "expectedWorkspace": .stringOrNull(state?.expected),
                "observedWorkspace": .stringOrNull(window.nodeWorkspace?.name),
                "state": .stringOrNull(state?.result),
                "paused": .bool(pausedWindows[id] === window),
                "conflictPaused": .bool(budget.isBlocked(windowID: id)),
            ])
        }
        return .dict([
            "enabledInConfig": .bool(config.workspaceRulesEnabled),
            "runtimePaused": .bool(runtimePaused),
            "effectiveEnabled": .bool(enabled),
            "configurationGeneration": .int(Int(configurationGeneration)),
            "logDirectory": .string(WorkspaceJournal.logDirectory.path),
            "journal": .dict([
                "writtenRecords": .int(Int(clamping: journal.writtenRecords)),
                "droppedRecords": .int(Int(clamping: journal.droppedRecords)),
                "writeFailures": .int(Int(clamping: journal.writeFailures)),
                "pendingRecords": .int(journal.pendingRecords),
            ]),
            "windows": .array(windows),
        ])
    }
}
