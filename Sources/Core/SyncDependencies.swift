import Foundation

/// An entity an operation writes or refers to.
public struct SyncReference: Hashable, Sendable {
    public let entity: SyncEntity
    public let id: UUID

    public init(entity: SyncEntity, id: UUID) {
        self.entity = entity
        self.id = id
    }
}

/// ADR 0004's causal ordering, as pure functions over operations.
///
/// The server rejects any reference to an id it has not seen, so a parent's create
/// must reach it before anything that names that parent. Ticket 05 keeps this in
/// Swift rather than in SQL deliberately: it is a domain contract, it should be
/// unit-testable without a database, and it should survive a change of storage.
///
/// Dependencies are **derived, not stored**. The domain has few relationship types,
/// and a stored edge list is state that can drift from the records it describes.
public enum SyncDependencies {

    /// The entity an operation writes.
    public static func target(of operation: SyncOperation) -> SyncReference {
        switch operation {
        case .putIssue(_, let id, _, _), .patchIssue(_, let id, _, _), .deleteIssue(_, let id, _):
            SyncReference(entity: .issue, id: id.rawValue)
        case .putComment(_, let id, _, _), .patchComment(_, let id, _, _),
            .deleteComment(_, let id, _):
            SyncReference(entity: .comment, id: id.rawValue)
        case .putLabel(_, let id, _, _), .patchLabel(_, let id, _, _), .deleteLabel(_, let id, _):
            SyncReference(entity: .label, id: id.rawValue)
        case .addLabel(_, let id, _, _, _), .removeLabel(_, let id, _):
            SyncReference(entity: .issueLabel, id: id.rawValue)
        }
    }

    /// Other entities this operation names, which must exist server-side first.
    ///
    /// **Projects and Users are deliberately absent.** No operation can create one —
    /// they are pulled, never pushed — so listing them would imply the queue might
    /// reorder to satisfy them. An issue naming an unknown project has to fail at
    /// the server; there is no local reordering that could help.
    public static func prerequisites(of operation: SyncOperation) -> Set<SyncReference> {
        switch operation {
        case .putIssue(_, _, _, let body):
            // A create may name labels made in the same offline session.
            Set(body.labelIds.map { SyncReference(entity: .label, id: $0.rawValue) })
        case .putComment(_, _, _, let body):
            [SyncReference(entity: .issue, id: body.issueId.rawValue)]
        case .addLabel(_, _, _, let issueId, let labelId):
            [
                SyncReference(entity: .issue, id: issueId.rawValue),
                SyncReference(entity: .label, id: labelId.rawValue),
            ]
        // A patch or delete names only its target, which the ordering below already
        // handles. `removeLabel` carries just the membership id, so the `addLabel`
        // that created it is its target, not a prerequisite.
        case .patchIssue, .deleteIssue, .putLabel, .patchComment, .deleteComment,
            .patchLabel, .deleteLabel, .removeLabel:
            []
        }
    }

    /// Orders operations so nothing reaches the server before what it refers to.
    ///
    /// A **stable** topological sort: independent operations keep their original
    /// order, because chronological order is what the user actually did, and
    /// shuffling it would make a diff of the queue unreadable. Order within one
    /// entity is never changed — under per-field last-write-wins, reordering a
    /// user's own edits changes the outcome.
    public static func ordered(_ operations: [SyncOperation]) -> [SyncOperation] {
        var remaining = operations
        var emitted: [SyncOperation] = []
        var satisfied: Set<SyncReference> = []
        // Targets still waiting to go out. An operation waits only for a reference
        // something *else* in this batch will create; a reference nobody creates is
        // not reorderable and must still be sent, so the server can reject it and
        // the user can be told why.
        var pendingTargets = countsByTarget(operations)

        while !remaining.isEmpty {
            let index = nextReadyIndex(
                in: remaining, satisfied: satisfied, pendingTargets: pendingTargets)
            // No candidate means a cycle, which this domain cannot produce. Emitting
            // the head rather than stopping matters: silently dropping the rest
            // would lose the user's work, which is the one outcome ADR 0004 forbids.
            let next = remaining.remove(at: index ?? 0)
            let targetOfNext = target(of: next)
            pendingTargets[targetOfNext, default: 1] -= 1
            if pendingTargets[targetOfNext] == 0 { pendingTargets[targetOfNext] = nil }
            satisfied.insert(targetOfNext)
            emitted.append(next)
        }
        return emitted
    }

    /// The earliest operation that can go out now.
    ///
    /// Scans in queue order and skips any operation with an earlier unemitted
    /// sibling — without that, a patch whose own create is still waiting on a
    /// prerequisite would overtake it, and the patch would reach the server first.
    private static func nextReadyIndex(
        in remaining: [SyncOperation],
        satisfied: Set<SyncReference>,
        pendingTargets: [SyncReference: Int]
    ) -> Int? {
        var seenTargets: Set<SyncReference> = []

        for (index, operation) in remaining.enumerated() {
            let targetOfOperation = target(of: operation)
            // An earlier operation on the same entity is still queued, so this one
            // must wait: reordering a user's own edits changes the outcome under
            // per-field last-write-wins.
            let hasEarlierSibling = !seenTargets.insert(targetOfOperation).inserted

            let waitingOnAnother = prerequisites(of: operation).contains { reference in
                !satisfied.contains(reference) && pendingTargets[reference] != nil
            }

            if !hasEarlierSibling && !waitingOnAnother { return index }
        }
        return nil
    }

    /// Which operations cannot go out, given a set that cannot.
    ///
    /// ADR 0004's hard requirement is that a quarantined operation holds back only
    /// what causally depends on it — head-of-line blocking is the specific failure
    /// mode to design against. Transitive, and evaluated in queue order, so an
    /// operation that merely *precedes* a quarantined one is untouched.
    public static func blocked(
        by blockedOpIds: Set<UUID>, in operations: [SyncOperation]
    ) -> Set<UUID> {
        var unavailable: Set<SyncReference> = []
        var held: Set<UUID> = []

        for operation in operations {
            let isBlockedItself = blockedOpIds.contains(operation.opId)
            let dependsOnSomethingHeld =
                !prerequisites(of: operation).isDisjoint(with: unavailable)
                || unavailable.contains(target(of: operation))

            if isBlockedItself || dependsOnSomethingHeld {
                // Anything this operation would have written is now unavailable to
                // everything after it, which is what makes blocking transitive.
                unavailable.insert(target(of: operation))
                // The quarantined operation itself is not "blocked": it already has
                // its own error to show the user.
                if !isBlockedItself { held.insert(operation.opId) }
            }
        }
        return held
    }

    private static func countsByTarget(_ operations: [SyncOperation]) -> [SyncReference: Int] {
        operations.reduce(into: [:]) { counts, operation in
            counts[target(of: operation), default: 0] += 1
        }
    }
}
