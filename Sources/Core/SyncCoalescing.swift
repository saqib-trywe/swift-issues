import Foundation

extension Settable {
    /// Later wins, unless the later value says nothing.
    ///
    /// `.unchanged` means "I did not touch this", so it must not erase what an
    /// earlier patch said.
    public func merging(_ later: Settable<Value>) -> Settable<Value> {
        later.isUnchanged ? self : later
    }
}

extension Patchable {
    /// Later wins, unless the later value says nothing.
    ///
    /// `.cleared` is a real value rather than an absence — that is the whole point
    /// of Merge Patch's three states — so a later clear beats an earlier set.
    public func merging(_ later: Patchable<Value>) -> Patchable<Value> {
        later.isUnchanged ? self : later
    }
}

extension IssuePatch {
    public func merging(_ later: IssuePatch) -> IssuePatch {
        var merged = IssuePatch()
        merged.title = title.merging(later.title)
        merged.description = description.merging(later.description)
        merged.status = status.merging(later.status)
        merged.priority = priority.merging(later.priority)
        merged.assigneeId = assigneeId.merging(later.assigneeId)
        merged.dueDate = dueDate.merging(later.dueDate)
        return merged
    }

    /// Applies this patch to a create that has not gone out yet.
    ///
    /// A create still in the queue is editable, so there is no reason to send the
    /// original and then immediately correct it.
    public func applied(to body: IssueCreate) -> IssueCreate {
        var folded = body
        if case .set(let value) = title { folded.title = value }
        if case .set(let value) = description { folded.description = value }
        if case .set(let value) = status { folded.status = value }
        if case .set(let value) = priority { folded.priority = value }
        switch assigneeId {
        case .set(let value): folded.assigneeId = value
        case .cleared: folded.assigneeId = nil
        case .unchanged: break
        }
        switch dueDate {
        case .set(let value): folded.dueDate = value
        case .cleared: folded.dueDate = nil
        case .unchanged: break
        }
        return folded
    }
}

extension CommentPatch {
    public func merging(_ later: CommentPatch) -> CommentPatch {
        var merged = CommentPatch()
        merged.body = body.merging(later.body)
        return merged
    }

    public func applied(to create: CommentCreate) -> CommentCreate {
        var folded = create
        if case .set(let value) = body { folded.body = value }
        return folded
    }
}

extension LabelPatch {
    public func merging(_ later: LabelPatch) -> LabelPatch {
        var merged = LabelPatch()
        merged.name = name.merging(later.name)
        merged.color = color.merging(later.color)
        return merged
    }

    public func applied(to create: LabelCreate) -> LabelCreate {
        var folded = create
        if case .set(let value) = name { folded.name = value }
        if case .set(let value) = color { folded.color = value }
        return folded
    }
}

/// Ticket 05's coalescing, as a pure function over a queue.
///
/// Replaying forty title patches yields the same end state as one, at forty times
/// the cost and forty chances to fail. Two exclusions keep it safe: **never
/// coalesce across a delete**, because deletion is terminal (ADR 0003), and **never
/// merge across entities**.
///
/// Merging one entity's patches *through* writes to other entities is safe and
/// deliberate: causal dependencies are on ids existing, never on another entity's
/// field values, so nothing can observe the difference.
public enum SyncCoalescing {

    /// Merges what can be merged, preserving queue order otherwise.
    ///
    /// A merged operation takes the **earliest** position of the group, so the
    /// user's original sequence is still recognisable in the queue.
    public static func coalesced(_ operations: [SyncOperation]) -> [SyncOperation] {
        var result: [SyncOperation] = []
        // Where each entity's currently-mergeable operation sits in `result`, and
        // therefore what a later patch may fold into. Cleared by a delete, which
        // nothing merges across.
        var openSlots: [SyncReference: Int] = [:]

        for operation in operations {
            let reference = SyncDependencies.target(of: operation)

            switch operation {
            case .deleteIssue, .deleteComment, .deleteLabel, .removeLabel:
                // Terminal: anything after this is a separate operation, and the
                // delete itself is never merged into.
                openSlots[reference] = nil
                result.append(operation)

            case .putIssue, .putComment, .putLabel, .addLabel:
                openSlots[reference] = result.count
                result.append(operation)

            case .patchIssue(_, _, _, let patch):
                append(
                    operation, patch: patch, reference: reference,
                    into: &result, slots: &openSlots,
                    isEmpty: { $0.isEmpty },
                    fold: Self.foldIssue)

            case .patchComment(_, _, _, let patch):
                append(
                    operation, patch: patch, reference: reference,
                    into: &result, slots: &openSlots,
                    isEmpty: { $0.body.isUnchanged },
                    fold: Self.foldComment)

            case .patchLabel(_, _, _, let patch):
                append(
                    operation, patch: patch, reference: reference,
                    into: &result, slots: &openSlots,
                    isEmpty: { $0.name.isUnchanged && $0.color.isUnchanged },
                    fold: Self.foldLabel)
            }
        }
        return result
    }

    /// Folds a patch into whatever is already open for its entity, or opens a slot.
    private static func append<Patch>(
        _ operation: SyncOperation,
        patch: Patch,
        reference: SyncReference,
        into result: inout [SyncOperation],
        slots: inout [SyncReference: Int],
        isEmpty: (Patch) -> Bool,
        fold: (SyncOperation, Patch) -> SyncOperation?
    ) {
        // A patch that changes nothing is a round trip that changes nothing.
        guard !isEmpty(patch) else { return }

        if let slot = slots[reference], let merged = fold(result[slot], patch) {
            result[slot] = merged
            return
        }
        slots[reference] = result.count
        result.append(operation)
    }

    private static func foldIssue(_ existing: SyncOperation, _ patch: IssuePatch)
        -> SyncOperation?
    {
        switch existing {
        // The create keeps its own opId, so the server's retry dedupe still
        // recognises it if an earlier attempt got through.
        case .putIssue(let opId, let id, let at, let body):
            .putIssue(opId: opId, id: id, at: at, body: patch.applied(to: body))
        case .patchIssue(let opId, let id, let at, let body):
            .patchIssue(opId: opId, id: id, at: at, body: body.merging(patch))
        default:
            nil
        }
    }

    private static func foldComment(_ existing: SyncOperation, _ patch: CommentPatch)
        -> SyncOperation?
    {
        switch existing {
        case .putComment(let opId, let id, let at, let body):
            .putComment(opId: opId, id: id, at: at, body: patch.applied(to: body))
        case .patchComment(let opId, let id, let at, let body):
            .patchComment(opId: opId, id: id, at: at, body: body.merging(patch))
        default:
            nil
        }
    }

    private static func foldLabel(_ existing: SyncOperation, _ patch: LabelPatch)
        -> SyncOperation?
    {
        switch existing {
        case .putLabel(let opId, let id, let at, let body):
            .putLabel(opId: opId, id: id, at: at, body: patch.applied(to: body))
        case .patchLabel(let opId, let id, let at, let body):
            .patchLabel(opId: opId, id: id, at: at, body: body.merging(patch))
        default:
            nil
        }
    }
}
