import Core
import Foundation
import GRDB

/// Persistence for Projects.
///
/// Explicit SQL rather than GRDB's record protocols: the column names are
/// snake_case, the domain types are wrappers (`ProjectKey`, `ID<Project>`), and the
/// mapping is clearer written out than inferred.
public struct ProjectRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Writes the Project **and** records the change in one transaction.
    public func save(_ project: Project) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO project
                        (id, key, name, description, archived, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        name = excluded.name,
                        description = excluded.description,
                        archived = excluded.archived,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    project.id.rawValue.uuidString, project.key.wireValue, project.name,
                    project.description, project.archived, project.createdAt, project.updatedAt,
                ])

            try ChangeCursor.record(db, entity: .project, id: project.id.rawValue.uuidString)
        }
    }

    public func find(_ id: Project.ID) throws -> Project? {
        try database.reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM project WHERE id = ?",
                    arguments: [id.rawValue.uuidString])
            else { return nil }
            return try Self.project(from: row)
        }
    }

    static func project(from row: Row) throws -> Project {
        guard
            let uuid = UUID(uuidString: row["id"]),
            let key = ProjectKey(row["key"])
        else {
            throw DatabaseError(message: "Malformed project row: \(row)")
        }
        return Project(
            id: Project.ID(uuid),
            key: key,
            name: row["name"],
            description: row["description"],
            archived: row["archived"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}
