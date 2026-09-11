import Core
import Foundation
import GRDB

/// Persistence for Comments.
public struct CommentRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ comment: Comment) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO comment
                        (id, issue_id, author_id, body, via, created_at, updated_at, deleted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        body = excluded.body, updated_at = excluded.updated_at,
                        deleted_at = excluded.deleted_at
                    """,
                arguments: [
                    comment.id.rawValue.uuidString, comment.issueId.rawValue.uuidString,
                    comment.authorId.rawValue.uuidString, comment.body, comment.via.wireValue,
                    comment.createdAt, comment.updatedAt, comment.deletedAt,
                ])
            try ChangeCursor.record(db, entity: .comment, id: comment.id.rawValue.uuidString)
        }
    }

    /// Tombstones the Comment **and clears its text**.
    ///
    /// People delete comments because of what is in them — a mistake, an
    /// intemperate remark, a pasted credential — so a tombstone that kept serving
    /// the body would defeat the point. Propagating a null body also purges it from
    /// clients that already synced it. Not a security guarantee: backups and
    /// long-offline clients still hold the old text.
    public func delete(_ id: Comment.ID, at now: Date) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE comment SET body = NULL, deleted_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [now, now, id.rawValue.uuidString])
            try ChangeCursor.record(db, entity: .comment, id: id.rawValue.uuidString)
        }
    }

    /// Returns tombstoned Comments too, so a caller can answer 410 rather than 404.
    public func find(_ id: Comment.ID) throws -> Comment? {
        try database.reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM comment WHERE id = ?",
                    arguments: [id.rawValue.uuidString])
            else { return nil }
            return try Self.comment(from: row)
        }
    }

    /// The discussion thread, oldest first. Deleted comments vanish from the thread
    /// rather than leaving a marker — at this team size a marker is clutter.
    public func thread(for issueId: Issue.ID) throws -> [Comment] {
        try database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM comment
                    WHERE issue_id = ? AND deleted_at IS NULL
                    ORDER BY created_at, id
                    """,
                arguments: [issueId.rawValue.uuidString]
            ).map { try Self.comment(from: $0) }
        }
    }

    static func comment(from row: Row) throws -> Comment {
        guard let uuid = UUID(uuidString: row["id"]),
            let issueUUID = UUID(uuidString: row["issue_id"]),
            let authorUUID = UUID(uuidString: row["author_id"])
        else {
            throw DatabaseError(message: "Malformed comment row: \(row)")
        }
        return Comment(
            id: Comment.ID(uuid),
            issueId: Issue.ID(issueUUID),
            authorId: User.ID(authorUUID),
            body: row["body"],
            via: Via(wireValue: row["via"]),
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            deletedAt: row["deleted_at"]
        )
    }
}
