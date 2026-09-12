import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import ClientStore

/// The advisory pre-push warning.
///
/// The server does pure last-write-wins by receipt time, so a stale offline edit
/// beats newer work silently. This check is the only place a user can find out
/// before it happens — ADR 0005 rejected optimistic concurrency, so there is no
/// server-side veto to rely on.
@Suite("Stale edits")
struct StaleEditTests {

    private let projectId = Project.ID()
    private let watermark = Watermark(epoch: "e1", sequence: 1)!

    private func withIssue(
        updatedAt: Date, _ body: (ReplicaDatabase, Core.Issue) throws -> Void
    ) throws {
        let database = try ReplicaDatabase.inMemory()
        var issue = Core.Issue.fixture(key: nil, projectId: projectId, title: "Server title")
        issue.updatedAt = updatedAt
        try database.apply(
            [SyncChange(entity: .issue, id: issue.id.rawValue, deleted: false, record: .issue(issue))],
            upTo: watermark)
        try body(database, issue)
    }

    private func titlePatch(_ title: String = "My edit") -> IssuePatch {
        var patch = IssuePatch()
        patch.title = .set(title)
        return patch
    }

    /// The case the warning exists for: edited on a plane on Monday, somebody else
    /// changed it on Tuesday, and pushing on Wednesday overwrites them.
    @Test("an edit older than the server's record is reported stale")
    func editOlderThanTheServersRecordIsStale() throws {
        let tuesday = Date()
        let monday = tuesday.addingTimeInterval(-86_400)

        try withIssue(updatedAt: tuesday) { database, issue in
            try database.enqueue(
                .patchIssue(opId: UUID(), id: issue.id, at: monday, body: titlePatch()))

            let stale = try database.staleEdits()
            #expect(stale.count == 1)
            let warning = try #require(stale.first)
            #expect(warning.fields == [.title])
            // Compared with a tolerance: these round-trip through SQLite and JSON,
            // which do not agree below the millisecond.
            #expect(abs(warning.editedAt.timeIntervalSince(monday)) < 0.01)
            #expect(abs(warning.serverChangedAt.timeIntervalSince(tuesday)) < 0.01)
        }
    }

    /// The ordinary case, which must not warn — otherwise the warning is noise and
    /// people stop reading it.
    @Test("an edit newer than the server's record is not stale")
    func editNewerThanTheServersRecordIsNotStale() throws {
        let monday = Date().addingTimeInterval(-86_400)

        try withIssue(updatedAt: monday) { database, issue in
            try database.enqueue(
                .patchIssue(opId: UUID(), id: issue.id, at: Date(), body: titlePatch()))
            #expect(try database.staleEdits().isEmpty)
        }
    }

    /// An equal timestamp is this device's own write coming back. So is one a few
    /// milliseconds apart: SQLite and JSON do not round identically, and warning on
    /// that noise would teach people to ignore the warning.
    @Test("an edit the same age as the record is not stale", arguments: [0.0, 0.005, 0.4])
    func editTheSameAgeIsNotStale(_ drift: TimeInterval) throws {
        let moment = Date()
        try withIssue(updatedAt: moment.addingTimeInterval(drift)) { database, issue in
            try database.enqueue(
                .patchIssue(opId: UUID(), id: issue.id, at: moment, body: titlePatch()))
            #expect(try database.staleEdits().isEmpty)
        }
    }

    /// A create has a brand new id, so there is no other work it could overwrite.
    @Test("a create is never stale")
    func createIsNeverStale() throws {
        let database = try ReplicaDatabase.inMemory()
        try database.enqueue(
            .putIssue(
                opId: UUID(), id: Core.Issue.ID(), at: Date().addingTimeInterval(-86_400),
                body: IssueCreate(projectId: projectId, title: "Made offline")))

        #expect(try database.staleEdits().isEmpty)
    }

    /// Deletion is terminal and beats a concurrent edit by design (ADR 0003), so
    /// warning about it would be telling the user something is wrong when it is
    /// working as specified.
    @Test("a delete is not reported as a stale edit")
    func deleteIsNotReportedAsStale() throws {
        try withIssue(updatedAt: Date()) { database, issue in
            try database.enqueue(
                .deleteIssue(
                    opId: UUID(), id: issue.id, at: Date().addingTimeInterval(-86_400)))
            #expect(try database.staleEdits().isEmpty)
        }
    }

    /// The user needs to know *what* they are about to overwrite, not merely that
    /// they are.
    @Test("the warning names every field the edit would write")
    func warningNamesEveryFieldTheEditWouldWrite() throws {
        try withIssue(updatedAt: Date()) { database, issue in
            var patch = IssuePatch()
            patch.title = .set("New")
            patch.priority = .set(.urgent)
            patch.assigneeId = .cleared

            try database.enqueue(
                .patchIssue(
                    opId: UUID(), id: issue.id, at: Date().addingTimeInterval(-86_400),
                    body: patch))

            let warning = try #require(try database.staleEdits().first)
            #expect(warning.fields == [.title, .priority, .assignee])
        }
    }

    @Test("an edit to an issue this client has never seen is not reported")
    func editToAnUnknownIssueIsNotReported() throws {
        let database = try ReplicaDatabase.inMemory()
        try database.enqueue(
            .patchIssue(
                opId: UUID(), id: Core.Issue.ID(), at: Date().addingTimeInterval(-86_400),
                body: titlePatch()))

        #expect(try database.staleEdits().isEmpty)
    }

    @Test("an empty queue reports nothing")
    func emptyQueueReportsNothing() throws {
        #expect(try ReplicaDatabase.inMemory().staleEdits().isEmpty)
    }

    /// Advisory, not a veto: last-write-wins is the intended behaviour, and this is
    /// a warning about it rather than a block on it.
    @Test("a stale edit still pushes")
    func staleEditStillPushes() throws {
        try withIssue(updatedAt: Date()) { database, issue in
            let operation = SyncOperation.patchIssue(
                opId: UUID(), id: issue.id, at: Date().addingTimeInterval(-86_400),
                body: titlePatch())
            try database.enqueue(operation)

            #expect(try database.staleEdits().count == 1)
            #expect(
                try database.readyOperations().map(\.operation.opId) == [operation.opId],
                "the advisory check blocked a push it should only warn about")
        }
    }

    @Test("quarantined work is listed separately")
    func quarantinedWorkIsListedSeparately() throws {
        try withIssue(updatedAt: Date()) { database, issue in
            let operation = SyncOperation.patchIssue(
                opId: UUID(), id: issue.id, at: Date(), body: titlePatch())
            try database.enqueue(operation)
            #expect(try database.quarantinedWork().isEmpty)

            try database.quarantine(operation.opId, problem: nil)
            #expect(try database.quarantinedWork().count == 1)
        }
    }
}
