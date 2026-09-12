import Foundation
import Testing

@testable import Core

/// Ticket 05's coalescing rules.
///
/// Replaying forty title patches yields the same end state as one, at forty times
/// the cost and forty chances to fail. The two hard exclusions are what keep it
/// safe: never coalesce across a delete, and never merge across entities.
@Suite("Sync coalescing")
struct SyncCoalescingTests {

    private let projectId = Project.ID()

    private func create(_ title: String = "A thing", labels: [Label.ID] = []) -> IssueCreate {
        IssueCreate(projectId: projectId, title: title, labelIds: labels)
    }

    private func titlePatch(_ title: String) -> IssuePatch {
        var patch = IssuePatch()
        patch.title = .set(title)
        return patch
    }

    // MARK: Merging patches

    @Test("later values win per field")
    func laterValuesWinPerField() {
        var first = IssuePatch()
        first.title = .set("First")
        first.priority = .set(.low)
        var second = IssuePatch()
        second.title = .set("Second")

        let merged = first.merging(second)
        #expect(merged.title == .set("Second"))
        // Untouched by the later patch, so the earlier value survives.
        #expect(merged.priority == .set(.low))
    }

    /// An unchanged field in the later patch means "I did not touch this", which
    /// must not erase what the earlier one said.
    @Test("an unchanged field does not overwrite an earlier value")
    func unchangedDoesNotOverwrite() {
        var first = IssuePatch()
        first.title = .set("First")

        #expect(first.merging(IssuePatch()).title == .set("First"))
    }

    /// Clearing is a real value, not an absence — that is the whole point of
    /// Merge Patch's three states.
    @Test("a later clear beats an earlier set")
    func laterClearBeatsEarlierSet() {
        var first = IssuePatch()
        first.assigneeId = .set(User.ID())
        var second = IssuePatch()
        second.assigneeId = .cleared

        #expect(first.merging(second).assigneeId == .cleared)
    }

    @Test("a later set beats an earlier clear")
    func laterSetBeatsEarlierClear() {
        let assignee = User.ID()
        var first = IssuePatch()
        first.assigneeId = .cleared
        var second = IssuePatch()
        second.assigneeId = .set(assignee)

        #expect(first.merging(second).assigneeId == .set(assignee))
    }

    @Test("merging is associative over a run of patches")
    func mergingIsAssociative() {
        let patches = ["one", "two", "three"].map(titlePatch)
        let leftToRight = patches.dropFirst().reduce(patches[0]) { $0.merging($1) }
        let folded = patches[0].merging(patches[1].merging(patches[2]))

        #expect(leftToRight.title == .set("three"))
        #expect(folded.title == .set("three"))
    }

    // MARK: Folding into a create

    /// A create that has not gone out yet is still editable, so there is no reason
    /// to send the original and then immediately correct it.
    @Test("a patch folds into an unsent create")
    func patchFoldsIntoUnsentCreate() {
        let issue = Issue.ID()
        let operations: [SyncOperation] = [
            .putIssue(opId: UUID(), id: issue, at: Date(), body: create("Original")),
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: titlePatch("Corrected")),
        ]

