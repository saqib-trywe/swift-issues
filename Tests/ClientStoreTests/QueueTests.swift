import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import ClientStore

typealias DomainIssue = Core.Issue

/// The offline queue, and the atomicity ADR 0004's guarantee rests on.
@Suite("Pending queue")
struct QueueTests {

    private let projectId = Project.ID()

    private func create(_ title: String = "A thing", labels: [Label.ID] = []) -> IssueCreate {
        IssueCreate(projectId: projectId, title: title, labelIds: labels)
    }

    private func titlePatch(_ title: String) -> IssuePatch {
        var patch = IssuePatch()
        patch.title = .set(title)
        return patch
    }

    // MARK: Atomicity

    /// The reason the replica and the queue share one file. Its failure mode
    /// otherwise is silent divergence: the user sees their edit, the server never
    /// hears about it, and nothing can tell.
    @Test("a local write and its queue entry both land")
    func localWriteAndQueueEntryBothLand() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = DomainIssue.ID()

        try database.enqueue(.putIssue(opId: UUID(), id: id, at: Date(), body: create("Queued")))

        let title = try database.reader.read { db in
            try String.fetchOne(
                db, sql: "SELECT title FROM issue WHERE id = ?", arguments: [id.rawValue.uuidString])
        }
        #expect(title == "Queued")
        #expect(try database.allOperations().count == 1)
    }

    /// If the enqueue fails, the local mutation must not survive — otherwise the
    /// device is silently ahead of the server with nothing to detect it.
    @Test("a failed enqueue rolls back the local write")
    func failedEnqueueRollsBackTheLocalWrite() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = DomainIssue.ID()
        let opId = UUID()

        // The same opId twice: the second insert violates the unique constraint
        // after its local write has already been applied.
        try database.enqueue(.putIssue(opId: opId, id: id, at: Date(), body: create("First")))
        let other = DomainIssue.ID()

        #expect(throws: (any Error).self) {
            try database.enqueue(
                .putIssue(opId: opId, id: other, at: Date(), body: create("Second")))
        }

        let stored = try database.reader.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM issue WHERE id = ?",
                arguments: [other.rawValue.uuidString])
        }
        #expect(stored == 0, "the local write survived a failed enqueue, diverging the device")
        #expect(try database.allOperations().count == 1)
    }

    // MARK: Local application

    @Test("a patch touches only the fields it names")
    func patchTouchesOnlyNamedFields() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = DomainIssue.ID()
        var body = create("Original")
        body.description = "Untouched"
        body.priority = .high

        try database.enqueue(.putIssue(opId: UUID(), id: id, at: Date(), body: body))
        try database.enqueue(
            .patchIssue(opId: UUID(), id: id, at: Date(), body: titlePatch("Renamed")))

        let row = try database.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM issue WHERE id = ?", arguments: [id.rawValue.uuidString])
        }
        let stored = try #require(row)
        #expect(stored["title"] == "Renamed")
        #expect(stored["description"] == "Untouched")
        #expect(stored["priority"] == "high")
    }

    @Test("clearing a field clears it locally")
    func clearingAFieldClearsItLocally() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = DomainIssue.ID()
        var body = create()
        body.assigneeId = User.ID()

        try database.enqueue(.putIssue(opId: UUID(), id: id, at: Date(), body: body))
        var patch = IssuePatch()
        patch.assigneeId = .cleared
        try database.enqueue(.patchIssue(opId: UUID(), id: id, at: Date(), body: patch))

        let assignee = try database.reader.read { db in
            try String.fetchOne(
                db, sql: "SELECT assignee_id FROM issue WHERE id = ?",
                arguments: [id.rawValue.uuidString])
        }
        #expect(assignee == nil)
    }

    /// A tombstone is kept indefinitely: a client that forgot one would resurrect
    /// the record on its next pull.
    @Test("a delete tombstones rather than removing the row")
    func deleteTombstonesRatherThanRemoving() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = DomainIssue.ID()

        try database.enqueue(.putIssue(opId: UUID(), id: id, at: Date(), body: create()))
        try database.enqueue(.deleteIssue(opId: UUID(), id: id, at: Date()))

        let row = try database.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM issue WHERE id = ?", arguments: [id.rawValue.uuidString])
        }
        let stored = try #require(row)
        #expect(stored["deleted_at"] != nil)
    }

    /// A deleted comment still occupies its place in a thread, so the body is
    /// cleared rather than the row removed — matching the server.
    @Test("deleting a comment clears its body")
    func deletingACommentClearsItsBody() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = Core.Comment.ID()

        try database.enqueue(
            .putComment(
                opId: UUID(), id: id, at: Date(),
                body: CommentCreate(issueId: DomainIssue.ID(), body: "Said something")))
        try database.enqueue(.deleteComment(opId: UUID(), id: id, at: Date()))

        let row = try database.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM comment WHERE id = ?", arguments: [id.rawValue.uuidString])
        }
        let stored = try #require(row)
        #expect(stored["body"] == nil)
        #expect(stored["deleted_at"] != nil)
    }

    /// Two clients adding the same label converge on one membership, even though
    /// each invented its own row id.
    @Test("adding the same label twice converges on one membership")
    func addingTheSameLabelTwiceConverges() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = DomainIssue.ID()
        let label = Label.ID()

        try database.enqueue(
            .addLabel(opId: UUID(), id: IssueLabel.ID(), at: Date(), issueId: issue, labelId: label))
        try database.enqueue(
            .addLabel(opId: UUID(), id: IssueLabel.ID(), at: Date(), issueId: issue, labelId: label))

        let count = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM issue_label")
        }
        #expect(count == 1)
    }

    @Test("a create carrying labels attaches them")
    func createCarryingLabelsAttachesThem() throws {
        let database = try ReplicaDatabase.inMemory()
        let label = Label.ID()

        try database.enqueue(
            .putIssue(
                opId: UUID(), id: DomainIssue.ID(), at: Date(), body: create(labels: [label])))

        let count = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM issue_label")
        }
        #expect(count == 1)
    }

    // MARK: Round-tripping

    /// Replay is a translation rather than a re-derivation (ADR 0005), which only
    /// holds if the stored payload reconstructs the operation exactly.
    @Test("an operation survives a round trip through the queue")
    func operationSurvivesARoundTrip() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = DomainIssue.ID()
        var patch = IssuePatch()
        patch.title = .set("Round trip")
        patch.assigneeId = .cleared
        let original = SyncOperation.patchIssue(opId: UUID(), id: id, at: Date(), body: patch)

        try database.enqueue(original)
        let stored = try #require(try database.allOperations().first)

        guard case .patchIssue(let opId, let storedId, _, let body) = stored.operation else {
            Issue.record("the operation came back as the wrong kind")
            return
        }
        #expect(opId == original.opId)
        #expect(storedId == id)
        #expect(body.title == .set("Round trip"))
        #expect(body.assigneeId == .cleared)
    }

    /// One unreadable row must not make the whole queue unreadable, which is when
    /// it matters most.
    @Test("an undecodable row is skipped, not fatal")
    func undecodableRowIsSkipped() throws {
        let database = try ReplicaDatabase.inMemory()
        try database.enqueue(
            .putIssue(opId: UUID(), id: DomainIssue.ID(), at: Date(), body: create()))

        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_operation
                        (op_id, entity_type, entity_id, kind, payload, created_at, state)
                    VALUES (?, 'issue', ?, 'patch', 'not json', ?, 'pending')
                    """,
                arguments: [UUID().uuidString, UUID().uuidString, Date()])
        }

        #expect(try database.allOperations().count == 1)
    }

    // MARK: Quarantine and blocking

    /// ADR 0004: a rejection is kept with its error for repair, never silently
    /// dropped.
    @Test("quarantining records the problem and keeps the payload")
    func quarantiningRecordsTheProblem() throws {
        let database = try ReplicaDatabase.inMemory()
        let operation = SyncOperation.putIssue(
            opId: UUID(), id: DomainIssue.ID(), at: Date(), body: create("Rejected"))
        try database.enqueue(operation)

        try database.quarantine(
            operation.opId,
            problem: Problem(
                type: "about:blank", title: "Invalid", status: 422, detail: "Title too long."))

        let stored = try #require(try database.allOperations().first)
        #expect(stored.state == .quarantined)
        #expect(stored.problem?.detail == "Title too long.")
        #expect(stored.attemptCount == 1)
        // The payload survives, so the user can repair and retry.
        guard case .putIssue(_, _, _, let body) = stored.operation else {
            Issue.record("the payload was lost")
            return
        }
        #expect(body.title == "Rejected")
    }

    /// The specific failure mode ADR 0004 designs against.
    @Test("a quarantined operation does not block unrelated work")
    func quarantineDoesNotBlockUnrelatedWork() throws {
        let database = try ReplicaDatabase.inMemory()
        let doomed = SyncOperation.putIssue(
            opId: UUID(), id: DomainIssue.ID(), at: Date(), body: create("Doomed"))
        let unrelated = SyncOperation.putIssue(
            opId: UUID(), id: DomainIssue.ID(), at: Date(), body: create("Fine"))

        try database.enqueue(doomed)
        try database.enqueue(unrelated)
        try database.quarantine(doomed.opId, problem: nil)

        let ready = try database.readyOperations().map(\.operation.opId)
        #expect(ready == [unrelated.opId])
    }

    @Test("a quarantined operation does block what depends on it")
    func quarantineBlocksItsDependents() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = DomainIssue.ID()
        let doomed = SyncOperation.putIssue(opId: UUID(), id: issue, at: Date(), body: create())
        let comment = SyncOperation.putComment(
            opId: UUID(), id: Core.Comment.ID(), at: Date(),
            body: CommentCreate(issueId: issue, body: "Blocked"))

        try database.enqueue(doomed)
        try database.enqueue(comment)
        try database.quarantine(doomed.opId, problem: nil)

        #expect(try database.readyOperations().isEmpty)
        #expect(try database.blockedOperations().map(\.operation.opId) == [comment.opId])
    }

    @Test("an acknowledged operation leaves the queue")
    func acknowledgedOperationLeavesTheQueue() throws {
        let database = try ReplicaDatabase.inMemory()
        let operation = SyncOperation.putIssue(
            opId: UUID(), id: DomainIssue.ID(), at: Date(), body: create())

        try database.enqueue(operation)
        try database.acknowledge(operation.opId)

        #expect(try database.allOperations().isEmpty)
    }

    @Test("ready operations come back in queue order")
    func readyOperationsComeBackInQueueOrder() throws {
        let database = try ReplicaDatabase.inMemory()
        let ids = (0..<5).map { _ in UUID() }
        for opId in ids {
            try database.enqueue(
                .putIssue(opId: opId, id: DomainIssue.ID(), at: Date(), body: create()))
        }

        #expect(try database.readyOperations().map(\.operation.opId) == ids)
    }

    @Test("the batch respects its limit")
    func batchRespectsItsLimit() throws {
        let database = try ReplicaDatabase.inMemory()
        for _ in 0..<10 {
            try database.enqueue(
                .putIssue(opId: UUID(), id: DomainIssue.ID(), at: Date(), body: create()))
        }
        #expect(try database.readyOperations(limit: 3).count == 3)
    }

    // MARK: Coalescing in the store

    @Test("coalescing collapses a run of patches in the queue")
    func coalescingCollapsesARunOfPatches() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = DomainIssue.ID()
        try database.enqueue(.putIssue(opId: UUID(), id: id, at: Date(), body: create()))
        for index in 0..<10 {
            try database.enqueue(
                .patchIssue(opId: UUID(), id: id, at: Date(), body: titlePatch("Title \(index)")))
        }

        try database.coalescePending()

        let remaining = try database.allOperations()
        #expect(remaining.count == 1)
        guard case .putIssue(_, _, _, let body) = remaining[0].operation else {
            Issue.record("expected the create to absorb the patches")
            return
        }
        #expect(body.title == "Title 9")
    }

    /// Coalescing must not touch an operation the server may already have seen:
    /// that would change what a retry means.
    @Test("coalescing leaves quarantined operations alone")
    func coalescingLeavesQuarantinedAlone() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = DomainIssue.ID()
        let first = SyncOperation.patchIssue(
            opId: UUID(), id: id, at: Date(), body: titlePatch("One"))
        try database.enqueue(first)
        try database.enqueue(.patchIssue(opId: UUID(), id: id, at: Date(), body: titlePatch("Two")))
        try database.quarantine(first.opId, problem: nil)

        try database.coalescePending()

        let states = try database.allOperations()
        #expect(states.count == 2)
        #expect(states.contains { $0.operation.opId == first.opId && $0.state == .quarantined })
    }

    @Test("coalescing an already-minimal queue changes nothing")
    func coalescingAnAlreadyMinimalQueueChangesNothing() throws {
        let database = try ReplicaDatabase.inMemory()
        let operation = SyncOperation.putIssue(
            opId: UUID(), id: DomainIssue.ID(), at: Date(), body: create())
        try database.enqueue(operation)

        let before = try database.allOperations()
        try database.coalescePending()
        let after = try database.allOperations()

        #expect(before.map(\.sequence) == after.map(\.sequence))
    }
}
