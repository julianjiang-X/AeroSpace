@testable import AppBundle
import Foundation
import XCTest

final class WorkspaceAffinityPolicyTest: XCTestCase {
    private func key(generation: UInt64 = 1, windowID: UInt32 = 1, pid: Int32 = 100, ruleID: String = "home", expected: String = "HOME", observed: String = "OTHER") -> WorkspaceAffinityStability.Key {
        .init(generation: generation, windowID: windowID, pid: pid, ruleID: ruleID, expected: expected, observed: observed)
    }

    func testStableMismatchNeedsARepeatedSettledObservation() {
        var gate = WorkspaceAffinityStability()
        XCTAssertFalse(gate.observe(key: key(), now: 10))
        XCTAssertFalse(gate.observe(key: key(), now: 10.249))
        XCTAssertTrue(gate.observe(key: key(), now: 10.25))
        XCTAssertTrue(gate.observe(key: key(), now: 10.3))
        gate.forget(windowID: 1)
        XCTAssertFalse(gate.observe(key: key(), now: 11))
        gate.reset()
        XCTAssertFalse(gate.observe(key: key(), now: 12))
    }

    func testChangedGenerationIdentityRuleOrWorkspaceStartsNewConfirmation() {
        for changed in [key(generation: 2), key(pid: 101), key(ruleID: "different"), key(expected: "NEW"), key(observed: "THIRD")] {
            var gate = WorkspaceAffinityStability()
            XCTAssertFalse(gate.observe(key: key(), now: 0))
            XCTAssertFalse(gate.observe(key: changed, now: 1))
            XCTAssertTrue(gate.observe(key: changed, now: 1.25))
        }
        var gate = WorkspaceAffinityStability()
        XCTAssertFalse(gate.observe(key: key(windowID: 1), now: 0))
        XCTAssertFalse(gate.observe(key: key(windowID: 2), now: 1))
        XCTAssertTrue(gate.observe(key: key(windowID: 1), now: 1))
    }

    func testClockRegressionAndInvalidTimeNeverImmediatelyConfirm() {
        var gate = WorkspaceAffinityStability()
        XCTAssertFalse(gate.observe(key: key(), now: 10))
        XCTAssertFalse(gate.observe(key: key(), now: 9))
        XCTAssertFalse(gate.observe(key: key(), now: .infinity))
        XCTAssertFalse(gate.observe(key: key(), now: .nan))
        XCTAssertFalse(gate.observe(key: key(), now: 9.1))
        XCTAssertTrue(gate.observe(key: key(), now: 9.25))
    }

    func testCorrectionConflictsBlockUntilExplicitResetOrDeath() {
        var budget = WorkspaceAffinityCorrectionBudget()
        XCTAssertTrue(budget.allowAndRecord(windowID: 1, now: 0))
        XCTAssertTrue(budget.allowAndRecord(windowID: 1, now: 1))
        XCTAssertTrue(budget.allowAndRecord(windowID: 1, now: 2))
        XCTAssertTrue(budget.isBlocked(windowID: 1))
        XCTAssertFalse(budget.allowAndRecord(windowID: 1, now: 3))
        XCTAssertFalse(budget.allowAndRecord(windowID: 1, now: 100))
        XCTAssertTrue(budget.allowAndRecord(windowID: 2, now: 3))
        budget.reset(windowID: 1)
        XCTAssertFalse(budget.isBlocked(windowID: 1))
        XCTAssertTrue(budget.allowAndRecord(windowID: 1, now: 101))
        budget.prune(alive: [2])
        XCTAssertTrue(budget.allowAndRecord(windowID: 1, now: 102))
    }

    func testSpreadOutCorrectionsExpireButBackwardsTimeCannotBypassBudget() {
        var budget = WorkspaceAffinityCorrectionBudget()
        XCTAssertTrue(budget.allowAndRecord(windowID: 1, now: 0))
        XCTAssertTrue(budget.allowAndRecord(windowID: 1, now: 31))
        XCTAssertFalse(budget.allowAndRecord(windowID: 1, now: 30))
        XCTAssertTrue(budget.allowAndRecord(windowID: 1, now: 62))
        XCTAssertTrue(budget.allowAndRecord(windowID: 1, now: 93))
        XCTAssertFalse(budget.isBlocked(windowID: 1))
        XCTAssertFalse(budget.allowAndRecord(windowID: 2, now: .nan))
        XCTAssertFalse(budget.allowAndRecord(windowID: 2, now: .infinity))
    }
}
