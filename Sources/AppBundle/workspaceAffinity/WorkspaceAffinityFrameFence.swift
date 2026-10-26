import Foundation

/// Only layouts applying an affinity correction receive this lease. Each AX-thread job
/// registers when dequeued, so invalidation covers both already-running jobs and
/// jobs that have not started yet without touching ordinary layout jobs.
final class WorkspaceAffinityFrameFence: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var jobs: [ObjectIdentifier: RunLoopJob] = [:]

    var isActive: Bool { lock.withLock { active } }

    @discardableResult
    func register(_ job: RunLoopJob) -> Bool {
        lock.withLock {
            guard active else {
                job.cancel()
                return false
            }
            jobs[ObjectIdentifier(job)] = job
            return true
        }
    }

    func unregister(_ job: RunLoopJob) {
        lock.withLock { _ = jobs.removeValue(forKey: ObjectIdentifier(job)) }
    }

    func invalidate() {
        lock.withLock {
            active = false
            // Cancellation is a bounded atomic flag operation, never an AX
            // call. Hold the lock until all registered jobs see cancellation.
            for job in jobs.values { job.cancel() }
            jobs.removeAll()
        }
    }
}

enum WorkspaceAffinityFrameContext {
    @TaskLocal static var current: WorkspaceAffinityFrameFence? = nil
}