        let coalesced = SyncCoalescing.coalesced(operations)
        #expect(coalesced.count == 1)
        guard case .putIssue(_, _, _, let body) = coalesced[0] else {
            Issue.record("expected a single create")
            return
        }
        #expect(body.title == "Corrected")
    }

    @Test("a fold applies every field the patch set")
    func foldAppliesEveryField() {
        let issue = Issue.ID()
        let assignee = User.ID()
        var patch = IssuePatch()
        patch.title = .set("New")
        patch.description = .set("Body")
        patch.status = .set(.inProgress)
        patch.priority = .set(.urgent)
        patch.assigneeId = .set(assignee)
        patch.dueDate = .set(CivilDate(wireValue: "2026-12-25")!)

        let coalesced = SyncCoalescing.coalesced([
            .putIssue(opId: UUID(), id: issue, at: Date(), body: create()),
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: patch),
        ])

        guard case .putIssue(_, _, _, let body) = coalesced[0] else {
            Issue.record("expected a create")
            return
        }
        #expect(body.title == "New")
        #expect(body.description == "Body")
        #expect(body.status == .inProgress)
        #expect(body.priority == .urgent)
        #expect(body.assigneeId == assignee)
        #expect(body.dueDate?.wireValue == "2026-12-25")
    }

    @Test("a fold can clear a field the create set")
    func foldCanClearAField() {
        let issue = Issue.ID()
        var body = create()
        body.assigneeId = User.ID()
        var patch = IssuePatch()
        patch.assigneeId = .cleared

        let coalesced = SyncCoalescing.coalesced([
            .putIssue(opId: UUID(), id: issue, at: Date(), body: body),
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: patch),
        ])

        guard case .putIssue(_, _, _, let folded) = coalesced[0] else {
            Issue.record("expected a create")
            return
        }
        #expect(folded.assigneeId == nil)
    }

    /// The create keeps its own opId, so the server's retry dedupe still recognises
    /// it as the same operation if an earlier attempt got through.
    @Test("a fold keeps the create's operation id")
    func foldKeepsTheCreatesOperationId() {
        let issue = Issue.ID()
        let createOp = SyncOperation.putIssue(
            opId: UUID(), id: issue, at: Date(), body: create())

        let coalesced = SyncCoalescing.coalesced([
            createOp,
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: titlePatch("Corrected")),
        ])
        #expect(coalesced[0].opId == createOp.opId)
    }

    // MARK: The hard exclusions

    /// Deletion is terminal (ADR 0003). Merging across it could resurrect an edit
    /// after the delete, or drop the delete entirely.
    @Test("nothing coalesces across a delete")
    func nothingCoalescesAcrossADelete() {
        let issue = Issue.ID()
        let operations: [SyncOperation] = [
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: titlePatch("Before")),
            .deleteIssue(opId: UUID(), id: issue, at: Date()),
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: titlePatch("After")),
        ]

        let coalesced = SyncCoalescing.coalesced(operations)
        #expect(coalesced.count == 3)
        #expect(coalesced.map(\.opId) == operations.map(\.opId))
    }

    /// A create followed by a delete is left alone: cancelling the pair would mean
    /// the server never learns of an id that other queued operations may name.
    @Test("a create and a delete are both kept")
    func createAndDeleteAreBothKept() {
        let issue = Issue.ID()
        let operations: [SyncOperation] = [
            .putIssue(opId: UUID(), id: issue, at: Date(), body: create()),
            .deleteIssue(opId: UUID(), id: issue, at: Date()),
        ]
        #expect(SyncCoalescing.coalesced(operations).count == 2)
    }

    @Test("patches to different entities are never merged")
    func patchesToDifferentEntitiesAreNeverMerged() {
        let operations: [SyncOperation] = [
            .patchIssue(opId: UUID(), id: Issue.ID(), at: Date(), body: titlePatch("One")),
            .patchIssue(opId: UUID(), id: Issue.ID(), at: Date(), body: titlePatch("Two")),
        ]
        #expect(SyncCoalescing.coalesced(operations).count == 2)
    }

    /// Merging happens within one entity's own operations, so intervening writes to
    /// other entities do not prevent it — dependencies are on ids existing, never on
    /// another entity's field values.
    @Test("an intervening operation on another entity does not prevent merging")
    func interveningOperationDoesNotPreventMerging() {
        let issue = Issue.ID()
        let other = Issue.ID()
        let operations: [SyncOperation] = [
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: titlePatch("First")),
            .patchIssue(opId: UUID(), id: other, at: Date(), body: titlePatch("Elsewhere")),
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: titlePatch("Second")),
        ]

        let coalesced = SyncCoalescing.coalesced(operations)
        #expect(coalesced.count == 2)
        guard case .patchIssue(_, let firstId, _, let body) = coalesced[0] else {
            Issue.record("expected a patch first")
            return
        }
        #expect(firstId == issue)
        #expect(body.title == .set("Second"))
    }

    /// The merged patch takes the earliest position, so the user's original
    /// sequence is still recognisable in the queue.
    @Test("a merged patch keeps the earliest position")
    func mergedPatchKeepsEarliestPosition() {
        let issue = Issue.ID()
        let first = SyncOperation.patchIssue(
            opId: UUID(), id: issue, at: Date(), body: titlePatch("First"))
        let elsewhere = SyncOperation.patchIssue(
            opId: UUID(), id: Issue.ID(), at: Date(), body: titlePatch("Elsewhere"))
        let second = SyncOperation.patchIssue(
            opId: UUID(), id: issue, at: Date(), body: titlePatch("Second"))

        let coalesced = SyncCoalescing.coalesced([first, elsewhere, second])
        #expect(coalesced[0].opId == first.opId)
        #expect(coalesced[1].opId == elsewhere.opId)
    }

    // MARK: Other entities

    @Test("comment patches coalesce")
    func commentPatchesCoalesce() {
        let comment = Comment.ID()
        var first = CommentPatch()
        first.body = .set("One")
        var second = CommentPatch()
        second.body = .set("Two")

        let coalesced = SyncCoalescing.coalesced([
            .patchComment(opId: UUID(), id: comment, at: Date(), body: first),
            .patchComment(opId: UUID(), id: comment, at: Date(), body: second),
        ])

        #expect(coalesced.count == 1)
        guard case .patchComment(_, _, _, let body) = coalesced[0] else {
            Issue.record("expected a patch")
            return
        }
        #expect(body.body == .set("Two"))
    }

    @Test("a comment patch folds into its unsent create")
    func commentPatchFoldsIntoItsCreate() {
        let comment = Comment.ID()
        var patch = CommentPatch()
        patch.body = .set("Edited")

        let coalesced = SyncCoalescing.coalesced([
            .putComment(
                opId: UUID(), id: comment, at: Date(),
                body: CommentCreate(issueId: Issue.ID(), body: "Original")),
            .patchComment(opId: UUID(), id: comment, at: Date(), body: patch),
        ])

        #expect(coalesced.count == 1)
        guard case .putComment(_, _, _, let body) = coalesced[0] else {
            Issue.record("expected a create")
            return
        }
        #expect(body.body == "Edited")
    }

    @Test("label patches coalesce and fold")
    func labelPatchesCoalesceAndFold() {
        let label = Label.ID()
        var patch = LabelPatch()
        patch.color = .set("#123ABC")

        let coalesced = SyncCoalescing.coalesced([
            .putLabel(
                opId: UUID(), id: label, at: Date(),
                body: LabelCreate(name: "bug", color: "#2D6CDF")),
            .patchLabel(opId: UUID(), id: label, at: Date(), body: patch),
        ])

        #expect(coalesced.count == 1)
        guard case .putLabel(_, _, _, let body) = coalesced[0] else {
            Issue.record("expected a create")
            return
        }
        #expect(body.name == "bug")
        #expect(body.color == "#123ABC")
    }

    /// Label membership has no patch verb, so there is nothing to coalesce — and an
    /// add/remove pair must survive, because the server arbitrates them by receipt
    /// time.
    @Test("label membership operations are left alone")
    func labelMembershipIsLeftAlone() {
        let membership = IssueLabel.ID()
        let operations: [SyncOperation] = [
            .addLabel(
                opId: UUID(), id: membership, at: Date(),
                issueId: Issue.ID(), labelId: Label.ID()),
            .removeLabel(opId: UUID(), id: membership, at: Date()),
        ]
        #expect(SyncCoalescing.coalesced(operations).count == 2)
    }

    // MARK: Properties

    @Test("coalescing an empty queue gives an empty queue")
    func coalescingEmptyGivesEmpty() {
        #expect(SyncCoalescing.coalesced([]).isEmpty)
    }

    @Test("coalescing is idempotent")
    func coalescingIsIdempotent() {
        let issue = Issue.ID()
        let operations: [SyncOperation] = [
            .putIssue(opId: UUID(), id: issue, at: Date(), body: create()),
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: titlePatch("One")),
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: titlePatch("Two")),
        ]

        let once = SyncCoalescing.coalesced(operations)
        let twice = SyncCoalescing.coalesced(once)
        #expect(once.map(\.opId) == twice.map(\.opId))
    }

    /// Forty patches becoming one is the stated reason coalescing exists.
    @Test("a long run of patches becomes one")
    func longRunBecomesOne() {
        let issue = Issue.ID()
        let operations = (0..<40).map { index in
            SyncOperation.patchIssue(
                opId: UUID(), id: issue, at: Date(), body: titlePatch("Title \(index)"))
        }

        let coalesced = SyncCoalescing.coalesced(operations)
        #expect(coalesced.count == 1)
        guard case .patchIssue(_, _, _, let body) = coalesced[0] else {
            Issue.record("expected a patch")
            return
        }
        #expect(body.title == .set("Title 39"))
    }

    /// A patch that would be discarded entirely must not leave an empty operation
    /// behind, which would be a round trip that changes nothing.
    @Test("an empty patch is dropped")
    func emptyPatchIsDropped() {
        let issue = Issue.ID()
        let coalesced = SyncCoalescing.coalesced([
            .patchIssue(opId: UUID(), id: issue, at: Date(), body: IssuePatch())
        ])
        #expect(coalesced.isEmpty)
    }
}

