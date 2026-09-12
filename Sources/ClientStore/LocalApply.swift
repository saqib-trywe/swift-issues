import Core
import Foundation
import GRDB

extension ReplicaDatabase {

    /// Stands in for an id only the server can supply.
    ///
    /// A locally created issue has no reporter and a local comment no author: both
    /// come from the token, server-side. An empty string would be unparseable and
    /// the row would be skipped on read — so the record a user just made would be
    /// invisible until it synced. A well-known zero UUID is readable, obviously not
    /// a real id, and replaced by the first authoritative record.
    static let unknownID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// What a queued write puts on disk *before* the server has seen it.
    ///
    /// Only a create, and only the row itself. Ticket 05 keeps the base tables
    /// server-authoritative and derives the displayed value by overlaying pending
    /// operations at read time — the queue already records what is locally changed,
    /// and a second dirty copy could disagree with it.
    ///
    /// A create is the exception because there is no server record to overlay onto:
    /// without a row there would be nothing to show at all, and every list query
    /// would have to merge unsent creates in Swift rather than in SQL.
    static func applyProvisionally(
        _ operation: SyncOperation, in db: Database, at now: Date
    ) throws {
        switch operation {
        case .putIssue, .putComment, .putLabel, .addLabel:
            try applyConfirmed(operation, in: db, at: now)
        // A patch or a delete changes a record that already exists, so it is carried
        // by the queue alone until the server confirms it. That is what lets a
        // discarded quarantined operation revert cleanly, and what stops a rejected
        // delete leaving the replica claiming a deletion that never happened.
        case .patchIssue, .deleteIssue, .patchComment, .deleteComment,
            .patchLabel, .deleteLabel, .removeLabel:
            break
        }
    }

