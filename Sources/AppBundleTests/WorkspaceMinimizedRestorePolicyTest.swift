@testable import AppBundle
import XCTest

final class WorkspaceMinimizedRestorePolicyTest: XCTestCase {
    func testDefaultAndNonFloatingWindowsNeverOptIn() {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: nil, floating: true)
        state.remember(windowID: 2, pid: 102, workspace: "A", ruleID: "precise-rule", floating: false)
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertNil(state.begin(workspace: "A", readOnly: false))
        XCTAssertTrue(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: true, minimized: nil, nativeFullscreen: false))
        XCTAssertFalse(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: false, minimized: nil, nativeFullscreen: false))
        XCTAssertFalse(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: true, minimized: false, nativeFullscreen: false))
        XCTAssertFalse(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: true, minimized: true, nativeFullscreen: false))
        XCTAssertFalse(WorkspaceMinimizedRestorePolicy.preserveNativeLayout(eligible: true, minimized: nil, nativeFullscreen: true))
    }

    func testOnlyExplicitSelectionStartsRestoreAndPreservesOrigin() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.noteFocused(1)
        state.remember(windowID: 1, pid: 101, workspace: "Origin", ruleID: "precise-rule", floating: true)
        XCTAssertNil(state.request)
        XCTAssertEqual(state.entries[1]?.workspace, "Origin")
        XCTAssertNil(state.begin(workspace: "Other", readOnly: false))
        let request = try XCTUnwrap(state.begin(workspace: "Origin", readOnly: false))
        XCTAssertEqual(request.entry.workspace, "Origin")
        XCTAssertEqual(request.entry.ruleID, "precise-rule")
        XCTAssertTrue(state.isCurrent(request, workspace: "Origin"))
        XCTAssertFalse(state.isCurrent(request, workspace: "Other"))
    }

    func testMostRecentEligibleWindowWinsWithinRequestedWorkspace() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.noteFocused(2)
        state.noteFocused(1)
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        state.remember(windowID: 2, pid: 102, workspace: "A", ruleID: "two", floating: true)
        state.noteFocused(3)
        state.remember(windowID: 3, pid: 103, workspace: "B", ruleID: "three", floating: true)
        let request = try XCTUnwrap(state.begin(workspace: "A", readOnly: false))
        XCTAssertEqual(request.entry.windowID, 1)
        XCTAssertEqual(state.entries.count, 3)
    }

    func testReadOnlySelectionDoesNotStartOrCancelARequest() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        XCTAssertNil(state.begin(workspace: "A", readOnly: true))
        XCTAssertNil(state.request)
        let request = try XCTUnwrap(state.begin(workspace: "A", readOnly: false))
        XCTAssertNil(state.begin(workspace: "B", readOnly: true))
        XCTAssertEqual(state.request, request)
    }

    func testSameWorkspaceRetryIsExplicitAndSuccessIsNotRepeated() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        let first = try XCTUnwrap(state.begin(workspace: "A", readOnly: false))
        state.finish(first, outcome: .timeout)
        XCTAssertNil(state.request)
        XCTAssertEqual(state.entries[1]?.minimized, true)
        XCTAssertEqual(state.outcomes[1], .timeout)
        let retry = try XCTUnwrap(state.begin(workspace: "A", readOnly: false))
        XCTAssertFalse(state.isCurrent(first, workspace: "A"))
        XCTAssertTrue(state.isCurrent(retry, workspace: "A"))
        state.finish(retry, outcome: .success)
        XCTAssertEqual(state.entries[1]?.workspace, "A")
        XCTAssertEqual(state.entries[1]?.minimized, false)
        XCTAssertNil(state.begin(workspace: "A", readOnly: false))
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        XCTAssertNotNil(state.begin(workspace: "A", readOnly: false))
    }

    func testLatestRequestCancelsOldAndStaleCompletionCannotWin() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        state.remember(windowID: 2, pid: 102, workspace: "B", ruleID: "two", floating: true)
        let old = try XCTUnwrap(state.begin(workspace: "A", readOnly: false))
        let latest = try XCTUnwrap(state.begin(workspace: "B", readOnly: false))
        XCTAssertFalse(state.isCurrent(old, workspace: "A"))
        XCTAssertEqual(state.outcomes[1], .cancelled)
        state.finish(old, outcome: .success)
        XCTAssertEqual(state.request, latest)
        XCTAssertEqual(state.entries[1]?.minimized, true)
        state.cancel()
        XCTAssertFalse(state.isCurrent(latest, workspace: "B"))
        XCTAssertEqual(state.outcomes[2], .cancelled)
    }

    func testFailedIdentityRetainsMinimizedOriginAndNoAutomaticRetry() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "Origin", ruleID: "one", floating: true)
        let request = try XCTUnwrap(state.begin(workspace: "Origin", readOnly: false))
        state.finish(request, outcome: .identityMismatch)
        XCTAssertEqual(state.entries[1]?.minimized, true)
        XCTAssertEqual(state.entries[1]?.workspace, "Origin")
        XCTAssertEqual(state.outcomes[1], .identityMismatch)
        XCTAssertNil(state.request)
    }

    func testDestroyedOrReusedWindowInvalidatesRequest() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        let request = try XCTUnwrap(state.begin(workspace: "A", readOnly: false))
        state.forget(1)
        XCTAssertNil(state.request)
        XCTAssertNil(state.entries[1])
        state.remember(windowID: 1, pid: 999, workspace: "A", ruleID: "new-process", floating: true)
        XCTAssertFalse(state.isCurrent(request, workspace: "A"))
        let new = try XCTUnwrap(state.begin(workspace: "A", readOnly: false))
        XCTAssertEqual(new.entry.pid, 999)
        XCTAssertEqual(new.entry.ruleID, "new-process")
    }

    func testExternalRestoreSkipsRecentWindowWithoutInventingSuccess() throws {
        var state = WorkspaceMinimizedRestorePolicy()
        state.noteFocused(1)
        state.noteFocused(2)
        state.remember(windowID: 1, pid: 101, workspace: "A", ruleID: "one", floating: true)
        state.remember(windowID: 2, pid: 102, workspace: "A", ruleID: "two", floating: true)
        state.noteNotMinimized(2)
        XCTAssertNil(state.outcomes[2])
        let older = try XCTUnwrap(state.begin(workspace: "A", readOnly: false))
        XCTAssertEqual(older.entry.windowID, 1)
        state.finish(older, outcome: .timeout)
        state.remember(windowID: 2, pid: 102, workspace: "A", ruleID: "two", floating: true)
        let minimizedAgain = try XCTUnwrap(state.begin(workspace: "A", readOnly: false))
        XCTAssertEqual(minimizedAgain.entry.windowID, 2)
        XCTAssertEqual(state.entries[2]?.workspace, "A")
    }
}
