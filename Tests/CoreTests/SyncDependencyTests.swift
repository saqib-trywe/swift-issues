import Foundation
import Testing

@testable import Core

/// ADR 0004's replay ordering, as a domain contract.
///
/// Ticket 05's input 4 is explicit that this must be unit-testable without a
/// database: the server rejects any reference to an id it has not seen, so getting
/// the order wrong means an offline batch fails for reasons the user cannot act on.
@Suite("Sync dependencies")
struct SyncDependencyTests {

    private let projectId = Project.ID()
    private let reporterId = User.ID()

    private func issueCreate(labels: [Label.ID] = []) -> IssueCreate {
        IssueCreate(projectId: projectId, title: "A thing", labelIds: labels)
    }

    /// A comment refers to its issue, so the issue's create has to go first.
    @Test("a comment depends on its issue")
    func commentDependsOnItsIssue() {
        let issue = Issue.ID()
        let operation = SyncOperation.putComment(
            opId: UUID(), id: Comment.ID(), at: Date(),
            body: CommentCreate(issueId: issue, body: "Looks right"))

        #expect(
            SyncDependencies.prerequisites(of: operation)
                == [SyncReference(entity: .issue, id: issue.rawValue)])
    }

    @Test("a label membership depends on both the issue and the label")
    func labelMembershipDependsOnBoth() {
        let issue = Issue.ID()
        let label = Label.ID()
        let operation = SyncOperation.addLabel(
            opId: UUID(), id: IssueLabel.ID(), at: Date(), issueId: issue, labelId: label)

        #expect(
            SyncDependencies.prerequisites(of: operation) == [
                SyncReference(entity: .issue, id: issue.rawValue),
                SyncReference(entity: .label, id: label.rawValue),
            ])
    }

    /// A create may name labels made in the same offline session.
    @Test("an issue create depends on any labels it names")
    func issueCreateDependsOnItsLabels() {
        let label = Label.ID()
        let operation = SyncOperation.putIssue(
            opId: UUID(), id: Issue.ID(), at: Date(), body: issueCreate(labels: [label]))

        #expect(
            SyncDependencies.prerequisites(of: operation)
                == [SyncReference(entity: .label, id: label.rawValue)])
    }

    /// Projects and Users are pulled, never pushed, so no queued operation can
    /// create one. Listing them as prerequisites would imply the queue might
    /// reorder to satisfy them, when in truth an issue in an unknown project has to
    /// fail at the server.
    @Test("a project is not a prerequisite, because no operation can create one")
    func projectIsNotAPrerequisite() {
        let operation = SyncOperation.putIssue(
            opId: UUID(), id: Issue.ID(), at: Date(), body: issueCreate())

        #expect(SyncDependencies.prerequisites(of: operation).isEmpty)
    }

    @Test("an assignee is not a prerequisite either")
    func assigneeIsNotAPrerequisite() {
        var patch = IssuePatch()
        patch.assigneeId = .set(User.ID())
        let operation = SyncOperation.patchIssue(
            opId: UUID(), id: Issue.ID(), at: Date(), body: patch)

        #expect(SyncDependencies.prerequisites(of: operation).isEmpty)
    }

    @Test("every operation names the entity it writes")
    func everyOperationNamesItsTarget() {
        let issue = Issue.ID()
        let target = SyncDependencies.target(
            of: .deleteIssue(opId: UUID(), id: issue, at: Date()))

        #expect(target == SyncReference(entity: .issue, id: issue.rawValue))
    }

    // MARK: Ordering

    /// The whole point: a child queued before its parent must still replay after it.
    @Test("a create is moved ahead of an operation that depends on it")
    func createMovesAheadOfItsDependent() {
        let issue = Issue.ID()
        let comment = SyncOperation.putComment(
            opId: UUID(), id: Comment.ID(), at: Date(),
            body: CommentCreate(issueId: issue, body: "First"))
        let create = SyncOperation.putIssue(
            opId: UUID(), id: issue, at: Date(), body: issueCreate())

        let ordered = SyncDependencies.ordered([comment, create])
        #expect(ordered.map(\.opId) == [create.opId, comment.opId])
    }

    /// Order within one entity is the user's own sequence of edits, and reordering
    /// it would change the outcome under last-write-wins.
    @Test("operations on one entity keep their original order")
    func operationsOnOneEntityKeepTheirOrder() {
        let issue = Issue.ID()
        var first = IssuePatch()
        first.title = .set("First")
        var second = IssuePatch()
        second.title = .set("Second")

        let a = SyncOperation.patchIssue(opId: UUID(), id: issue, at: Date(), body: first)
        let b = SyncOperation.patchIssue(opId: UUID(), id: issue, at: Date(), body: second)

        #expect(SyncDependencies.ordered([a, b]).map(\.opId) == [a.opId, b.opId])
    }

    /// Independent operations must not be shuffled: chronological order is what the
    /// user did, and a stable sort keeps a diff of the queue readable.
    @Test("independent operations are left in their original order")
    func independentOperationsAreLeftAlone() {
        let operations = (0..<5).map { index in
            SyncOperation.putIssue(
                opId: UUID(), id: Issue.ID(), at: Date().addingTimeInterval(Double(index)),
                body: issueCreate())
        }

        #expect(SyncDependencies.ordered(operations).map(\.opId) == operations.map(\.opId))
    }

    @Test("a chain of three orders correctly from any starting arrangement")
    func chainOfThreeOrdersCorrectly() {
        let label = Label.ID()
        let issue = Issue.ID()
        let makeLabel = SyncOperation.putLabel(
            opId: UUID(), id: label, at: Date(), body: LabelCreate(name: "bug", color: "#2D6CDF"))
        let makeIssue = SyncOperation.putIssue(
            opId: UUID(), id: issue, at: Date(), body: issueCreate(labels: [label]))
        let comment = SyncOperation.putComment(
            opId: UUID(), id: Comment.ID(), at: Date(),
            body: CommentCreate(issueId: issue, body: "Hi"))

        for arrangement in [
            [comment, makeIssue, makeLabel],
            [makeIssue, comment, makeLabel],
            [comment, makeLabel, makeIssue],
        ] {
            let ordered = SyncDependencies.ordered(arrangement).map(\.opId)
            #expect(ordered == [makeLabel.opId, makeIssue.opId, comment.opId])
        }
    }

    /// Found by building the sort: a patch with no prerequisites of its own looked
    /// "ready" and overtook its own create, which was still waiting on a label.
    /// The patch would then have reached the server before the record existed.
    @Test("a patch never overtakes its own create, even when the create is waiting")
    func patchNeverOvertakesItsOwnCreate() {
        let label = Label.ID()
        let comment = Comment.ID()
        let issue = Issue.ID()

        let makeLabel = SyncOperation.putLabel(
            opId: UUID(), id: label, at: Date(), body: LabelCreate(name: "bug", color: "#2D6CDF"))
        let makeIssue = SyncOperation.putIssue(
            opId: UUID(), id: issue, at: Date(), body: issueCreate(labels: [label]))
        let makeComment = SyncOperation.putComment(
            opId: UUID(), id: comment, at: Date(),
            body: CommentCreate(issueId: issue, body: "First"))
        var patch = CommentPatch()
        patch.body = .set("Edited")
        let editComment = SyncOperation.patchComment(
            opId: UUID(), id: comment, at: Date(), body: patch)

        // Deliberately queued with the label last, so the create chain is blocked
        // while the patch looks free.
        let ordered = SyncDependencies.ordered([makeIssue, makeComment, editComment, makeLabel])
            .map(\.opId)

        let createIndex = try! #require(ordered.firstIndex(of: makeComment.opId))
        let patchIndex = try! #require(ordered.firstIndex(of: editComment.opId))
        #expect(createIndex < patchIndex, "the patch overtook its own create")
        #expect(ordered.first == makeLabel.opId)
    }

    /// A reference to something the queue never creates is not reorderable. It must
    /// still be emitted, so the server can reject it and the user can be told.
    @Test("an operation referring to an id nothing creates is still emitted")
    func operationReferringToAnUncreatedIdIsStillEmitted() {
        let comment = SyncOperation.putComment(
            opId: UUID(), id: Comment.ID(), at: Date(),
            body: CommentCreate(issueId: Issue.ID(), body: "Orphan"))

        #expect(SyncDependencies.ordered([comment]).map(\.opId) == [comment.opId])
    }

    /// A cycle cannot arise from this domain, but a sort that silently dropped
    /// operations on encountering one would lose a user's work.
    @Test("ordering never loses or duplicates an operation")
    func orderingNeverLosesAnOperation() {
        let issue = Issue.ID()
        let operations = [
            SyncOperation.putComment(
                opId: UUID(), id: Comment.ID(), at: Date(),
                body: CommentCreate(issueId: issue, body: "One")),
            SyncOperation.deleteIssue(opId: UUID(), id: issue, at: Date()),
            SyncOperation.putIssue(opId: UUID(), id: issue, at: Date(), body: issueCreate()),
        ]

        let ordered = SyncDependencies.ordered(operations)
        #expect(Set(ordered.map(\.opId)) == Set(operations.map(\.opId)))
        #expect(ordered.count == operations.count)
    }

    // MARK: Blocking

    /// ADR 0004's hard requirement: a quarantined operation must not block the
    /// whole queue, only what causally depends on it.
    @Test("a quarantined create blocks its dependents and nothing else")
    func quarantinedCreateBlocksOnlyItsDependents() {
        let issue = Issue.ID()
        let create = SyncOperation.putIssue(
            opId: UUID(), id: issue, at: Date(), body: issueCreate())
        let comment = SyncOperation.putComment(
            opId: UUID(), id: Comment.ID(), at: Date(),
            body: CommentCreate(issueId: issue, body: "Blocked"))
        let unrelated = SyncOperation.putIssue(
            opId: UUID(), id: Issue.ID(), at: Date(), body: issueCreate())

        let blocked = SyncDependencies.blocked(
            by: [create.opId], in: [create, comment, unrelated])

        #expect(blocked == [comment.opId])
        #expect(!blocked.contains(unrelated.opId))
    }

    /// Head-of-line blocking is the specific failure to design against, so a later
    /// edit to the *same* entity is held back too — it would fail identically.
    @Test("a quarantined create blocks later edits to the same entity")
    func quarantinedCreateBlocksLaterEditsToTheSameEntity() {
        let issue = Issue.ID()
        let create = SyncOperation.putIssue(
            opId: UUID(), id: issue, at: Date(), body: issueCreate())
        var patch = IssuePatch()
        patch.title = .set("Renamed")
        let edit = SyncOperation.patchIssue(opId: UUID(), id: issue, at: Date(), body: patch)

        #expect(SyncDependencies.blocked(by: [create.opId], in: [create, edit]) == [edit.opId])
    }

    @Test("blocking is transitive")
    func blockingIsTransitive() {
        let label = Label.ID()
        let issue = Issue.ID()
        let makeLabel = SyncOperation.putLabel(
            opId: UUID(), id: label, at: Date(), body: LabelCreate(name: "bug", color: "#2D6CDF"))
        let makeIssue = SyncOperation.putIssue(
            opId: UUID(), id: issue, at: Date(), body: issueCreate(labels: [label]))
        let comment = SyncOperation.putComment(
            opId: UUID(), id: Comment.ID(), at: Date(),
            body: CommentCreate(issueId: issue, body: "Hi"))

        let blocked = SyncDependencies.blocked(
            by: [makeLabel.opId], in: [makeLabel, makeIssue, comment])

        #expect(blocked == [makeIssue.opId, comment.opId])
    }

    /// An edit that happens to precede a quarantined create of the same entity is
    /// not caused by it, and holding it back would be head-of-line blocking again.
    @Test("an earlier operation is not blocked by a later quarantine")
    func earlierOperationIsNotBlocked() {
        let issue = Issue.ID()
        var patch = IssuePatch()
        patch.title = .set("Early")
        let early = SyncOperation.patchIssue(opId: UUID(), id: Issue.ID(), at: Date(), body: patch)
        let create = SyncOperation.putIssue(
            opId: UUID(), id: issue, at: Date(), body: issueCreate())

        #expect(SyncDependencies.blocked(by: [create.opId], in: [early, create]).isEmpty)
    }

    @Test("nothing blocked means nothing held back")
    func nothingBlockedMeansNothingHeldBack() {
        let operations = [
            SyncOperation.putIssue(opId: UUID(), id: Issue.ID(), at: Date(), body: issueCreate())
        ]
        #expect(SyncDependencies.blocked(by: [], in: operations).isEmpty)
    }

    /// The blocked set names dependents, not the quarantined operation itself —
    /// that one is already quarantined and has its own error to show.
    @Test("the quarantined operation is not listed as blocked")
    func quarantinedOperationIsNotListedAsBlocked() {
        let create = SyncOperation.putIssue(
            opId: UUID(), id: Issue.ID(), at: Date(), body: issueCreate())
        #expect(!SyncDependencies.blocked(by: [create.opId], in: [create]).contains(create.opId))
    }
}