    /// Applies a write the server has accepted.
    ///
    /// Called on acknowledgement rather than on enqueue, so the base tables only
    /// ever hold what the server has confirmed — and so a successful push leaves the
    /// replica correct without waiting for the pull that follows.
    static func applyConfirmed(_ operation: SyncOperation, in db: Database, at now: Date) throws {
        switch operation {
        case .putIssue(_, let id, _, let body):
            try db.execute(
                sql: """
                    INSERT INTO issue
                        (id, key, project_id, title, description, status, priority,
                         reporter_id, assignee_id, due_date, via, created_at, updated_at)
                    VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, 'human', ?, ?)
                    ON CONFLICT (id) DO NOTHING
                    """,
                arguments: [
                    id.rawValue.uuidString, body.projectId.rawValue.uuidString, body.title,
                    body.description, body.status.wireValue, body.priority.wireValue,
                    // The reporter comes from the token, server-side, so a local
                    // create cannot know it. Replaced by the first record that
                    // arrives.
                    unknownID.uuidString, body.assigneeId?.rawValue.uuidString,
                    body.dueDate?.wireValue, now, now,
                ])
            for labelId in body.labelIds {
                try attach(issueId: id, labelId: labelId, in: db, at: now)
            }

        case .patchIssue(_, let id, _, let body):
            try patchIssue(id, body, in: db, at: now)

        case .deleteIssue(_, let id, _):
            // Terminal, and the tombstone is kept indefinitely: a client that forgot
            // one would resurrect the record on its next pull.
            try db.execute(
                sql: "UPDATE issue SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id.rawValue.uuidString])

        case .putComment(_, let id, _, let body):
            try db.execute(
                sql: """
                    INSERT INTO comment
                        (id, issue_id, author_id, body, via, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'human', ?, ?)
                    ON CONFLICT (id) DO NOTHING
                    """,
                arguments: [
                    id.rawValue.uuidString, body.issueId.rawValue.uuidString,
                    unknownID.uuidString, body.body, now, now,
                ])

        case .patchComment(_, let id, _, let body):
            if case .set(let text) = body.body {
                try db.execute(
                    sql: "UPDATE comment SET body = ?, updated_at = ? WHERE id = ?",
                    arguments: [text, now, id.rawValue.uuidString])
            }

        case .deleteComment(_, let id, _):
            // The body is cleared rather than the row removed, matching the server:
            // a deleted comment still occupies its place in a thread.
            try db.execute(
                sql: "UPDATE comment SET body = NULL, deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id.rawValue.uuidString])

        case .putLabel(_, let id, _, let body):
            try db.execute(
                sql: """
                    INSERT INTO label (id, project_id, name, color, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO NOTHING
                    """,
                arguments: [
                    id.rawValue.uuidString, unknownID.uuidString, body.name, body.color, now, now,
                ])

        case .patchLabel(_, let id, _, let body):
            if case .set(let name) = body.name {
                try db.execute(
                    sql: "UPDATE label SET name = ?, updated_at = ? WHERE id = ?",
                    arguments: [name, now, id.rawValue.uuidString])
            }
            if case .set(let color) = body.color {
                try db.execute(
                    sql: "UPDATE label SET color = ?, updated_at = ? WHERE id = ?",
                    arguments: [color, now, id.rawValue.uuidString])
            }

        case .deleteLabel(_, let id, _):
            try db.execute(
                sql: "UPDATE label SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id.rawValue.uuidString])

        case .addLabel(_, let id, _, let issueId, let labelId):
            try db.execute(
                sql: """
                    INSERT INTO issue_label (id, issue_id, label_id, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT (issue_id, label_id) DO UPDATE SET deleted_at = NULL
                    """,
                arguments: [
                    id.rawValue.uuidString, issueId.rawValue.uuidString,
                    labelId.rawValue.uuidString, now,
                ])

        case .removeLabel(_, let id, _):
            try db.execute(
                sql: "UPDATE issue_label SET deleted_at = ? WHERE id = ?",
                arguments: [now, id.rawValue.uuidString])
        }
    }

    /// Applies only the fields a patch actually names.
    ///
    /// Field by field rather than as one statement, because a whole-record update
    /// would carry stale values for untouched fields — and under per-field
    /// last-write-wins those stale values would beat somebody else's newer edit,
    /// silently reverting their work.
    private static func patchIssue(
        _ id: Issue.ID, _ patch: IssuePatch, in db: Database, at now: Date
    ) throws {
        func set(_ column: String, _ value: (any DatabaseValueConvertible)?) throws {
            try db.execute(
                sql: "UPDATE issue SET \(column) = ?, updated_at = ? WHERE id = ?",
                arguments: [value, now, id.rawValue.uuidString])
        }

        if case .set(let value) = patch.title { try set("title", value) }
        if case .set(let value) = patch.description { try set("description", value) }
        if case .set(let value) = patch.status { try set("status", value.wireValue) }
        if case .set(let value) = patch.priority { try set("priority", value.wireValue) }

        switch patch.assigneeId {
        case .set(let value): try set("assignee_id", value.rawValue.uuidString)
        case .cleared: try set("assignee_id", nil)
        case .unchanged: break
        }
        switch patch.dueDate {
        case .set(let value): try set("due_date", value.wireValue)
        case .cleared: try set("due_date", nil)
        case .unchanged: break
        }
    }

    private static func attach(
        issueId: Issue.ID, labelId: Label.ID, in db: Database, at now: Date
    ) throws {
        // Convergence is on `(issue_id, label_id)`, matching the server: two clients
        // adding the same label converge on one membership even though each invented
        // its own row id.
        try db.execute(
            sql: """
                INSERT INTO issue_label (id, issue_id, label_id, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (issue_id, label_id) DO UPDATE SET deleted_at = NULL
                """,
            arguments: [
                IssueLabel.ID(UUIDv7.generate()).rawValue.uuidString,
                issueId.rawValue.uuidString, labelId.rawValue.uuidString, now,
            ])
    }
}
