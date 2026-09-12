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

    /// Every user, ordered by display name.
    ///
    /// Unpaginated: an instance this is for has tens of users, not thousands, and
    /// a cursor here would be machinery with nothing to do. It is still returned
    /// inside a `Paginated` so the shape can gain paging later without becoming a
    /// breaking change.
    public func all() throws -> [User] {
        try database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM user ORDER BY display_name COLLATE NOCASE, id")
                .map(Self.user(from:))
        }
    }

    /// Used to keep email addresses unique, which login depends on: two accounts
    /// sharing an address would make one of them permanently unreachable.
    public func find(email: String) throws -> User? {
        try database.reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM user WHERE email = ? COLLATE NOCASE",
                    arguments: [email])
            else { return nil }
            return try Self.user(from: row)
        }
    }

    public func find(_ id: User.ID) throws -> User? {
        try database.reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM user WHERE id = ?",
                    arguments: [id.rawValue.uuidString])
            else { return nil }
            return try Self.user(from: row)
        }
    }

    /// Stores an already-hashed password. The repository never sees a plaintext
    /// one, so there is nowhere for it to be logged or accidentally persisted.
    public func setPassword(_ encodedHash: String, for id: User.ID) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE user SET password_hash = ? WHERE id = ?",
                arguments: [encodedHash, id.rawValue.uuidString])
        }
    }

    /// Looks a user up for authentication, returning their stored hash alongside.
    ///
    /// Returns `nil` for an unknown address *and* for one with no password set, so
    /// the caller cannot accidentally distinguish the two.
    func credentials(forEmail email: String) throws -> (user: User, passwordHash: String)? {
        try database.reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM user WHERE email = ?", arguments: [email]),
                let hash: String = row["password_hash"]
            else { return nil }
            return (try Self.user(from: row), hash)
        }
    }

    /// The stored hash for a user, or `nil` if they have never been given a
    /// password. Used to verify the *current* one before allowing a self-service
    /// change.
    func credentials(forId id: User.ID) throws -> String? {
        try database.reader.read { db in
            try String.fetchOne(
                db, sql: "SELECT password_hash FROM user WHERE id = ?",
                arguments: [id.rawValue.uuidString])
        }
    }

    static func user(from row: Row) throws -> User {
        guard let uuid = UUID(uuidString: row["id"]) else {
            throw DatabaseError(message: "Malformed user row: \(row)")
        }
        return User(
            id: User.ID(uuid),
            email: row["email"],
            displayName: row["display_name"],
            role: Role(wireValue: row["role"]),
            active: row["active"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}
