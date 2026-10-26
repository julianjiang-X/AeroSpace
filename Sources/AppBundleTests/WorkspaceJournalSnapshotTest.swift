@testable import AppBundle
import XCTest

final class WorkspaceJournalSnapshotTest: XCTestCase {
    func testTerminalDiffCatchesIndirectContainerMoves() {
        let before: [UInt32: WorkspaceJournalWindowState] = [1: state(1, workspace: "6"), 2: state(2, workspace: "6")]
        let after: [UInt32: WorkspaceJournalWindowState] = [1: state(1, workspace: "HSR"), 2: state(2, workspace: "HSR")]
        let changes = WorkspaceJournalTransition.diff(before: before, after: after)
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.allSatisfy { $0.kind == .moved })
        XCTAssertTrue(changes.allSatisfy { $0.before?.workspace == "6" && $0.after?.workspace == "HSR" })
    }

    func testTemporaryRebindingWithSameTerminalStateHasNoDrift() {
        let before: [UInt32: WorkspaceJournalWindowState] = [1: state(1, workspace: "HSR")]
        let intermediate: [UInt32: WorkspaceJournalWindowState] = [1: state(1, workspace: "6")]
        XCTAssertEqual(WorkspaceJournalTransition.diff(before: before, after: intermediate).count, 1)
        XCTAssertTrue(WorkspaceJournalTransition.diff(before: before, after: before).isEmpty)
    }

    func testNewDestroyedAndReusedWindowIdentitiesAreDistinct() {
        let old = state(1, pid: 10, workspace: "A")
        let reused = state(1, pid: 11, workspace: "A")
        XCTAssertEqual(WorkspaceJournalTransition.diff(before: [:], after: [1: old]).first?.kind, .appeared)
        XCTAssertEqual(WorkspaceJournalTransition.diff(before: [1: old], after: [:]).first?.kind, .disappeared)
        XCTAssertEqual(WorkspaceJournalTransition.diff(before: [1: old], after: [1: reused]).first?.kind, .identityReplaced)
        let restarted = state(1, pid: 10, start: 200, workspace: "A")
        XCTAssertEqual(WorkspaceJournalTransition.diff(before: [1: old], after: [1: restarted]).first?.kind, .identityReplaced)
    }

    func testParentChangeWithinWorkspaceIsNotWorkspaceMove() {
        let before = state(1, workspace: "A", parent: "FloatingWindowsContainer")
        let after = state(1, workspace: "A", parent: "TilingContainer")
        let change = WorkspaceJournalTransition.diff(before: [1: before], after: [1: after]).first
        XCTAssertEqual(change?.kind, .reparented)
        XCTAssertEqual(change?.before?.workspace, change?.after?.workspace)
    }

    func testWorkspaceMoveCauseSurvivesInterleavedParentOnlyRebinds() {
        var tracker = WorkspaceJournalProvenanceTracker<String>()
        let original = state(1, workspace: "HSR")
        let moved = state(1, workspace: "6")
        let tiling = state(1, workspace: "6", parent: "TilingContainer")
        let transactionAStart = tracker.revision
        tracker.record(transition(original, moved), cause: "transaction-A-move")
        // A yields. B performs a legal focus helper round trip inside workspace6.
        tracker.record(transition(moved, tiling), cause: "transaction-B-focus")
        tracker.record(transition(tiling, moved), cause: "transaction-B-focus")
        XCTAssertEqual(tracker.cause(for: transition(original, moved), since: transactionAStart), "transaction-A-move")
        XCTAssertFalse(tracker.cause(for: transition(original, moved), since: transactionAStart) == "transaction-B-focus")
    }

    func testProvenanceRequiresCompleteWorkspacePairAndFreshRevision() {
        var tracker = WorkspaceJournalProvenanceTracker<String>()
        let home = state(1, workspace: "HSR")
        let middle = state(1, workspace: "6")
        let final = state(1, workspace: "ZZZ")
        let beginning = tracker.revision
        tracker.record(transition(home, middle), cause: "A")
        tracker.record(transition(middle, final), cause: "B")
        // A terminal HSR→ZZZ delta cannot be attributed to B's 6→ZZZ hop.
        XCTAssertNil(tracker.cause(for: transition(home, final), since: beginning))
        XCTAssertEqual(tracker.cause(for: transition(middle, final), since: beginning), "B")
        let afterMove = tracker.revision
        XCTAssertNil(tracker.cause(for: transition(middle, final), since: afterMove))
    }

    func testProvenanceRejectsReusedIdentityAndForgetsRemovedWindows() {
        var tracker = WorkspaceJournalProvenanceTracker<String>()
        let home = state(1, workspace: "HSR")
        let moved = state(1, workspace: "6")
        tracker.record(transition(home, moved), cause: "old-process")
        let newHome = state(1, pid: 99, start: 200, workspace: "HSR")
        let newMoved = state(1, pid: 99, start: 200, workspace: "6")
        XCTAssertNil(tracker.cause(for: transition(newHome, newMoved), since: 0))
        tracker.retainWindowIDs([])
        XCTAssertNil(tracker.cause(for: transition(home, moved), since: 0))
    }

    func testEndedInheritedTransactionIsNotReusedByConfirmationSession() {
        var registry = WorkspaceJournalTransactionRegistry()
        registry.begin("move-command")
        XCTAssertTrue(registry.mayReuse("move-command", forceNew: false))
        registry.end("move-command")
        // Task.init can still inherit this value after the parent logged end.
        XCTAssertFalse(registry.mayReuse("move-command", forceNew: false))
        XCTAssertFalse(registry.mayReuse("move-command", forceNew: true))
        registry.begin("confirmation")
        XCTAssertTrue(registry.mayReuse("confirmation", forceNew: false))
        XCTAssertFalse(registry.mayReuse("move-command", forceNew: false))
        registry.end("confirmation")
        XCTAssertFalse(registry.mayReuse("confirmation", forceNew: false))
    }

    func testIndependentEntryAlwaysStartsNewWhileInternalHelpersReuseCurrent() {
        var registry = WorkspaceJournalTransactionRegistry()
        registry.begin("light-session")
        // A scheduled heavy refresh can start while its parent is still active.
        XCTAssertFalse(registry.mayReuse("light-session", forceNew: true))
        registry.begin("heavy-session")
        XCTAssertTrue(registry.mayReuse("heavy-session", forceNew: false))
        registry.end("light-session")
        // Ending the parent cannot close or steal the child's transaction.
        XCTAssertTrue(registry.mayReuse("heavy-session", forceNew: false))
        registry.end("heavy-session")
        XCTAssertFalse(registry.mayReuse("heavy-session", forceNew: false))
        XCTAssertFalse(registry.mayReuse(nil, forceNew: false))
    }

    @MainActor
    func testConfigSourceFingerprintIncludesNonAffinityConfiguration() {
        let tiles = parseConfig("default-root-container-layout = 'tiles'").config.sourceFingerprint
        let accordion = parseConfig("default-root-container-layout = 'accordion'").config.sourceFingerprint
        let repeated = parseConfig("default-root-container-layout = 'tiles'").config.sourceFingerprint
        XCTAssertEqual(tiles.count, 64)
        XCTAssertEqual(tiles, repeated)
        XCTAssertFalse(tiles == accordion)
    }

    private func transition(_ before: WorkspaceJournalWindowState, _ after: WorkspaceJournalWindowState) -> WorkspaceJournalTransition {
        .init(kind: before.workspace == after.workspace ? .reparented : .moved, before: before, after: after)
    }

    private func state(_ id: UInt32, pid: Int32 = 10, start: Double = 100,
                       workspace: String, parent: String = "FloatingWindowsContainer") -> WorkspaceJournalWindowState {
        .init(windowID: id, pid: pid, processStart: start, appID: "test.app", workspace: workspace, parent: parent)
    }
}
