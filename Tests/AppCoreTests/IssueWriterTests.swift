import ClientStore
import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import AppCore

/// Writes from the app go to the offline queue, never straight to the network.
@Suite("Issue writer")
struct IssueWriterTests {

    private let projectId = Project.ID()
    private let watermark = Watermark(epoch: "e1", sequence: 1)!

    private func store() throws -> (ReplicaDatabase, IssueWriter) {
        let database = try ReplicaDatabase.inMemory()
        return (database, IssueWriter(database: database))
    }

    private func stored(_ database: ReplicaDatabase, _ issue: DomainIssue) throws {
        try database.apply(
            [SyncChange(entity: .issue, id: issue.id.rawValue, deleted: false, record: .issue(issue))],
            upTo: watermark)
    }

    // MARK: The diff

    /// Ticket 05's reason for field-level patches: a whole-record snapshot carries
    /// stale values for untouched fields, and under per-field last-write-wins those
    /// would beat somebody else's newer edit — silently reverting their work.
    @Test("a patch carries only what changed")
    func patchCarriesOnlyWhatChanged() {
        let original = IssueDraft(
            title: "Original", description: "Body", status: .todo, priority: .high)
        var edited = original
        edited.title = "Renamed"

        let patch = edited.patch(against: original)
        #expect(patch.title == .set("Renamed"))
        #expect(patch.description.isUnchanged)
        #expect(patch.status.isUnchanged)
        #expect(patch.priority.isUnchanged, "an untouched field would have clobbered newer work")
    }

    /// A form saved untouched must queue nothing: a no-op operation is a round trip
    /// that changes nothing and an `updatedAt` bump that wins a race it should
    /// never have entered.
    @Test("an unchanged draft produces an empty patch")
    func unchangedDraftProducesAnEmptyPatch() {
        let draft = IssueDraft(title: "Same", description: "Same", priority: .urgent)
        #expect(draft.patch(against: draft).isEmpty)
    }

    /// Clearing is a value, not an absence — the whole point of Merge Patch's third
    /// state.
    @Test("clearing a field patches to cleared, not to unchanged")
    func clearingPatchesToCleared() {
        var original = IssueDraft()
        original.assigneeId = Core.User.ID()
        original.dueDate = CivilDate(wireValue: "2026-01-01")

        var cleared = original
        cleared.assigneeId = nil
        cleared.dueDate = nil

        let patch = cleared.patch(against: original)
        #expect(patch.assigneeId == .cleared)
        #expect(patch.dueDate == .cleared)
    }

    @Test("setting a previously empty field patches to set")
    func settingAPreviouslyEmptyFieldPatchesToSet() {
        let assignee = Core.User.ID()
        var edited = IssueDraft()
        edited.assigneeId = assignee

        #expect(IssueDraft().patch(against: IssueDraft()).assigneeId.isUnchanged)
        #expect(edited.patch(against: IssueDraft()).assigneeId == .set(assignee))
    }

    @Test("every field can be changed independently")
    func everyFieldCanBeChangedIndependently() {
        let original = IssueDraft(title: "A", description: "B", status: .todo, priority: .none)

        var status = original
        status.status = .done
        #expect(status.patch(against: original).status == .set(.done))

        var priority = original
        priority.priority = .urgent
        #expect(priority.patch(against: original).priority == .set(.urgent))

        var description = original
        description.description = "Rewritten"
        #expect(description.patch(against: original).description == .set("Rewritten"))
    }

    /// The form is seeded from what is on screen, which is the overlaid value — so
    /// an edit builds on the user's own unsent changes rather than on the server's
    /// older record.
    @Test("a draft seeded from an issue matches it")
    func draftSeededFromAnIssueMatchesIt() {
        let issue = DomainIssue.fixture(
            title: "Seeded", description: "Body", status: .inProgress, priority: .high)

        let draft = IssueDraft(from: issue)
        #expect(draft.title == "Seeded")
        #expect(draft.status == .inProgress)
        #expect(draft.patch(against: draft).isEmpty)
    }

    // MARK: Validation

