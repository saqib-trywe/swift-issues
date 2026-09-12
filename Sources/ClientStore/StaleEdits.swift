import Core
import Foundation
import GRDB

/// An unsent edit that will overwrite newer work when it is pushed.
///
/// The server does pure last-write-wins arbitrated by receipt time, so a
/// three-day-old offline edit beats a change somebody made this morning. This is
/// the **only** place a user can learn that before it happens: ADR 0005 rejected
/// optimistic concurrency deliberately, so there is no server-side check to fall
/// back on.
public struct StaleEdit: Sendable {
    public let operation: SyncOperation
    /// Which fields would be overwritten. Empty for a whole-record operation.
    public let fields: Set<IssueField>
    /// When the user made this edit.
    public let editedAt: Date
    /// When the record last changed on the server, which is after `editedAt`.
    public let serverChangedAt: Date

    public var entity: SyncReference { SyncDependencies.target(of: operation) }

    public init(
        operation: SyncOperation,
        fields: Set<IssueField>,
        editedAt: Date,
        serverChangedAt: Date
    ) {
        self.operation = operation
        self.fields = fields
        self.editedAt = editedAt
        self.serverChangedAt = serverChangedAt
    }
}

extension ReplicaDatabase {

    /// How much newer the server's record must be before this is worth saying.
    ///
    /// Timestamps lose sub-millisecond precision differently through SQLite and
    /// through JSON, so two records written from the same instant can come back
    /// microseconds apart. Warning on that would be a false alarm, and a warning
    /// people learn to ignore protects nobody. A second is far below the scale of
    /// a real offline edit and far above the rounding noise.
    static let staleThreshold: TimeInterval = 1

    /// Unsent edits that would overwrite work done elsewhere since they were made.
    ///
    /// Detected by comparing the edit's own timestamp with the base record's
    /// `updatedAt`: the base is what the server last confirmed, so a base newer
    /// than the edit means somebody else has written in the meantime. Advisory
    /// only — nothing is blocked, because ADR 0005's last-write-wins is the
    /// intended behaviour and this is a warning, not a veto.
    public func staleEdits() throws -> [StaleEdit] {
        try reader.read { db in
            let queued = try Row.fetchAll(
                db, sql: "SELECT * FROM pending_operation ORDER BY sequence"
            ).compactMap(Self.pending(from:))
            guard !queued.isEmpty else { return [] }

            var stale: [StaleEdit] = []
            for entry in queued {
                // A create cannot clobber anything: the id is new, so there is no
                // other work to overwrite.
                guard case .patchIssue(_, let id, let editedAt, let patch) = entry.operation
                else { continue }

                guard let base = try Self.issueRow(db, id: id) else { continue }
                // Meaningfully newer: an equal — or microscopically different —
                // timestamp is this device's own write coming back, not somebody
                // else's change.
                guard base.updatedAt.timeIntervalSince(editedAt) > Self.staleThreshold
                else { continue }

                stale.append(
                    StaleEdit(
                        operation: entry.operation,
                        fields: Self.fields(of: patch),
                        editedAt: editedAt,
                        serverChangedAt: base.updatedAt))
            }
            return stale
        }
    }

    /// Which fields a patch would write.
    static func fields(of patch: IssuePatch) -> Set<IssueField> {
        var fields: Set<IssueField> = []
        if !patch.title.isUnchanged { fields.insert(.title) }
        if !patch.description.isUnchanged { fields.insert(.description) }
        if !patch.status.isUnchanged { fields.insert(.status) }
        if !patch.priority.isUnchanged { fields.insert(.priority) }
        if !patch.assigneeId.isUnchanged { fields.insert(.assignee) }
        if !patch.dueDate.isUnchanged { fields.insert(.dueDate) }
        return fields
    }

    /// Work the server rejected, waiting for the user to repair or discard it.
    public func quarantinedWork() throws -> [PendingOperation] {
        try allOperations().filter { $0.state == .quarantined }
    }
}
