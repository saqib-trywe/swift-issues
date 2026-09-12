import Core
import Foundation
import GRDB

extension ReplicaDatabase {

    /// An issue's comment thread, oldest first.
    ///
    /// Deleted comments are kept: the body is cleared but the entry stays, because
    /// a removed comment still occupies its place in a conversation and a thread
    /// that silently closes its gaps reads as if it were never there.
    public func comments(forIssue id: Issue.ID) throws -> [Comment] {
        try reader.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM comment WHERE issue_id = ? ORDER BY created_at, id",
                arguments: [id.rawValue.uuidString]
            ).compactMap(Self.comment(from:))
        }
    }

    /// The labels currently on an issue.
    public func labels(forIssue id: Issue.ID) throws -> [Label] {
        try reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT l.* FROM issue_label il JOIN label l ON l.id = il.label_id
                    WHERE il.issue_id = ? AND il.deleted_at IS NULL AND l.deleted_at IS NULL
                    ORDER BY l.name COLLATE NOCASE
                    """,
                arguments: [id.rawValue.uuidString]
            ).compactMap(Self.label(from:))
        }
    }

    static func comment(from row: Row) -> Comment? {
        guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
            let issueId = (row["issue_id"] as String?).flatMap(UUID.init(uuidString:)),
            let authorId = (row["author_id"] as String?).flatMap(UUID.init(uuidString:))
        else { return nil }

        return Comment(
            id: Comment.ID(id),
            issueId: Issue.ID(issueId),
            authorId: User.ID(authorId),
            body: row["body"],
            via: Via(wireValue: row["via"]),
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            deletedAt: row["deleted_at"])
    }

    static func label(from row: Row) -> Label? {
        guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
            let projectId = (row["project_id"] as String?).flatMap(UUID.init(uuidString:))
        else { return nil }

        return Label(
            id: Label.ID(id),
            projectId: Project.ID(projectId),
            name: row["name"],
            color: row["color"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            deletedAt: row["deleted_at"])
    }
}