@Suite("Label patch coalescing")
struct LabelPatchCoalescingTests {

    @Test("two label patches merge, later values winning")
    func twoLabelPatchesMerge() {
        let label = Label.ID()
        var first = LabelPatch()
        first.name = .set("bug")
        first.color = .set("#2D6CDF")
        var second = LabelPatch()
        second.color = .set("#123ABC")

        let coalesced = SyncCoalescing.coalesced([
            .patchLabel(opId: UUID(), id: label, at: Date(), body: first),
            .patchLabel(opId: UUID(), id: label, at: Date(), body: second),
        ])

        #expect(coalesced.count == 1)
        guard case .patchLabel(_, _, _, let body) = coalesced[0] else {
            Issue.record("expected a patch")
            return
        }
        #expect(body.color == .set("#123ABC"))
        // Untouched by the later patch, so the earlier value survives.
        #expect(body.name == .set("bug"))
    }

    @Test("merging label patches directly follows the same rule")
    func mergingLabelPatchesDirectly() {
        var first = LabelPatch()
        first.name = .set("bug")
        var second = LabelPatch()
        second.name = .set("defect")

        #expect(first.merging(second).name == .set("defect"))
        #expect(first.merging(LabelPatch()).name == .set("bug"))
    }

    @Test("an empty label patch is dropped")
    func emptyLabelPatchIsDropped() {
        #expect(
            SyncCoalescing.coalesced([
                .patchLabel(opId: UUID(), id: Label.ID(), at: Date(), body: LabelPatch())
            ]).isEmpty)
    }

    @Test("an empty comment patch is dropped")
    func emptyCommentPatchIsDropped() {
        #expect(
            SyncCoalescing.coalesced([
                .patchComment(opId: UUID(), id: Comment.ID(), at: Date(), body: CommentPatch())
            ]).isEmpty)
    }
}
