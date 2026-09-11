import Core
import Foundation
import GRDB

/// Persistence for Labels and their membership links.
///
/// Membership is a record rather than a set-valued field, so two users adding
/// different labels concurrently both survive (ADR 0003). Removing a label
/// tombstones the link.
public struct LabelRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func save(_ label: Label) throws -> Label {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO label (id, project_id, name, color, created_at, updated_at, deleted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        name = excluded.name, color = excluded.color,
                        updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
                    """,
                arguments: [
                    label.id.rawValue.uuidString, label.projectId.rawValue.uuidString,
                    label.name, label.color, label.createdAt, label.updatedAt, label.deletedAt,
                ])
            try ChangeCursor.record(db, entity: .label, id: label.id.rawValue.uuidString)
            return label
        }
    }

    /// Applies a Label to an Issue. Idempotent: re-attaching an existing link
    /// revives it rather than failing, which is what a replayed offline operation
    /// needs.
    public func attach(labelId: Label.ID, to issueId: Issue.ID, at now: Date) throws {
        let linkId = ID<IssueLabel>()
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO issue_label (id, issue_id, label_id, created_at, updated_at, deleted_at)
                    VALUES (?, ?, ?, ?, ?, NULL)
                    ON CONFLICT (issue_id, label_id) DO UPDATE SET
                        deleted_at = NULL, updated_at = excluded.updated_at
                    """,
                arguments: [
                    linkId.rawValue.uuidString, issueId.rawValue.uuidString,
                    labelId.rawValue.uuidString, now, now,
                ])
            try ChangeCursor.record(db, entity: .issueLabel, id: linkId.rawValue.uuidString)
        }
    }

    /// Removes a Label from an Issue by tombstoning the link, never deleting it.
    public func detach(labelId: Label.ID, from issueId: Issue.ID, at now: Date) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE issue_label SET deleted_at = ?, updated_at = ?
                    WHERE issue_id = ? AND label_id = ?
                    """,
                arguments: [
                    now, now, issueId.rawValue.uuidString, labelId.rawValue.uuidString,
                ])
        }
    }

    public func find(_ id: Label.ID) throws -> Label? {
        try database.reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM label WHERE id = ?",
                    arguments: [id.rawValue.uuidString])
            else { return nil }
            return try Self.label(from: row)
        }
    }

    /// Live labels in a Project, oldest first. Tombstoned ones are excluded.
    public func all(in projectId: Project.ID) throws -> [Label] {
        try database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM label
                    WHERE project_id = ? AND deleted_at IS NULL
                    ORDER BY created_at, id
                    """,
                arguments: [projectId.rawValue.uuidString]
            ).map { try Self.label(from: $0) }
        }
    }

    static func label(from row: Row) throws -> Label {
        guard let uuid = UUID(uuidString: row["id"]),
            let projectUUID = UUID(uuidString: row["project_id"])
        else {
            throw DatabaseError(message: "Malformed label row: \(row)")
        }
        return Label(
            id: Label.ID(uuid),
            projectId: Project.ID(projectUUID),
            name: row["name"],
            color: row["color"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            deletedAt: row["deleted_at"]
        )
    }

    /// Tombstones the Label. Removing a label never deletes the row.
    public func delete(_ id: Label.ID, at now: Date) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE label SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id.rawValue.uuidString])
            try ChangeCursor.record(db, entity: .label, id: id.rawValue.uuidString)
        }
    }

    /// Live label ids on an Issue, tombstoned links excluded.
    public func labelIds(for issueId: Issue.ID) throws -> [Label.ID] {
        try database.reader.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT label_id FROM issue_label
                    WHERE issue_id = ? AND deleted_at IS NULL
                    """,
                arguments: [issueId.rawValue.uuidString]
            ).compactMap { UUID(uuidString: $0).map(Label.ID.init) }
        }
    }
}
