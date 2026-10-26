import AppKit
import Common
import Foundation

private struct WorkspaceJournalContext: Sendable {
    let transactionID: String
    let source: String
    var command: String?
    var reason: String?
}
@TaskLocal private var workspaceJournalContext: WorkspaceJournalContext?

/// Audit only. This layer observes model changes; it never changes a workspace,
/// executes an AX call, focuses an application or schedules a correction.
@MainActor
enum WorkspaceJournal {
    private static var store: WorkspaceJournalStore?
    private static var sequence: UInt64 = 0
    private static var transactionCounter: UInt64 = 0
    private static var transactions = WorkspaceJournalTransactionRegistry()
    private static let runID = UUID().uuidString
    private static var bindingProvenance = WorkspaceJournalProvenanceTracker<WorkspaceJournalContext>()

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AeroSpace/workspace-affinity", isDirectory: true)
    }

    static var status: WorkspaceJournalStore.Status { store?.status ?? .init() }

    private static var enabled: Bool {
        config.workspaceRulesEnabled && !serverArgs.isReadOnly && !isUnitTest
    }

    private static var activeContext: WorkspaceJournalContext? {
        guard let context = workspaceJournalContext,
              transactions.mayReuse(context.transactionID, forceNew: false) else { return nil }
        return context
    }

    /// Wrap the complete model/refresh session, rather than each bind. Nested
    /// commands share the transaction so a container's indirect leaf moves are
    /// compared only after all restoration/normalization has settled.
    static func withTransaction<T>(
        _ event: RefreshSessionEvent,
        body: @MainActor () async throws -> T,
    ) async rethrows -> T {
        try await runTransaction(event, forceNew: false, body: body)
    }

    /// Independent model sessions must call this at their entry point. Task.init
    /// inherits task locals, including the context of an already-ended session.
    /// Commands/cache helpers within the same session still use nested reuse.
    static func withNewTransaction<T>(
        _ event: RefreshSessionEvent,
        body: @MainActor () async throws -> T,
    ) async rethrows -> T {
        try await runTransaction(event, forceNew: true, body: body)
    }

    private static func runTransaction<T>(
        _ event: RefreshSessionEvent,
        forceNew: Bool,
        body: @MainActor () async throws -> T,
    ) async rethrows -> T {
        guard enabled else { return try await body() }
        if transactions.mayReuse(workspaceJournalContext?.transactionID, forceNew: forceNew) {
            return try await body()
        }
        transactionCounter &+= 1
        let source = safeSource(event)
        let context = WorkspaceJournalContext(transactionID: "\(runID)-\(transactionCounter)",
            source: source.source, command: source.command, reason: nil)
        let before = snapshot()
        let startingRevision = bindingProvenance.revision
        return try await $workspaceJournalContext.withValue(context) {
            transactions.begin(context.transactionID)
            record("transaction-begin")
            defer {
                emitTransitions(before: before, after: snapshot(), since: startingRevision)
                record("transaction-end")
                transactions.end(context.transactionID)
            }
            return try await body()
        }
    }

    static func withReason<T>(_ reason: String, body: @MainActor () async throws -> T) async rethrows -> T {
        guard enabled else { return try await body() }
        var context = activeContext ?? detachedContext()
        context.reason = reason
        return try await $workspaceJournalContext.withValue(context) { try await body() }
    }

    static func withCommand<T>(
        _ kind: CmdKind,
        requestedWorkspace: String? = nil,
        body: @MainActor () async throws -> T,
    ) async rethrows -> T {
        guard enabled else { return try await body() }
        var context = activeContext ?? detachedContext()
        context.command = kind.rawValue
        return try await $workspaceJournalContext.withValue(context) {
            record("command-begin", expectedWorkspace: requestedWorkspace)
            defer { record("command-end", expectedWorkspace: requestedWorkspace) }
            return try await body()
        }
    }

    /// The strings passed here are operation categories/enum values from code,
    /// never command descriptions, user content, window titles or argv.
    static func record(
        _ kind: String,
        window: MacWindow? = nil,
        ruleID: String? = nil,
        expectedWorkspace: String? = nil,
        result: String? = nil,
        reason: String? = nil,
    ) {
        guard enabled else { return }
        let value = window.map(state)
        emit(kind, state: value, ruleID: ruleID, expectedWorkspace: expectedWorkspace,
             result: result, reason: reason)
    }

    /// bind may move a whole container, not just one window. Its leaf list is
    /// captured before unbinding, then compared after reparenting. These events
    /// are explicitly intermediate; policy must use the terminal snapshot.
    static func beforeBind(_ node: TreeNode) -> [UInt32: WorkspaceJournalWindowState] {
        guard enabled else { return [:] }
        return Dictionary(uniqueKeysWithValues: node.allLeafWindowsRecursive.compactMap { window in
            guard let macWindow = window as? MacWindow else { return nil }
            return (window.windowId, state(macWindow))
        })
    }

    static func afterBind(_ node: TreeNode, before: [UInt32: WorkspaceJournalWindowState]) {
        guard enabled, !before.isEmpty else { return }
        let after = beforeBind(node)
        let cause = activeContext ?? detachedContext()
        for transition in WorkspaceJournalTransition.diff(before: before, after: after) {
            bindingProvenance.record(transition, cause: cause)
            emit("bind-intermediate", state: transition.after ?? transition.before,
                 before: transition.before, after: transition.after,
                 result: transition.kind.rawValue,
                 reason: cause.reason ?? "model-rebind", provenance: cause)
        }
    }

    private static func snapshot() -> [UInt32: WorkspaceJournalWindowState] {
        Dictionary(uniqueKeysWithValues: MacWindow.allWindows.map { ($0.windowId, state($0)) })
    }

    private static func state(_ window: MacWindow) -> WorkspaceJournalWindowState {
        WorkspaceJournalWindowState(windowID: window.windowId, pid: window.app.pid,
            processStart: NSRunningApplication(processIdentifier: window.app.pid)?.launchDate?.timeIntervalSince1970,
            appID: window.app.rawAppBundleId, workspace: window.nodeWorkspace?.name,
            parent: window.parent.map { String(describing: type(of: $0)) })
    }

    private static func emitTransitions(
        before: [UInt32: WorkspaceJournalWindowState],
        after: [UInt32: WorkspaceJournalWindowState],
        since startingRevision: UInt64,
    ) {
        for transition in WorkspaceJournalTransition.diff(before: before, after: after) {
            // Sessions may interleave. A parent-only bind is not evidence of a
            // workspace move; require its own complete old/new workspace pair.
            let cause = bindingProvenance.cause(for: transition, since: startingRevision)
            emit("window-\(transition.kind.rawValue)", state: transition.after ?? transition.before,
                 before: transition.before, after: transition.after,
                 result: "terminal-snapshot",
                 reason: cause?.reason ?? (cause == nil ? "unattributed-terminal-difference" : "model-rebind"),
                 provenance: cause, terminalObservation: true)
        }
        bindingProvenance.retainWindowIDs(Set(after.keys))
    }

    private static func detachedContext() -> WorkspaceJournalContext {
        transactionCounter &+= 1
        // With no active owner, an inherited event/context is not proof of
        // current causality. Never reuse the ID/source of an ended transaction.
        return WorkspaceJournalContext(transactionID: "\(runID)-\(transactionCounter)",
            source: "unknown", command: nil, reason: nil)
    }

    private static func safeSource(_ event: RefreshSessionEvent) -> (source: String, command: String?) {
        switch event {
            case .socketServer(let args): ("external-command", type(of: args).info.kind.rawValue)
            case .hotkeyBinding: ("aerospace-hotkey", nil)
            case .startup: ("startup", nil)
            case .configAutoReload: ("config-reload", nil)
            case .ax: ("accessibility-event", nil)
            case .globalObserver: ("system-observer", nil)
            case .globalObserverLeftMouseUp: ("mouse-release", nil)
            case .menuBarButton: ("menu", nil)
            case .resetManipulatedWithMouse: ("mouse-layout", nil)
            case .focusFollowsMouse: ("focus-follows-mouse", nil)
        }
    }

    private static func configurationFingerprint() -> String {
        config.sourceFingerprint
    }

    private static func emit(
        _ kind: String,
        state: WorkspaceJournalWindowState? = nil,
        before: WorkspaceJournalWindowState? = nil,
        after: WorkspaceJournalWindowState? = nil,
        ruleID: String? = nil,
        expectedWorkspace: String? = nil,
        result: String? = nil,
        reason: String? = nil,
        provenance: WorkspaceJournalContext? = nil,
        terminalObservation: Bool = false,
    ) {
        guard enabled else { return }
        if store == nil { store = WorkspaceJournalStore(options: .init(root: logDirectory)) }
        sequence &+= 1
        let context = activeContext ?? detachedContext()
        store?.enqueue(WorkspaceJournalEvent(sequence: sequence, kind: kind,
            transactionID: context.transactionID,
            causeTransactionID: provenance?.transactionID,
            source: provenance?.source ?? (terminalObservation ? "terminal-observation" : context.source),
            command: provenance?.command ?? (terminalObservation ? nil : context.command),
            reason: reason ?? context.reason, build: "\(aeroSpaceAppVersion) \(gitHash)",
            configuration: configurationFingerprint(), windowID: state?.windowID,
            pid: state?.pid, processStart: state?.processStart, appID: state?.appID,
            ruleID: ruleID, oldWorkspace: before?.workspace,
            newWorkspace: after?.workspace ?? state?.workspace,
            expectedWorkspace: expectedWorkspace, oldParent: before?.parent,
            newParent: after?.parent ?? state?.parent, result: result))
    }
}
