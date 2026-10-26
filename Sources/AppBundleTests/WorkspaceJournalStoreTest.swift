@testable import AppBundle
import Foundation
import XCTest

final class WorkspaceJournalStoreTest: XCTestCase {
    func testWritesMetadataAsJSONLinesWithPrivatePermissions() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = WorkspaceJournalStore(options: .init(root: root), clock: { now })
        XCTAssertTrue(store.enqueue(.init(timestamp: now, sequence: 1, kind: "window-moved",
            transactionID: "test-transaction", source: "external-command", command: "move-node-to-workspace",
            reason: "terminal-snapshot", windowID: 9, pid: 22, ruleID: "hsr-home",
            oldWorkspace: "6", newWorkspace: "HSR")))
        XCTAssertTrue(store.enqueue(.init(timestamp: now, sequence: 2, kind: "correction-success", windowID: 9)))
        store.flushForTesting()
        let events = try records(root)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.oldWorkspace, "6")
        XCTAssertEqual(events.first?.newWorkspace, "HSR")
        XCTAssertEqual(events.first?.command, "move-node-to-workspace")
        XCTAssertEqual(store.status.writtenRecords, 2)
        XCTAssertEqual(store.status.pendingRecords, 0)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRotationAndTotalBudgetKeepNewestRecords() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = WorkspaceJournalEvent(timestamp: now, sequence: 1, kind: "test", source: "unknown")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(sample).count + 1
        let store = WorkspaceJournalStore(options: .init(root: root, maxTotalBytes: bytes * 3,
            maxFileBytes: bytes + 8), clock: { now })
        for i in 1...8 {
            var event = sample
            event.sequence = UInt64(i)
            XCTAssertTrue(store.enqueue(event))
            store.flushForTesting()
        }
        let events = try records(root)
        XCTAssertTrue(events.count <= 3)
        XCTAssertTrue(events.contains { $0.sequence == 8 })
        XCTAssertFalse(events.contains { $0.sequence == 1 })
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertTrue(total <= bytes * 3)
    }

    func testRetentionRemovesOnlyOwnedOldRegularFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = root.appendingPathComponent("workspace-old.jsonl")
        let unrelated = root.appendingPathComponent("unrelated.jsonl")
        try Data("old\n".utf8).write(to: old)
        try Data("keep\n".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: unrelated.path)
        let store = WorkspaceJournalStore(options: .init(root: root, retention: 20), clock: { now })
        XCTAssertTrue(store.enqueue(.init(timestamp: now, kind: "test")))
        store.flushForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(store.status.writtenRecords, 1)
    }

    func testQueueAndRecordBoundsDropWithoutBlockingOrThrowing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disabledQueue = WorkspaceJournalStore(options: .init(root: root, maxPendingRecords: 0))
        XCTAssertFalse(disabledQueue.enqueue(.init(kind: "test")))
        XCTAssertEqual(disabledQueue.status.droppedRecords, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace-never.jsonl").path))
        let tinyBudget = WorkspaceJournalStore(options: .init(root: root, maxTotalBytes: 10, maxFileBytes: 10))
        XCTAssertFalse(tinyBudget.enqueue(.init(kind: "larger-than-ten-bytes")))
        XCTAssertEqual(tinyBudget.status.droppedRecords, 1)
    }

    func testUnwritableDestinationCountsFailureWithoutThrowing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("regular-file")
        try Data().write(to: file)
        let store = WorkspaceJournalStore(options: .init(root: file))
        XCTAssertTrue(store.enqueue(.init(kind: "test")))
        store.flushForTesting()
        XCTAssertEqual(store.status.writeFailures, 1)
        XCTAssertEqual(store.status.pendingRecords, 0)
    }

    func testFixedSchemaAndBoundedStringsExcludeContentFields() throws {
        let event = WorkspaceJournalEvent(kind: String(repeating: "k", count: 2_000), source: "external-command",
            command: "exec-and-forget", windowID: 2, pid: 3)
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["kind"] as? String)?.count, 160)
        XCTAssertNil(object["windowTitle"])
        XCTAssertNil(object["body"])
        XCTAssertNil(object["argv"])
        XCTAssertNil(object["stdin"])
        XCTAssertNil(object["clipboard"])
        XCTAssertNil(object["environment"])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aerospace-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func records(_ root: URL) throws -> [WorkspaceJournalEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("workspace-") && $0.pathExtension == "jsonl" }
        return try files.flatMap { url in
            try Data(contentsOf: url).split(separator: 0x0a).map { try decoder.decode(WorkspaceJournalEvent.self, from: Data($0)) }
        }.sorted { $0.sequence < $1.sequence }
    }
}
