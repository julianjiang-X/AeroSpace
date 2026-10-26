@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceAffinityRuntimeTest: XCTestCase {
    func testQueuedFrameDequeuedAfterFenceInvalidationNeverStarts() {
        let fence = WorkspaceAffinityFrameFence()
        let job = RunLoopJob(.cancellable)
        fence.invalidate()
        XCTAssertFalse(fence.register(job))
        XCTAssertTrue(job.isCancelled)
        var writes = 0
        if !job.isCancelled { writes += 1 }
        XCTAssertEqual(writes, 0)
    }

    func testNewSessionFenceCancelsOnlyItsAlreadyDequeuedFrameJobs() {
        let fence = WorkspaceAffinityFrameFence()
        let position = RunLoopJob(.cancellable)
        let size = RunLoopJob(.cancellable)
        let ordinaryLayout = RunLoopJob(.cancellable)
        XCTAssertTrue(fence.register(position))
        XCTAssertTrue(fence.register(size))
        XCTAssertFalse(position.isCancelled)
        fence.invalidate()
        XCTAssertTrue(position.isCancelled)
        XCTAssertTrue(size.isCancelled)
        XCTAssertFalse(ordinaryLayout.isCancelled)
        // Idempotent invalidation does not reach unrelated native jobs.
        fence.invalidate()
        XCTAssertFalse(ordinaryLayout.isCancelled)
    }

    func testFenceStaysValidAfterEnqueueUntilSupersededAndForgetsCompletedJobs() {
        let fence = WorkspaceAffinityFrameFence()
        let completed = RunLoopJob(.cancellable)
        XCTAssertTrue(fence.register(completed))
        fence.unregister(completed)
        let queuedLater = RunLoopJob(.cancellable)
        XCTAssertTrue(fence.register(queuedLater))
        XCTAssertFalse(queuedLater.isCancelled)
        fence.invalidate()
        XCTAssertFalse(completed.isCancelled)
        XCTAssertTrue(queuedLater.isCancelled)
    }

    func testChangedOldPassCannotLayoutAfterNewSessionInterruptsNativeRead() {
        var gate = WorkspaceAffinitySessionGate()
        let oldPass = gate.begin()
        let changedEarlierWindow = true
        XCTAssertTrue(gate.allowsLayout(oldPass, activeDepth: 1, independent: true, cancelled: false))

        // The old pass changed A and then suspended while reading B. A newer
        // session is now temporarily rebuilding the model at nested depth.
        let newSession = gate.begin()
        XCTAssertFalse(changedEarlierWindow && gate.allowsLayout(oldPass, activeDepth: 2, independent: true, cancelled: false))
        // Returning to exclusive depth does not make the old token current.
        XCTAssertFalse(gate.allowsLayout(oldPass, activeDepth: 1, independent: true, cancelled: false))
        XCTAssertTrue(gate.allowsLayout(newSession, activeDepth: 1, independent: true, cancelled: false))
    }

    func testLatestUserSessionKeepsLayoutPermissionWhileOldPassUnwinds() {
        var gate = WorkspaceAffinitySessionGate()
        _ = gate.begin()
        let latestUserSession = gate.begin()
        // New automatic enforcement must wait, but a priority user command's
        // ordinary layout must not disappear while the canceled task unwinds.
        XCTAssertFalse(gate.allowsLayout(latestUserSession, activeDepth: 2, independent: true, cancelled: false))
        XCTAssertTrue(gate.allowsLayout(latestUserSession, activeDepth: 2, independent: false, cancelled: false))
        XCTAssertFalse(gate.allowsLayout(latestUserSession, activeDepth: 1, independent: false, cancelled: true))
    }

    func testIndependentFrameContinuationRejectsEveryPostAwaitStaleWrite() {
        var gate = WorkspaceAffinitySessionGate()
        let token = gate.begin()
        var writes = 0
        let canContinue = { gate.allowsLayout(token, activeDepth: 1, independent: true, cancelled: false) }
        if canContinue() { writes += 1 }
        // Models a newer session beginning during an awaited native frame read.
        _ = gate.begin()
        if canContinue() { writes += 1 }
        if canContinue() { writes += 1 }
        XCTAssertEqual(writes, 1)
    }

    func testExplicitInvalidationCancelsEvenAnOtherwiseExclusivePass() {
        var gate = WorkspaceAffinitySessionGate()
        let token = gate.begin()
        gate.invalidate()
        XCTAssertFalse(gate.allowsLayout(token, activeDepth: 1, independent: true, cancelled: false))
    }

    func testEveryQueryEntryStaysObservationOnly() throws {
        let queries: [[String]] = [
            ["list-windows", "--all"], ["list-workspaces", "--all"],
            ["list-apps"], ["list-monitors"], ["config", "--config-path"],
            ["debug-windows", "--window-id", "123"],
            ["workspace-rule", "status"], ["workspace-rule", "status", "--window-id", "123", "--json"],
            ["reload-config", "--dry-run", "--no-gui"],
            ["eval", "list-windows --all"],
        ]
        for raw in queries {
            let args = try XCTUnwrap(parseCmdArgs(raw.slice).cmdOrNil)
            XCTAssertFalse(WorkspaceAffinity.eventAllowsCorrection(.socketServer(args)), raw.joined(separator: " "))
        }
        XCTAssertFalse(WorkspaceAffinity.eventAllowsCorrection(.hotkeyBinding))
        XCTAssertFalse(WorkspaceAffinity.eventAllowsCorrection(.menuBarButton))
    }

    func testExplicitMutationsAndIndependentEventsCanObserveOwnership() throws {
        let mutations: [[String]] = [
            ["move-node-to-workspace", "--window-id", "123", "Home"],
            ["workspace", "Home"], ["reload-config", "--no-gui"],
            ["workspace-rule", "pause", "--window-id", "123"],
            ["workspace-rule", "resume"],
        ]
        for raw in mutations {
            let args = try XCTUnwrap(parseCmdArgs(raw.slice).cmdOrNil)
            XCTAssertTrue(WorkspaceAffinity.eventAllowsCorrection(.socketServer(args)), raw.joined(separator: " "))
        }
        XCTAssertTrue(WorkspaceAffinity.eventAllowsCorrection(.ax("AXWindowCreated")))
        XCTAssertTrue(WorkspaceAffinity.eventAllowsCorrection(.globalObserver("workspace-affinity")))
    }

    func testWorkspaceRuleCommandHasExplicitControlAndReadOnlyStatus() throws {
        let status = try XCTUnwrap(parseCmdArgs(["workspace-rule", "status"].slice).cmdOrNil as? WorkspaceRuleCmdArgs)
        XCTAssertEqual(status.action.val, .status)
        XCTAssertNil(status.windowId)
        let pause = try XCTUnwrap(parseCmdArgs(["workspace-rule", "pause", "--window-id", "987"].slice).cmdOrNil as? WorkspaceRuleCmdArgs)
        XCTAssertEqual(pause.action.val, .pause)
        XCTAssertEqual(pause.windowId, 987)
        XCTAssertNil(parseCmdArgs(["workspace-rule", "force"].slice).cmdOrNil)
        XCTAssertNil(parseCmdArgs(["workspace-rule", "pause", "--window-id", "invalid"].slice).cmdOrNil)
    }
}
