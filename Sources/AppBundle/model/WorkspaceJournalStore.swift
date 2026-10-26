import Foundation

/// Fixed metadata schema: no window title, application body, stdin or process arguments.
struct WorkspaceJournalEvent: Codable, Equatable, Sendable {
    var timestamp: Date
    var sequence: UInt64
    var kind: String
    var transactionID: String?
    var causeTransactionID: String?
    var source: String
    var command: String?
    var reason: String?
    var build: String
    var configuration: String
    var windowID: UInt32?
    var pid: Int32?
    var processStart: TimeInterval?
    var appID: String?
    var ruleID: String?
    var oldWorkspace: String?
    var newWorkspace: String?
    var expectedWorkspace: String?
    var oldParent: String?
    var newParent: String?
    var result: String?

    init(timestamp: Date = Date(), sequence: UInt64 = 0, kind: String,
         transactionID: String? = nil, causeTransactionID: String? = nil, source: String = "unknown", command: String? = nil,
         reason: String? = nil, build: String = "unknown", configuration: String = "unknown",
         windowID: UInt32? = nil, pid: Int32? = nil, processStart: TimeInterval? = nil,
         appID: String? = nil, ruleID: String? = nil, oldWorkspace: String? = nil,
         newWorkspace: String? = nil, expectedWorkspace: String? = nil,
         oldParent: String? = nil, newParent: String? = nil, result: String? = nil) {
        self.timestamp = timestamp
        self.sequence = sequence
        self.kind = String(kind.prefix(160))
        self.transactionID = transactionID
        self.causeTransactionID = causeTransactionID
        self.source = String(source.prefix(160))
        self.command = command.map { String($0.prefix(160)) }
        self.reason = reason.map { String($0.prefix(160)) }
        self.build = String(build.prefix(160))
        self.configuration = String(configuration.prefix(160))
        self.windowID = windowID
        self.pid = pid
        self.processStart = processStart
        self.appID = appID.map { String($0.prefix(512)) }
        self.ruleID = ruleID.map { String($0.prefix(512)) }
        self.oldWorkspace = oldWorkspace.map { String($0.prefix(512)) }
        self.newWorkspace = newWorkspace.map { String($0.prefix(512)) }
        self.expectedWorkspace = expectedWorkspace.map { String($0.prefix(512)) }
        self.oldParent = oldParent.map { String($0.prefix(160)) }
        self.newParent = newParent.map { String($0.prefix(160)) }
        self.result = result.map { String($0.prefix(160)) }
    }
}

/// Disk work is serialized off the model actor. Only a bounded number of encoded
/// records may be pending; a slow or unwritable disk never blocks window actions.
final class WorkspaceJournalStore: @unchecked Sendable {
    struct Options: Sendable {
        var root: URL
        var retention: TimeInterval = 30 * 24 * 60 * 60
        var maxTotalBytes: Int = 1_073_741_824
        var maxFileBytes: Int = 8_388_608
        var maxPendingRecords: Int = 256
        var maxPendingBytes: Int = 1_048_576
    }
    struct Status: Equatable, Sendable {
        var pendingRecords = 0
        var pendingBytes = 0
        var writtenRecords: UInt64 = 0
        var droppedRecords: UInt64 = 0
        var writeFailures: UInt64 = 0
    }

