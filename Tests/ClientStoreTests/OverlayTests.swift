import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import ClientStore

/// Ticket 05's read-time overlay: the base record is what the server confirmed,
/// and what the user sees is that with their own unsent changes applied.
@Suite("Read-time overlay")
struct OverlayTests {

    private let projectId = Project.ID()

    private func create(_ title: String = "A thing") -> IssueCreate {
        IssueCreate(projectId: projectId, title: title)
    }

    private func stored(_ database: ReplicaDatabase, _ issue: Core.Issue) throws {
        try database.apply(
            [SyncChange(entity: .issue, id: issue.id.rawValue, deleted: false, record: .issue(issue))],
            upTo: Watermark(epoch: "e1", sequence: 1)!)
    }

    private func serverIssue(_ title: String = "From the server") -> Core.Issue {
        Core.Issue.fixture(key: nil, projectId: projectId, title: title, status: .todo, priority: .none)
    }

    /// Without a row there is nothing to show at all, so a create is the one thing
    /// that still writes to the base tables before the server has seen it.
    @Test("an issue created offline is visible immediately")
    func issueCreatedOfflineIsVisibleImmediately() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = Core.Issue.ID()
        try database.enqueue(.putIssue(opId: UUID(), id: id, at: Date(), body: create("Brand new")))

        let overlaid = try #require(try database.issue(id))
        #expect(overlaid.record.title == "Brand new")
        #expect(overlaid.isUnsentCreate)

