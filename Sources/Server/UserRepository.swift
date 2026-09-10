import Core
import Foundation
import GRDB

/// Persistence for Users.
///
/// Users are deactivated, never deleted, so there is no delete here at all.
public struct UserRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ user: User) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO user
                        (id, email, display_name, role, active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        email = excluded.email,
                        display_name = excluded.display_name,
                        role = excluded.role,
                        active = excluded.active,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    user.id.rawValue.uuidString, user.email, user.displayName,
                    user.role.wireValue, user.active, user.createdAt, user.updatedAt,
                ])

            try ChangeCursor.record(db, entity: .user, id: user.id.rawValue.uuidString)
        }
    }

    public func find(_ id: User.ID) throws -> User? {
        try database.reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM user WHERE id = ?",
                    arguments: [id.rawValue.uuidString])
            else { return nil }
            // No malformed-id guard here, unlike ProjectRepository: this looks a
            // row up *by* id, so any row it retrieves has an id equal to the valid
            // UUID string we queried with. A guard could never fire.
            return User(
                id: id,
                email: row["email"],
                displayName: row["display_name"],
                role: Role(wireValue: row["role"]),
                active: row["active"],
                createdAt: row["created_at"],
                updatedAt: row["updated_at"]
            )
        }
    }
}