    /// Refusing here means an offline edit is rejected while the person is looking
    /// at it, rather than quarantined hours later with no context.
    @Test("an invalid draft is refused before anything is queued")
    func invalidDraftIsRefusedBeforeQueueing() throws {
        let (database, writer) = try store()
        let draft = IssueDraft(title: "   ")

        #expect(throws: WriteError.self) {
            try writer.create(draft, in: projectId)
        }
        #expect(try database.allOperations().isEmpty)
    }

    @Test("an over-long title is refused")
    func overLongTitleIsRefused() throws {
        let (_, writer) = try store()
        let draft = IssueDraft(title: String(repeating: "a", count: 600))

        #expect(!draft.isValid)
        #expect(throws: WriteError.self) { try writer.create(draft, in: projectId) }
    }

    @Test("a validation failure reads as a sentence")
    func validationFailureReadsAsASentence() {
        let described = WriteError.invalid(IssueDraft(title: "").validationFailures).description
        #expect(!described.isEmpty)
        #expect(!described.contains("ValidationFailure"))
    }

    // MARK: Queueing

    /// The write lands locally and goes out later, which is what makes the app work
    /// on a plane.
    @Test("creating queues an operation and shows immediately")
    func creatingQueuesAndShowsImmediately() throws {
        let (database, writer) = try store()

        let id = try writer.create(
            IssueDraft(title: "Made offline", priority: .urgent), in: projectId)

        #expect(try database.allOperations().count == 1)
        let overlaid = try #require(try database.issue(id))
        #expect(overlaid.record.title == "Made offline")
        #expect(overlaid.record.priority == .urgent)
        #expect(overlaid.isUnsentCreate)
        // No key until the server assigns one.
        #expect(overlaid.record.key == nil)
    }

    @Test("editing queues a patch and shows immediately")
    func editingQueuesAPatchAndShowsImmediately() throws {
        let (database, writer) = try store()
        let issue = DomainIssue.fixture(key: nil, projectId: projectId, title: "Server title")
        try stored(database, issue)

        let original = IssueDraft(from: issue)
        var edited = original
        edited.title = "My edit"

        #expect(try writer.edit(issue.id, from: original, to: edited))

        let overlaid = try #require(try database.issue(issue.id))
        #expect(overlaid.record.title == "My edit")
        #expect(overlaid.dirty == [.title])
    }

    /// A save button has to be able to say "nothing changed" rather than appear to
    /// have done something.
    @Test("editing with no changes queues nothing and reports so")
    func editingWithNoChangesQueuesNothing() throws {
        let (database, writer) = try store()
        let issue = DomainIssue.fixture(key: nil, projectId: projectId)
        try stored(database, issue)
        let draft = IssueDraft(from: issue)

        #expect(try writer.edit(issue.id, from: draft, to: draft) == false)
        #expect(try database.allOperations().isEmpty)
    }

    @Test("commenting queues a create")
    func commentingQueuesACreate() throws {
        let (database, writer) = try store()
        let issue = DomainIssue.fixture(key: nil, projectId: projectId)
        try stored(database, issue)

        let id = try writer.comment(on: issue.id, body: "Looks right to me.")

        #expect(try database.comments(forIssue: issue.id).map(\.id) == [id])
        #expect(try database.allOperations().count == 1)
    }

    @Test("an empty comment is refused")
    func emptyCommentIsRefused() throws {
        let (database, writer) = try store()

        #expect(throws: WriteError.self) {
            try writer.comment(on: DomainIssue.ID(), body: "   ")
        }
        #expect(try database.allOperations().isEmpty)
    }

    /// Deletion is carried by the queue until the server agrees, so a rejected
    /// delete needs nothing undone.
    @Test("deleting flags the issue without tombstoning the base record")
    func deletingFlagsWithoutTombstoning() throws {
        let (database, writer) = try store()
        let issue = DomainIssue.fixture(key: nil, projectId: projectId)
        try stored(database, issue)

        try writer.delete(issue.id)

        #expect(try database.issue(issue.id)?.isUnsentDelete == true)
        let raw = try database.reader.read { db in
            try Date.fetchOne(
                db, sql: "SELECT deleted_at FROM issue WHERE id = ?",
                arguments: [issue.id.rawValue.uuidString])
        }
        #expect(raw == nil)
    }

    /// A client-generated id is what lets a create be made offline at all, and what
    /// makes a retry idempotent rather than a duplicate.
    @Test("each create gets its own id")
    func eachCreateGetsItsOwnId() throws {
        let (_, writer) = try store()

        let first = try writer.create(IssueDraft(title: "One"), in: projectId)
        let second = try writer.create(IssueDraft(title: "Two"), in: projectId)

        #expect(first != second)
    }

    /// Successive edits coalesce rather than queueing one operation per keystroke.
    @Test("a run of edits collapses when coalesced")
    func runOfEditsCollapsesWhenCoalesced() throws {
        let (database, writer) = try store()
        let issue = DomainIssue.fixture(key: nil, projectId: projectId, title: "Start")
        try stored(database, issue)

        var previous = IssueDraft(from: issue)
        for title in ["One", "Two", "Three"] {
            var next = previous
            next.title = title
            _ = try writer.edit(issue.id, from: previous, to: next)
            previous = next
        }
        #expect(try database.allOperations().count == 3)

        try database.coalescePending()

        #expect(try database.allOperations().count == 1)
        #expect(try database.issue(issue.id)?.record.title == "Three")
    }

    // MARK: Read-only fields

    /// Offering a picker would let the user clobber a value this build cannot
    /// represent — the very thing lenient decoding exists to prevent.
    @Test(
        "a field holding an unrecognised value is read-only",
        arguments: [
            IssueField.status, .priority,
        ])
    func fieldHoldingAnUnrecognisedValueIsReadOnly(_ field: IssueField) {
        var draft = IssueDraft()
        if field == .status {
            draft.status = .unknown("triaged")
        } else {
            draft.priority = .unknown("blocker")
        }

        #expect(draft.isReadOnly(field))
        #expect(!draft.isReadOnly(.title))
    }

    @Test("known values stay editable")
    func knownValuesStayEditable() {
        let draft = IssueDraft(status: .inProgress, priority: .high)

        #expect(!draft.isReadOnly(.status))
        #expect(!draft.isReadOnly(.priority))
    }
}
