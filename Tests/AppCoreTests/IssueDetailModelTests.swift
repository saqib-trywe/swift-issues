import ClientStore
import Core
import Foundation
import TestSupport
import Testing

@testable import AppCore

@MainActor
@Suite("Issue detail model")
struct IssueDetailModelTests {

    private let projectId = Project.ID()
    private let watermark = Watermark(epoch: "e1", sequence: 1)!

    private func store(_ database: ReplicaDatabase, _ changes: [SyncChange]) throws {
        try database.apply(changes, upTo: watermark)
    }

    private func withIssue(
        status: Status = .todo,
        priority: Priority = .none,
        _ body: (ReplicaDatabase, DomainIssue) throws -> Void
    ) throws {
        let database = try ReplicaDatabase.inMemory()
        let issue = DomainIssue.fixture(
            key: IssueKey("PROJ-7"), projectId: projectId, title: "Under discussion",
            status: status, priority: priority)
        try store(
            database,
            [SyncChange(entity: .issue, id: issue.id.rawValue, deleted: false, record: .issue(issue))])
        try body(database, issue)
    }

    @Test("loading reads the issue, its comments and its labels")
    func loadingReadsEverything() throws {
        try withIssue { database, issue in
            let label = Label.fixture(projectId: projectId, name: "bug")
            let link = IssueLabel.fixture(issueId: issue.id, labelId: label.id)
            try store(
                database,
                [
                    SyncChange(
                        entity: .comment, id: UUID(), deleted: false,
                        record: .comment(
                            Core.Comment.fixture(issueId: issue.id, body: "First thought"))),
                    SyncChange(
                        entity: .label, id: label.id.rawValue, deleted: false,
                        record: .label(label)),
                    SyncChange(
                        entity: .issueLabel, id: link.id.rawValue, deleted: false,
                        record: .issueLabel(link)),
                ])

            let model = IssueDetailModel(database: database, id: issue.id)
            model.reload()

            #expect(model.issue?.record.title == "Under discussion")
            #expect(model.comments.count == 1)
            #expect(model.labels.map(\.name) == ["bug"])
        }
    }

    /// On a client that has not finished its first sync this is normal, not an
    /// error — pull order is change order, so a record can simply not have arrived.
    @Test("an issue that has not arrived is missing, not failed")
    func issueThatHasNotArrivedIsMissing() throws {
        let database = try ReplicaDatabase.inMemory()
        let model = IssueDetailModel(database: database, id: DomainIssue.ID())
        model.reload()

        #expect(model.isMissing)
        #expect(model.failure == nil)
    }

    /// A removed comment still occupies its place in a conversation; a thread that
    /// silently closes its gaps reads as if it were never there.
    @Test("a deleted comment keeps its place with no body")
    func deletedCommentKeepsItsPlace() throws {
        try withIssue { database, issue in
            let comment = Core.Comment.fixture(issueId: issue.id, body: "Said something")
            try store(
                database,
                [
                    SyncChange(
                        entity: .comment, id: comment.id.rawValue, deleted: false,
                        record: .comment(comment))
                ])
            try store(
                database,
                [SyncChange(entity: .comment, id: comment.id.rawValue, deleted: true, record: nil)])

            let model = IssueDetailModel(database: database, id: issue.id)
            model.reload()

            #expect(model.comments.count == 1)
            #expect(model.comments.first?.body == nil)
            #expect(model.comments.first?.isDeleted == true)
        }
    }

    @Test("dirty fields are exposed for marking individual controls")
    func dirtyFieldsAreExposed() throws {
        try withIssue { database, issue in
            var patch = IssuePatch()
            patch.priority = .set(.urgent)
            try database.enqueue(
                .patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))

            let model = IssueDetailModel(database: database, id: issue.id)
            model.reload()

            #expect(model.dirtyFields == [.priority])
            #expect(model.issue?.record.priority == .urgent)
        }
    }

    /// Ticket 10: a leniently-decoded `unknown` value renders read-only. Offering a
    /// picker would let the user clobber a value this build cannot represent, which
    /// is the very thing lenient decoding exists to prevent.
    @Test(
        "a field holding an unknown enum value is read-only",
        arguments: [
            IssueField.status, .priority,
        ])
    func fieldHoldingAnUnknownValueIsReadOnly(_ field: IssueField) throws {
        let status: Status = field == .status ? .unknown("triaged") : .todo
        let priority: Priority = field == .priority ? .unknown("blocker") : .none

        try withIssue(status: status, priority: priority) { database, issue in
            let model = IssueDetailModel(database: database, id: issue.id)
            model.reload()

            #expect(model.isReadOnly(field))
        }
    }

    @Test("a field holding a known value is editable")
    func fieldHoldingAKnownValueIsEditable() throws {
        try withIssue(status: .inProgress, priority: .high) { database, issue in
            let model = IssueDetailModel(database: database, id: issue.id)
            model.reload()

            #expect(!model.isReadOnly(.status))
            #expect(!model.isReadOnly(.priority))
            #expect(!model.isReadOnly(.title))
        }
    }

    /// Nothing is read-only before the record has loaded, or every control would
    /// start disabled and flicker.
    @Test("nothing is read-only before the issue has loaded")
    func nothingIsReadOnlyBeforeLoading() throws {
        let database = try ReplicaDatabase.inMemory()
        let model = IssueDetailModel(database: database, id: DomainIssue.ID())

        #expect(!model.isReadOnly(.status))
        #expect(model.dirtyFields.isEmpty)
    }

    /// An issue created offline has no key until first sync, so every view needs a
    /// placeholder state for it (ticket 10).
    @Test("an unsynced issue has no key yet")
    func unsyncedIssueHasNoKeyYet() throws {
        let database = try ReplicaDatabase.inMemory()
        let id = DomainIssue.ID()
        try database.enqueue(
            .putIssue(
                opId: UUID(), id: id, at: Date(),
                body: IssueCreate(projectId: projectId, title: "Made on a plane")))

        let model = IssueDetailModel(database: database, id: id)
        model.reload()

        #expect(model.issue?.record.key == nil)
        #expect(model.issue?.isUnsentCreate == true)
    }
}