        let listed = try database.issues(in: projectId)
        #expect(listed.count == 1, "a locally created issue did not appear in the list")
    }

    /// The point of the overlay: the user sees their edit even though the base row
    /// still holds what the server last said.
    @Test("an unsent edit is visible over the server's record")
    func unsentEditIsVisibleOverTheServersRecord() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue()
        try stored(database, issue)

        var patch = IssuePatch()
        patch.title = .set("My edit")
        try database.enqueue(.patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))

        let overlaid = try #require(try database.issue(issue.id))
        #expect(overlaid.record.title == "My edit")
        #expect(overlaid.dirty == [.title])
    }

    /// The base is what the server confirmed, so an unsent patch must not touch it.
    /// That is what lets a discarded operation revert with nothing to undo.
    @Test("an unsent edit does not touch the base row")
    func unsentEditDoesNotTouchTheBaseRow() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue("Server title")
        try stored(database, issue)

        var patch = IssuePatch()
        patch.title = .set("My edit")
        try database.enqueue(.patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))

        let raw = try database.reader.read { db in
            try String.fetchOne(
                db, sql: "SELECT title FROM issue WHERE id = ?",
                arguments: [issue.id.rawValue.uuidString])
        }
        #expect(raw == "Server title")
    }

    /// Today's bug, had the base been written instead: discarding would leave the
    /// rejected value baked into the row until the next pull.
    @Test("discarding an edit reverts to the server's value immediately")
    func discardingRevertsImmediately() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue("Server title")
        try stored(database, issue)

        var patch = IssuePatch()
        patch.title = .set("Rejected text")
        let operation = SyncOperation.patchIssue(
            opId: UUID(), id: issue.id, at: Date(), body: patch)
        try database.enqueue(operation)
        try database.quarantine(operation.opId, problem: nil)

        #expect(try database.issue(issue.id)?.record.title == "Rejected text")

        try database.discard(operation.opId)
        #expect(try database.issue(issue.id)?.record.title == "Server title")
    }

    /// The user typed that text and it is still theirs to repair. Hiding it would
    /// make a rejection look like their edit had been thrown away.
    @Test("a quarantined edit is still shown, and flagged")
    func quarantinedEditIsStillShownAndFlagged() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue()
        try stored(database, issue)

        var patch = IssuePatch()
        patch.title = .set("Needs repair")
        let operation = SyncOperation.patchIssue(
            opId: UUID(), id: issue.id, at: Date(), body: patch)
        try database.enqueue(operation)
        try database.quarantine(operation.opId, problem: nil)

        let overlaid = try #require(try database.issue(issue.id))
        #expect(overlaid.record.title == "Needs repair")
        #expect(overlaid.isQuarantined)
    }

    @Test("every changed field is reported dirty, and untouched ones are not")
    func everyChangedFieldIsReportedDirty() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue()
        try stored(database, issue)

        var patch = IssuePatch()
        patch.title = .set("New")
        patch.priority = .set(.urgent)
        try database.enqueue(.patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))

        let dirty = try database.dirtyFields(of: issue.id)
        #expect(dirty == [.title, .priority])
        #expect(!dirty.contains(.status))
        #expect(!dirty.contains(.description))
    }

    /// Clearing is a change like any other, and the UI has to be able to mark it.
    @Test("clearing a field marks it dirty")
    func clearingAFieldMarksItDirty() throws {
        let database = try ReplicaDatabase.inMemory()
        var issue = serverIssue()
        issue.assigneeId = Core.User.ID()
        try stored(database, issue)

        var patch = IssuePatch()
        patch.assigneeId = .cleared
        try database.enqueue(.patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))

        let overlaid = try #require(try database.issue(issue.id))
        #expect(overlaid.record.assigneeId == nil)
        #expect(overlaid.dirty == [.assignee])
    }

    /// Operations apply in queue order, so the last edit is what shows.
    @Test("a run of edits shows the latest value")
    func runOfEditsShowsTheLatestValue() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue()
        try stored(database, issue)

        for title in ["One", "Two", "Three"] {
            var patch = IssuePatch()
            patch.title = .set(title)
            try database.enqueue(.patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))
        }

        #expect(try database.issue(issue.id)?.record.title == "Three")
    }

    /// A rejected delete needs nothing undone, because the base row was never
    /// tombstoned.
    @Test("a locally deleted issue is flagged, not tombstoned")
    func locallyDeletedIssueIsFlaggedNotTombstoned() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue()
        try stored(database, issue)
        try database.enqueue(.deleteIssue(opId: UUID(), id: issue.id, at: Date()))

        let overlaid = try #require(try database.issue(issue.id))
        #expect(overlaid.isUnsentDelete)

        let raw = try database.reader.read { db in
            try Date.fetchOne(
                db, sql: "SELECT deleted_at FROM issue WHERE id = ?",
                arguments: [issue.id.rawValue.uuidString])
        }
        #expect(raw == nil, "the base row was tombstoned before the server agreed")
    }

    /// A tombstone the server confirmed is different: that issue is gone.
    @Test("a server-deleted issue is not returned")
    func serverDeletedIssueIsNotReturned() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue()
        try stored(database, issue)
        try database.apply(
            [SyncChange(entity: .issue, id: issue.id.rawValue, deleted: true, record: nil)],
            upTo: Watermark(epoch: "e1", sequence: 2)!)

        #expect(try database.issues(in: projectId).isEmpty)
    }

    @Test("an unknown issue is nil rather than an error")
    func unknownIssueIsNil() throws {
        #expect(try ReplicaDatabase.inMemory().issue(Core.Issue.ID()) == nil)
    }

    @Test("an issue with nothing pending is not marked dirty")
    func issueWithNothingPendingIsNotDirty() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue()
        try stored(database, issue)

        let overlaid = try #require(try database.issue(issue.id))
        #expect(!overlaid.hasUnsentChanges)
        #expect(overlaid.dirty.isEmpty)
    }

    /// A list of fifty issues must not be fifty-one queries.
    @Test("a list applies the overlay to every row")
    func listAppliesTheOverlayToEveryRow() throws {
        let database = try ReplicaDatabase.inMemory()
        var edited: [Core.Issue.ID] = []

        for index in 0..<5 {
            let issue = serverIssue("Issue \(index)")
            try stored(database, issue)
            if index.isMultiple(of: 2) {
                var patch = IssuePatch()
                patch.title = .set("Edited \(index)")
                try database.enqueue(
                    .patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))
                edited.append(issue.id)
            }
        }

        let listed = try database.issues(in: projectId)
        #expect(listed.count == 5)
        #expect(listed.filter(\.hasUnsentChanges).count == edited.count)
        #expect(listed.filter { $0.record.title.hasPrefix("Edited") }.count == edited.count)
    }

    /// Once the server confirms a write, the base holds it and the overlay has
    /// nothing left to add — so the value must not revert when the queue drains.
    @Test("acknowledging applies the change to the base record")
    func acknowledgingAppliesTheChangeToTheBase() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue("Server title")
        try stored(database, issue)

        var patch = IssuePatch()
        patch.title = .set("Accepted edit")
        let operation = SyncOperation.patchIssue(
            opId: UUID(), id: issue.id, at: Date(), body: patch)
        try database.enqueue(operation)
        try database.acknowledge(operation.opId)

        #expect(try database.allOperations().isEmpty)
        let overlaid = try #require(try database.issue(issue.id))
        #expect(overlaid.record.title == "Accepted edit", "the value reverted when the queue drained")
        #expect(!overlaid.hasUnsentChanges)
    }

    @Test("acknowledging a delete tombstones the base record")
    func acknowledgingADeleteTombstonesTheBase() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = serverIssue()
        try stored(database, issue)
        let operation = SyncOperation.deleteIssue(opId: UUID(), id: issue.id, at: Date())
        try database.enqueue(operation)
        try database.acknowledge(operation.opId)

        #expect(try database.issues(in: projectId).isEmpty)
    }

    @Test("a malformed base row is skipped rather than failing the list")
    func malformedBaseRowIsSkipped() throws {
        let database = try ReplicaDatabase.inMemory()
        try stored(database, serverIssue("Good"))
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO issue
                        (id, project_id, title, description, status, priority,
                         reporter_id, via, created_at, updated_at)
                    VALUES ('not-a-uuid', ?, 'Bad', '', 'todo', 'none', ?, 'human', ?, ?)
                    """,
                arguments: [
                    projectId.rawValue.uuidString, UUID().uuidString, Date(), Date(),
                ])
        }

        #expect(try database.issues(in: projectId).count == 1)
    }
}

@Suite("Overlay field coverage")
struct OverlayFieldTests {

    private let projectId = Project.ID()

    /// Every field has its own branch in the overlay, so each needs its own case —
    /// a bug in one would not show up through another.
    @Test("each field overlays and reports itself dirty")
    func eachFieldOverlaysAndReportsItselfDirty() throws {
        let database = try ReplicaDatabase.inMemory()
        let assignee = Core.User.ID()
        let issue = Core.Issue.fixture(
            key: nil, projectId: projectId, title: "Server", description: "Server body",
            status: .todo, priority: .none)
        try database.apply(
            [SyncChange(entity: .issue, id: issue.id.rawValue, deleted: false, record: .issue(issue))],
            upTo: Watermark(epoch: "e1", sequence: 1)!)

        var patch = IssuePatch()
        patch.title = .set("New title")
        patch.description = .set("New body")
        patch.status = .set(.inProgress)
        patch.priority = .set(.urgent)
        patch.assigneeId = .set(assignee)
        patch.dueDate = .set(CivilDate(wireValue: "2026-12-25")!)
        try database.enqueue(.patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))

        let overlaid = try #require(try database.issue(issue.id))
        #expect(overlaid.record.title == "New title")
        #expect(overlaid.record.description == "New body")
        #expect(overlaid.record.status == .inProgress)
        #expect(overlaid.record.priority == .urgent)
        #expect(overlaid.record.assigneeId == assignee)
        #expect(overlaid.record.dueDate?.wireValue == "2026-12-25")
        #expect(overlaid.dirty == Set(IssueField.allCases))
    }

    /// Clearing a due date is a different branch from setting one.
    @Test("clearing a due date marks it dirty")
    func clearingADueDateMarksItDirty() throws {
        let database = try ReplicaDatabase.inMemory()
        var issue = Core.Issue.fixture(key: nil, projectId: projectId)
        issue.dueDate = CivilDate(wireValue: "2026-01-01")
        try database.apply(
            [SyncChange(entity: .issue, id: issue.id.rawValue, deleted: false, record: .issue(issue))],
            upTo: Watermark(epoch: "e1", sequence: 1)!)

        var patch = IssuePatch()
        patch.dueDate = .cleared
        try database.enqueue(.patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))

        let overlaid = try #require(try database.issue(issue.id))
        #expect(overlaid.record.dueDate == nil)
        #expect(overlaid.dirty == [.dueDate])
    }

    /// Operations on other entities share the queue, and must not be mistaken for
    /// changes to an issue.
    @Test("another entity's pending operations do not mark an issue dirty")
    func anotherEntitysOperationsDoNotMarkAnIssueDirty() throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = Core.Issue.fixture(key: nil, projectId: projectId)
        try database.apply(
            [SyncChange(entity: .issue, id: issue.id.rawValue, deleted: false, record: .issue(issue))],
            upTo: Watermark(epoch: "e1", sequence: 1)!)

        try database.enqueue(
            .putComment(
                opId: UUID(), id: Core.Comment.ID(), at: Date(),
                body: CommentCreate(issueId: issue.id, body: "A comment")))

        let overlaid = try #require(try database.issue(issue.id))
        #expect(!overlaid.hasUnsentChanges)
    }
}
