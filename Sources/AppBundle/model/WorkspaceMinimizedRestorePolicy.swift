/// Pure selection/cancellation state. Native writes live in the coordinator.
struct WorkspaceMinimizedRestorePolicy {
    static func preserveNativeLayout(eligible: Bool, minimized: Bool?, nativeFullscreen: Bool) -> Bool {
        eligible && minimized == nil && !nativeFullscreen
    }

    struct Entry: Equatable {
        let windowID: UInt32
        let pid: Int32
        var workspace: String
        var ruleID: String
        var lastFocused: UInt64
        var minimized: Bool
    }

    struct Request: Equatable {
        let generation: UInt64
        let entry: Entry
    }

    enum Outcome: String { case success, timeout, cancelled, identityMismatch = "identity-mismatch" }

    private(set) var entries: [UInt32: Entry] = [:]
    private(set) var request: Request?
    private(set) var outcomes: [UInt32: Outcome] = [:]
    private var clock: UInt64 = 0
    private var generation: UInt64 = 0
    private var focusedOrder: [UInt32: UInt64] = [:]

    mutating func noteFocused(_ windowID: UInt32) {
        clock &+= 1
        focusedOrder[windowID] = clock
        entries[windowID]?.lastFocused = clock
    }

    /// Native observation, not a restoration result. Dock/application recovery
    /// must not leave an already-visible window ahead of a minimized sibling.
    mutating func noteNotMinimized(_ windowID: UInt32) {
        entries[windowID]?.minimized = false
    }

    mutating func remember(windowID: UInt32, pid: Int32, workspace: String, ruleID: String?, floating: Bool) {
        guard floating, let ruleID else { return }
        let order = focusedOrder[windowID] ?? 0
        entries[windowID] = Entry(windowID: windowID, pid: pid, workspace: workspace,
            ruleID: ruleID, lastFocused: order, minimized: true)
    }

    mutating func begin(workspace: String, readOnly: Bool) -> Request? {
        guard !readOnly else { return nil }
        cancel()
        guard let entry = entries.values.filter({ $0.workspace == workspace && $0.minimized })
            .max(by: { ($0.lastFocused, $0.windowID) < ($1.lastFocused, $1.windowID) }) else { return nil }
        generation &+= 1
        let value = Request(generation: generation, entry: entry)
        request = value
        return value
    }

    func isCurrent(_ value: Request, workspace: String) -> Bool {
        request == value && value.entry.workspace == workspace &&
            entries[value.entry.windowID]?.pid == value.entry.pid
    }

    mutating func cancel() {
        if let request { outcomes[request.entry.windowID] = .cancelled }
        request = nil
        generation &+= 1
    }

    mutating func finish(_ value: Request, outcome: Outcome) {
        guard request == value else { return }
        outcomes[value.entry.windowID] = outcome
        if outcome == .success { entries[value.entry.windowID]?.minimized = false }
        request = nil
    }

    mutating func forget(_ windowID: UInt32) {
        if request?.entry.windowID == windowID { cancel() }
        entries[windowID] = nil
        focusedOrder[windowID] = nil
        outcomes[windowID] = nil
    }
}
