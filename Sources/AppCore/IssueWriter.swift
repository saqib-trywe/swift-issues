import ClientStore
import Core
import Foundation

/// Queues writes made in the app.
///
/// Everything goes to the offline queue, never straight to the network: the write
/// lands locally and the sync engine sends it when it can, which is what makes the
/// app work on a plane. The overlay shows it immediately.
public struct IssueWriter: Sendable {
    private let database: ReplicaDatabase

    public init(database: ReplicaDatabase) {
        self.database = database
    }

    /// Queues a new issue, returning the id it was given.
    ///
    /// UUIDv7, generated here: a client-generated id is what lets a create be made
    /// offline at all, and what makes a retry after a lost response idempotent
    /// rather than a duplicate (ADR 0003).
    @discardableResult
    public func create(
        _ draft: IssueDraft,
        in projectId: Project.ID,
        labelIds: [Label.ID] = [],
        at now: Date = Date()
    ) throws -> Issue.ID {
        guard draft.isValid else { throw WriteError.invalid(draft.validationFailures) }

        let id = Issue.ID(UUIDv7.generate())
        try database.enqueue(
            .putIssue(
                opId: UUIDv7.generate(), id: id, at: now,
                body: draft.create(projectId: projectId, labelIds: labelIds)),
            at: now)
        return id
    }

    /// Queues an edit, or nothing when nothing changed.
    ///
    /// Returns whether anything was queued, so a save button can report "no
    /// changes" rather than silently appearing to have done something.
    @discardableResult
    public func edit(
        _ id: Issue.ID,
        from original: IssueDraft,
        to edited: IssueDraft,
        at now: Date = Date()
    ) throws -> Bool {
        guard edited.isValid else { throw WriteError.invalid(edited.validationFailures) }

        let patch = edited.patch(against: original)
        guard !patch.isEmpty else { return false }

        try database.enqueue(
            .patchIssue(opId: UUIDv7.generate(), id: id, at: now, body: patch), at: now)
        return true
    }

    @discardableResult
    public func comment(
        on issueId: Issue.ID, body: String, at now: Date = Date()
    ) throws -> Comment.ID {
        let failures = Validation.comment(body: body)
        guard failures.isEmpty else { throw WriteError.invalid(failures) }

        let id = Comment.ID(UUIDv7.generate())
        try database.enqueue(
            .putComment(
                opId: UUIDv7.generate(), id: id, at: now,
                body: CommentCreate(issueId: issueId, body: body)),
            at: now)
        return id
    }

    /// Queues a deletion. Terminal, and not undoable from here.
    public func delete(_ id: Issue.ID, at now: Date = Date()) throws {
        try database.enqueue(.deleteIssue(opId: UUIDv7.generate(), id: id, at: now), at: now)
    }
}

public enum WriteError: Error, CustomStringConvertible {
    case invalid([ValidationFailure])

    public var description: String {
        switch self {
        case .invalid(let failures):
            failures.map(\.message).joined(separator: " ")
        }
    }
}