    private let options: Options
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "aerospace.workspace-journal", qos: .utility)
    private let lock = NSLock()
    private var state = Status()
    // These members are used on queue only.
    private var activeURL: URL?
    private var activeBytes = 0
    private var activeDay: Int?
    private var lastPrune: Date?
    private var knownTotalBytes: Int?
    private var serial: UInt64 = 0
    private let writerID = UUID().uuidString

    init(options: Options, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.options = options
        self.clock = clock
    }

    @discardableResult
    func enqueue(_ event: WorkspaceJournalEvent) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(event) else {
            lock.withLock { state.droppedRecords &+= 1 }
            return false
        }
        data.append(0x0a)
        let byteCount = data.count
        guard byteCount <= max(0, min(options.maxFileBytes, options.maxTotalBytes)) else {
            lock.withLock { state.droppedRecords &+= 1 }
            return false
        }
        let accepted = lock.withLock { () -> Bool in
            guard state.pendingRecords < options.maxPendingRecords,
                  state.pendingBytes + byteCount <= options.maxPendingBytes else {
                state.droppedRecords &+= 1
                return false
            }
            state.pendingRecords += 1
            state.pendingBytes += byteCount
            return true
        }
        guard accepted else { return false }
        let encoded = data
        queue.async { [self] in
            defer {
                lock.withLock {
                    state.pendingRecords -= 1
                    state.pendingBytes -= byteCount
                }
            }
            do {
                try append(encoded, now: clock())
                lock.withLock { state.writtenRecords &+= 1 }
            } catch {
                // Fail closed for the current record, retry future records.
                // Never propagate a filesystem failure into the model actor.
                lock.withLock { state.writeFailures &+= 1 }
                activeURL = nil
                activeBytes = 0
            }
        }
        return true
    }

    var status: Status { lock.withLock { state } }

    /// Test/diagnostic synchronization only. The window-management path never calls this.
    func flushForTesting() { queue.sync {} }

    private func append(_ data: Data, now: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: options.root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let day = Int(now.timeIntervalSince1970 / 86_400)
        let rotating = activeURL == nil || activeDay != day || activeBytes + data.count > options.maxFileBytes
        if rotating {
            serial &+= 1
            activeURL = options.root.appendingPathComponent("workspace-\(Int(now.timeIntervalSince1970))-\(writerID)-\(serial).jsonl")
            activeBytes = 0
            activeDay = day
        }
        guard let target = activeURL else { throw StoreError.noActiveFile }
        if !fm.fileExists(atPath: target.path) {
            guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw StoreError.cannotCreateFile
            }
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
        activeBytes += data.count
        if let total = knownTotalBytes { knownTotalBytes = total + data.count }
        // Deterministic clock injection also makes retention independent of the
        // execution host's timezone. New files are not mistaken for stale files.
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
        if rotating || knownTotalBytes.map({ $0 > options.maxTotalBytes }) != false || lastPrune.map({ now.timeIntervalSince($0) >= 60 }) != false {
            try prune(now: now)
            lastPrune = now
        }
    }

    private func prune(now: Date) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try fm.contentsOfDirectory(at: options.root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var files: [(url: URL, size: Int, date: Date)] = []
        for url in urls where url.lastPathComponent.hasPrefix("workspace-") && url.pathExtension == "jsonl" {
            let value = try url.resourceValues(forKeys: keys)
            guard value.isRegularFile == true, value.isSymbolicLink != true else { continue }
            let date = value.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > options.retention {
                try fm.removeItem(at: url)
                if url == activeURL { activeURL = nil; activeBytes = 0 }
            } else {
                files.append((url, value.fileSize ?? 0, date))
            }
        }
        files.sort { ($0.date, $0.url.lastPathComponent) < ($1.date, $1.url.lastPathComponent) }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total > options.maxTotalBytes {
            try fm.removeItem(at: file.url)
            total -= file.size
            if file.url == activeURL { activeURL = nil; activeBytes = 0 }
        }
        knownTotalBytes = total
    }

    private enum StoreError: Error { case noActiveFile, cannotCreateFile }
}

/// Pure terminal-state comparison, including indirect moves caused by reparenting
/// a whole container. Intermediate bind operations are a separate event stream.
struct WorkspaceJournalWindowState: Equatable, Sendable {
    let windowID: UInt32
    let pid: Int32
    let processStart: TimeInterval?
    let appID: String?
    let workspace: String?
    let parent: String?
}

struct WorkspaceJournalTransition: Equatable, Sendable {
    enum Kind: String, Sendable { case appeared, disappeared, moved, reparented, identityReplaced = "identity-replaced" }
    let kind: Kind
    let before: WorkspaceJournalWindowState?
    let after: WorkspaceJournalWindowState?

