import Core
import Foundation
import GRDB

/// The server's database.
///
/// SQLite embedded in the process (ADR 0010). One consequence matters for
/// correctness rather than convenience: SQLite in WAL mode serialises writers, so
/// the monotonic change-cursor sequence cannot commit out of order. Under
/// concurrent writers a client could otherwise observe sequence 5 before 4 is
/// visible and skip change 4 permanently — silent, unrecoverable, and very hard to
/// reproduce.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }

    /// Migrations run on construction: a database that exists but is unmigrated is
    /// not a state worth being able to represent.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// For tests and for `--dry-run` style checks. In-memory so the whole
    /// persistence layer is testable at unit speed (ticket 13's 60-second budget).
    ///
    /// Foreign keys are enforced here too. Without that, tests could create states
    /// production rejects — a dangling reference, say — and would quietly stop
    /// testing the constraint that ticket 08 relies on.
    public static func inMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try AppDatabase(DatabaseQueue(configuration: configuration))
    }

    /// Opens the on-disk database in WAL mode.
    public static func open(at url: URL) throws -> AppDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-schema") { db in
            // Ids are TEXT rather than BLOB: a UUID you can read in a query result
            // is worth more than the bytes it saves at this scale.

            try db.create(table: "instance") { t in
                // Exactly one row. The epoch changes on restore, which is what
                // stops a client silently resuming against a rewound sequence.
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("epoch", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "Issues")
                t.column("created_at", .datetime).notNull()
            }

            try db.create(table: "user") { t in
                t.primaryKey("id", .text)
                t.column("email", .text).notNull().unique()
                t.column("display_name", .text).notNull()
                t.column("role", .text).notNull()
                // Users are deactivated, never deleted: they are referenced as
                // reporter, assignee and comment author permanently.
                t.column("active", .boolean).notNull().defaults(to: true)
                t.column("password_hash", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("key", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                // Archived, never deleted.
                t.column("archived", .boolean).notNull().defaults(to: false)
                // Monotonic and never reused, so a deleted Issue burns its number
                // rather than repointing old references.
                t.column("next_issue_number", .integer).notNull().defaults(to: 1)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "issue") { t in
                t.primaryKey("id", .text)
                // Null until first sync assigns one.
                t.column("key_number", .integer)
                t.column("project_id", .text).notNull().references("project")
                t.column("title", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull()
                t.column("priority", .text).notNull()
                t.column("reporter_id", .text).notNull().references("user")
                t.column("assignee_id", .text).references("user")
                // A calendar day, stored as YYYY-MM-DD so no timezone can touch it.
                t.column("due_date", .text)
                t.column("via", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("deleted_at", .datetime)

                // Per-field last-write-wins is resolved here, so each mutable
                // scalar carries its own receipt timestamp. Columns rather than a
                // JSON sidecar: the comparison is a plain SQL predicate per field,
                // where a map would need json_extract on every write.
                for field in [
                    "title", "description", "status", "priority", "assignee_id", "due_date",
                ] {
                    t.column("\(field)_updated_at", .datetime).notNull()
                }

                t.uniqueKey(["project_id", "key_number"])
            }

            try db.create(table: "label") { t in
                t.primaryKey("id", .text)
                t.column("project_id", .text).notNull().references("project")
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }

            try db.create(table: "issue_label") { t in
                t.primaryKey("id", .text)
                t.column("issue_id", .text).notNull().references("issue")
                t.column("label_id", .text).notNull().references("label")
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
                t.uniqueKey(["issue_id", "label_id"])
            }

            try db.create(table: "comment") { t in
                t.primaryKey("id", .text)
                t.column("issue_id", .text).notNull().references("issue")
                t.column("author_id", .text).notNull().references("user")
                // Null once deleted: deleting a comment clears its text.
                t.column("body", .text)
                t.column("via", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }

            try db.create(table: "session") { t in
                // Only a hash is stored, so a database leak does not hand out
                // usable tokens (ADR 0006).
                t.primaryKey("token_hash", .text)
                t.column("user_id", .text).notNull().references("user")
                t.column("device_id", .text)
                // human, agent or agent-readonly — an agent's authority is fixed
                // and narrower than its owner's (ADR 0007).
                t.column("kind", .text).notNull()
                t.column("label", .text)
                t.column("created_at", .datetime).notNull()
                t.column("last_used_at", .datetime)
                t.column("expires_at", .datetime)
                t.column("revoked_at", .datetime)
            }

            try db.create(table: "change_cursor") { t in
                t.column("entity", .text).notNull()
                t.column("entity_id", .text).notNull()
                // Globally unique: two changes sharing a position would let a
                // client skip one. Upserted, so a row moves forward rather than
                // accumulating history.
                t.column("seq", .integer).notNull().unique()
                t.primaryKey(["entity", "entity_id"])
            }
            try db.create(
                index: "change_cursor_on_seq", on: "change_cursor", columns: ["seq"])
        }

        migrator.registerMigration("v1-seed-instance") { db in
            try db.execute(
                sql: "INSERT INTO instance (id, epoch, created_at) VALUES (1, ?, ?)",
                arguments: [UUIDv7.generate().uuidString, Date()])
        }

        migrator.registerMigration("v2-applied-operations") { db in
            // Retained indefinitely, matching tombstones (ADR 0003). A bounded
            // window looks tidier but fails exactly where it matters: a client's
            // queue survives session expiry, so it can legitimately return after
            // any offline period and replay operations older than any window,
            // producing silent duplicates. Cost is a UUID and a row per operation
            // ever performed.
            try db.create(table: "applied_operation") { t in
                t.primaryKey("op_id", .text)
                t.column("outcome", .text).notNull()
                t.column("applied_at", .datetime).notNull()
            }
        }

        return migrator
    }
}
