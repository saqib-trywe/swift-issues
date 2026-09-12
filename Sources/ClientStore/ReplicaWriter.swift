import Core
import Foundation
import GRDB

extension ReplicaDatabase {

    /// The client's position in the server's change stream.
    public func watermark() throws -> Watermark? {
        try reader.read { db in
            (try String.fetchOne(db, sql: "SELECT watermark FROM sync_state WHERE id = 1"))
                .flatMap(Watermark.init)
        }
    }

    func setWatermark(_ watermark: Watermark?, in db: Database) throws {
        try db.execute(
            sql: "UPDATE sync_state SET watermark = ? WHERE id = 1",
            arguments: [watermark?.wireValue])
    }

    /// Applies a page of pulled changes and advances the watermark, atomically.
    ///
    /// One transaction per page on purpose: a crash mid-page must not leave the
    /// watermark ahead of the records it claims to cover, which would skip those
    /// changes permanently.
    public func apply(_ changes: [SyncChange], upTo watermark: Watermark) throws {
        try writer.write { db in
            for change in changes {
                try Self.apply(change, in: db)
            }
            try setWatermark(watermark, in: db)
        }
    }

    /// Discards every base record and the watermark, keeping the pending queue.
    ///
    /// Used when the server reports a superseded epoch after a restore (ticket 09).
    /// The queue is **never** cleared: it is unsent user work, and losing it to a
    /// server-side operational event is exactly the silent data loss ADR 0004
    /// forbids.
    public func resetForFullResync() throws {
        try writer.write { db in
            for table in ["issue", "comment", "label", "issue_label", "project", "user"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try setWatermark(nil, in: db)
        }
    }

    static func apply(_ change: SyncChange, in db: Database) throws {
        guard !change.deleted else {
            try tombstone(entity: change.entity, id: change.id, in: db)
            return
        }
        guard let record = change.record else {
            // A non-deleted change with no record is a server bug. Skipping beats
            // throwing: one malformed entry must not stall the whole stream, and the
            // next pull will carry the record again.
            return
        }
        try upsert(record, in: db)
    }

    private static func tombstone(entity: SyncEntity, id: UUID, in db: Database) throws {
        // A tombstone can arrive for a record this client has never seen, because
        // pull order is change order. The row is created so the tombstone is not
        // lost — forgetting it would resurrect the record on a later pull.
        switch entity {
        case .issue:
            try db.execute(
                sql: """
                    INSERT INTO issue
                        (id, project_id, title, description, status, priority,
                         reporter_id, via, created_at, updated_at, deleted_at)
                    VALUES (?, '', '', '', 'todo', 'none', '', 'human', ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET deleted_at = excluded.deleted_at
                    """,
                arguments: [id.uuidString, Date(), Date(), Date()])
        case .comment:
            try db.execute(
                sql: """
                    INSERT INTO comment
                        (id, issue_id, author_id, body, via, created_at, updated_at, deleted_at)
                    VALUES (?, '', '', NULL, 'human', ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET body = NULL, deleted_at = excluded.deleted_at
                    """,
                arguments: [id.uuidString, Date(), Date(), Date()])
        case .label:
            try db.execute(
                sql: """
                    INSERT INTO label
                        (id, project_id, name, color, created_at, updated_at, deleted_at)
                    VALUES (?, '', '', '#000000', ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET deleted_at = excluded.deleted_at
                    """,
                arguments: [id.uuidString, Date(), Date(), Date()])
        case .issueLabel:
            try db.execute(
                sql: "UPDATE issue_label SET deleted_at = ? WHERE id = ?",
                arguments: [Date(), id.uuidString])
        case .project, .user:
            // Neither is ever tombstoned: a Project archives and a User deactivates,
            // both of which arrive as ordinary records.
            break
        }
    }

    private static func upsert(_ record: SyncRecord, in db: Database) throws {
        switch record {
        case .issue(let issue):
            try db.execute(
                sql: """
                    INSERT INTO issue
                        (id, key, project_id, title, description, status, priority,
                         reporter_id, assignee_id, due_date, via, created_at, updated_at, deleted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        key = excluded.key, title = excluded.title,
                        description = excluded.description, status = excluded.status,
                        priority = excluded.priority, assignee_id = excluded.assignee_id,
                        due_date = excluded.due_date, updated_at = excluded.updated_at,
                        deleted_at = excluded.deleted_at,
                        -- Server-owned and immutable, but a locally created row holds
                        -- placeholders for them: the reporter comes from the token and
                        -- `via` from its kind, neither of which a client can know. The
                        -- first authoritative record has to fill them in, or the
                        -- replica keeps the placeholder forever.
                        project_id = excluded.project_id, reporter_id = excluded.reporter_id,
                        via = excluded.via, created_at = excluded.created_at
                    """,
                arguments: [
                    issue.id.rawValue.uuidString, issue.key?.wireValue,
                    issue.projectId.rawValue.uuidString, issue.title, issue.description,
                    issue.status.wireValue, issue.priority.wireValue,
                    issue.reporterId.rawValue.uuidString, issue.assigneeId?.rawValue.uuidString,
                    issue.dueDate?.wireValue, issue.via.wireValue,
                    issue.createdAt, issue.updatedAt, issue.deletedAt,
                ])

        case .comment(let comment):
            try db.execute(
                sql: """
                    INSERT INTO comment
                        (id, issue_id, author_id, body, via, created_at, updated_at, deleted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        body = excluded.body, updated_at = excluded.updated_at,
                        deleted_at = excluded.deleted_at,
                        -- As with an issue: a locally created comment cannot know its
                        -- author or `via`, so the placeholders must be replaced.
                        issue_id = excluded.issue_id, author_id = excluded.author_id,
                        via = excluded.via, created_at = excluded.created_at
                    """,
                arguments: [
                    comment.id.rawValue.uuidString, comment.issueId.rawValue.uuidString,
                    comment.authorId.rawValue.uuidString, comment.body, comment.via.wireValue,
                    comment.createdAt, comment.updatedAt, comment.deletedAt,
                ])

        case .label(let label):
            try db.execute(
                sql: """
                    INSERT INTO label
                        (id, project_id, name, color, created_at, updated_at, deleted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        name = excluded.name, color = excluded.color,
                        updated_at = excluded.updated_at, deleted_at = excluded.deleted_at,
                        project_id = excluded.project_id, created_at = excluded.created_at
                    """,
                arguments: [
                    label.id.rawValue.uuidString, label.projectId.rawValue.uuidString,
                    label.name, label.color, label.createdAt, label.updatedAt, label.deletedAt,
                ])

        case .issueLabel(let link):
            try db.execute(
                sql: """
                    INSERT INTO issue_label (id, issue_id, label_id, created_at, deleted_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (issue_id, label_id) DO UPDATE SET
                        deleted_at = excluded.deleted_at
                    """,
                arguments: [
                    link.id.rawValue.uuidString, link.issueId.rawValue.uuidString,
                    link.labelId.rawValue.uuidString, link.createdAt, link.deletedAt,
                ])

        case .project(let project):
            try db.execute(
                sql: """
                    INSERT INTO project
                        (id, key, name, description, archived, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        key = excluded.key, name = excluded.name,
                        description = excluded.description, archived = excluded.archived,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    project.id.rawValue.uuidString, project.key.wireValue, project.name,
                    project.description, project.archived, project.createdAt, project.updatedAt,
                ])

        case .user(let user):
            try db.execute(
                sql: """
                    INSERT INTO user
                        (id, email, display_name, role, active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        email = excluded.email, display_name = excluded.display_name,
                        role = excluded.role, active = excluded.active,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    user.id.rawValue.uuidString, user.email, user.displayName,
                    user.role.wireValue, user.active, user.createdAt, user.updatedAt,
                ])
        }
    }
}