    static func diff(before: [UInt32: WorkspaceJournalWindowState], after: [UInt32: WorkspaceJournalWindowState]) -> [Self] {
        Set(before.keys).union(after.keys).sorted().compactMap { id in
            let old = before[id], new = after[id]
            let kind: Kind
            switch (old, new) {
                case (nil, .some): kind = .appeared
                case (.some, nil): kind = .disappeared
                case let (old?, new?):
                    if old.pid != new.pid || (old.processStart != nil && new.processStart != nil && old.processStart != new.processStart) { kind = .identityReplaced }
                    else if old.workspace != new.workspace { kind = .moved }
                    else if old.parent != new.parent { kind = .reparented }
                    else { return nil }
                case (nil, nil): return nil
            }
            return Self(kind: kind, before: old, after: new)
        }
    }
}

/// Separate provenance for workspace moves and in-workspace parent changes.
/// A later focus/layout rebind cannot become the cause of an earlier move.
/// Attribution is deliberately conservative: if a terminal delta spans several
/// different workspace hops, no single bind is claimed as its complete cause.
struct WorkspaceJournalProvenanceTracker<Cause: Sendable>: Sendable {
    private struct Binding: Sendable {
        let transition: WorkspaceJournalTransition
        let cause: Cause
        let revision: UInt64
    }
    private var workspaceMoves: [UInt32: Binding] = [:]
    private var parentChanges: [UInt32: Binding] = [:]
    private(set) var revision: UInt64 = 0

    mutating func record(_ transition: WorkspaceJournalTransition, cause: Cause) {
        revision &+= 1
        let id = transition.after?.windowID ?? transition.before?.windowID
        guard let id else { return }
        let binding = Binding(transition: transition, cause: cause, revision: revision)
        switch transition.kind {
            case .moved:
                workspaceMoves[id] = binding
                parentChanges[id] = nil
            case .reparented:
                parentChanges[id] = binding
            case .appeared, .disappeared, .identityReplaced:
                workspaceMoves[id] = nil
                parentChanges[id] = nil
        }
    }

    func cause(for terminal: WorkspaceJournalTransition, since startingRevision: UInt64) -> Cause? {
        guard let old = terminal.before, let new = terminal.after,
              sameIdentity(old, new) else { return nil }
        let binding: Binding?
        switch terminal.kind {
            case .moved: binding = workspaceMoves[new.windowID]
            case .reparented: binding = parentChanges[new.windowID]
            case .appeared, .disappeared, .identityReplaced: return nil
        }
        guard let binding, binding.revision > startingRevision,
              let boundOld = binding.transition.before, let boundNew = binding.transition.after,
              sameIdentity(old, boundOld), sameIdentity(new, boundNew),
              old.workspace == boundOld.workspace, new.workspace == boundNew.workspace else { return nil }
        if terminal.kind == .reparented {
            guard old.parent == boundOld.parent, new.parent == boundNew.parent else { return nil }
        }
        return binding.cause
    }

    mutating func retainWindowIDs(_ ids: Set<UInt32>) {
        workspaceMoves = workspaceMoves.filter { ids.contains($0.key) }
        parentChanges = parentChanges.filter { ids.contains($0.key) }
    }

    private func sameIdentity(_ lhs: WorkspaceJournalWindowState, _ rhs: WorkspaceJournalWindowState) -> Bool {
        lhs.windowID == rhs.windowID && lhs.pid == rhs.pid &&
            lhs.processStart == rhs.processStart && lhs.appID == rhs.appID
    }
}

/// Task-local values can outlive their originating transaction when inherited
/// by an unstructured task. Reuse is only valid for a still-active nested scope;
/// independent model sessions always open a new transaction even while the
/// originating parent remains active.
struct WorkspaceJournalTransactionRegistry {
    private var active: Set<String> = []

    mutating func begin(_ transactionID: String) { active.insert(transactionID) }
    mutating func end(_ transactionID: String) { active.remove(transactionID) }

    func mayReuse(_ inheritedTransactionID: String?, forceNew: Bool) -> Bool {
        guard !forceNew, let inheritedTransactionID else { return false }
        return active.contains(inheritedTransactionID)
    }
}
