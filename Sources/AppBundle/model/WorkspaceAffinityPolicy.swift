import Foundation

/// A settled model observation must repeat before a correction becomes eligible.
/// Async task ownership, native-read guards and foreground deferral live outside
/// this state. Query paths must not call observe merely to inspect a window.
struct WorkspaceAffinityStability {
    struct Key: Sendable, Hashable {
        let generation: UInt64
        let windowID: UInt32
        let pid: Int32
        let ruleID: String
        let expected: String
        let observed: String
    }

    private struct Entry {
        let key: Key
        let since: TimeInterval
    }

    private var entries: [UInt32: Entry] = [:]
    private let interval: TimeInterval = 0.25

    mutating func observe(key: Key, now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        if let entry = entries[key.windowID], entry.key == key, now >= entry.since {
            return now - entry.since >= interval
        }
        entries[key.windowID] = Entry(key: key, since: now)
        return false
    }

    mutating func forget(windowID: UInt32) { entries[windowID] = nil }
    mutating func reset() { entries.removeAll() }
}

/// A repeated external conflict must stop instead of pulling a window forever.
/// Three attempts within thirty seconds consume the window's budget until an
/// explicit resume, identity/configuration change, or window death resets it.
struct WorkspaceAffinityCorrectionBudget {
    private struct Entry {
        var attempts: [TimeInterval] = []
        var blocked = false
    }

    private var entries: [UInt32: Entry] = [:]
    private let interval: TimeInterval = 30
    private let limit = 3

    mutating func allowAndRecord(windowID: UInt32, now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        var entry = entries[windowID] ?? Entry()
        guard !entry.blocked else { return false }
        if let last = entry.attempts.last, now < last { return false }
        entry.attempts.removeAll { now - $0 > interval }
        guard entry.attempts.count < limit else {
            entry.blocked = true
            entries[windowID] = entry
            return false
        }
        entry.attempts.append(now)
        if entry.attempts.count == limit { entry.blocked = true }
        entries[windowID] = entry
        return true
    }

    func isBlocked(windowID: UInt32) -> Bool { entries[windowID]?.blocked == true }
    mutating func reset(windowID: UInt32) { entries[windowID] = nil }
    mutating func prune(alive: Set<UInt32>) { entries = entries.filter { alive.contains($0.key) } }
}
