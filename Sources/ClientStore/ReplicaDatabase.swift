import Core
import Foundation
import GRDB

/// The client's local database: the replica and the offline queue, one file.
///
/// One file is what makes ADR 0004's no-silent-drops guarantee real. "Apply the
/// local mutation *and* enqueue the operation, or neither" is a single GRDB
/// `write { }`; split across two stores no transaction spans them, and a crash
/// between the writes diverges the device with nothing able to detect it.
public struct ReplicaDatabase: Sendable {
    let writer: any DatabaseWriter

    /// `DatabasePool` in WAL mode on disk (ticket 05): the UI reads constantly while
    /// the sync engine writes, and a serial queue would make every background write
    /// block the interface.
    public static func open(at url: URL) throws -> ReplicaDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try migrator.migrate(pool)
        return ReplicaDatabase(writer: pool)
    }

    /// For tests. A queue rather than a pool, so a test never races itself.
    public static func inMemory() throws -> ReplicaDatabase {
        var configuration = Configuration()
        // Off here too, deliberately: see the migrator's note. A test database that
        // enforced them would accept states the real one rejects, and vice versa.
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(queue)
        return ReplicaDatabase(writer: queue)
    }

    public var reader: any DatabaseReader { writer }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-replica") { db in
            // **Foreign keys are deliberately off on the client.** Pull order is
            // change order, so a comment can arrive hundreds of pages before its
            // issue; the map records that enforcing them here breaks first sync.
            // Orphans are stored and simply not displayed.
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("key", .text).notNull()
                t.column("name", .text).notNull()
                t.column("description", .text).notNull()
                t.column("archived", .boolean).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "user") { t in
                t.primaryKey("id", .text)
                t.column("email", .text).notNull()
                t.column("display_name", .text).notNull()
                t.column("role", .text).notNull()
                t.column("active", .boolean).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            // Only the **server-authoritative base record** is stored. The displayed
            // value is this with pending operations applied on read (ticket 05): the
            // queue already records what is locally dirty, so a second copy would be
            // redundant state able to disagree with the log.
            try db.create(table: "issue") { t in
                t.primaryKey("id", .text)
                t.column("key", .text)
                t.column("project_id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("description", .text).notNull()
                t.column("status", .text).notNull()
                t.column("priority", .text).notNull()
                t.column("reporter_id", .text).notNull()
                t.column("assignee_id", .text)
                t.column("due_date", .text)
                t.column("via", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                // Tombstones are retained indefinitely (ADR 0003): a client that
                // forgot one would resurrect the record on its next pull.
                t.column("deleted_at", .datetime)
            }
            try db.create(index: "issue_on_project", on: "issue", columns: ["project_id"])
            try db.create(index: "issue_on_key", on: "issue", columns: ["key"])

            try db.create(table: "label") { t in
                t.primaryKey("id", .text)
                t.column("project_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }

            try db.create(table: "issue_label") { t in
                t.primaryKey("id", .text)
                t.column("issue_id", .text).notNull()
                t.column("label_id", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }
            try db.create(
                index: "issue_label_on_issue", on: "issue_label", columns: ["issue_id"])
            // Convergence is on the natural key, matching the server: two clients
            // adding the same label offline produce one membership, not two. The row
            // id itself is incidental.
            try db.create(
                index: "issue_label_unique", on: "issue_label",
                columns: ["issue_id", "label_id"], unique: true)

            try db.create(table: "comment") { t in
                t.primaryKey("id", .text)
                t.column("issue_id", .text).notNull()
                t.column("author_id", .text).notNull()
                // Null once deleted: the body is cleared rather than the row removed.
                t.column("body", .text)
                t.column("via", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }
            try db.create(index: "comment_on_issue", on: "comment", columns: ["issue_id"])

            try db.create(table: "pending_operation") { t in
                // The primary key is the sequence, not the opId: two operations made
                // in the same millisecond must still have a defined order, and
                // `created_at` cannot give one. The opId is unique but not the key.
                t.autoIncrementedPrimaryKey("sequence")
                // The same opId sent on the wire (ticket 06), so the server's retry
                // dedupe recognises a replay.
                t.column("op_id", .text).notNull().unique()
                t.column("entity_type", .text).notNull()
                t.column("entity_id", .text).notNull()
                t.column("kind", .text).notNull()
                // Merge-Patch shaped, so replay is a translation rather than a
                // re-derivation.
                t.column("payload", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("state", .text).notNull()
                // The RFC 9457 body, kept so the user can repair and retry.
                t.column("problem", .text)
                t.column("attempt_count", .integer).notNull().defaults(to: 0)
            }

            // ADR 0004's no-head-of-line-blocking guarantee, expressed as an index
            // rather than a code convention: the next-batch query never scans
            // quarantined rows.
            try db.execute(
                sql: """
                    CREATE INDEX pending_operation_ready
                    ON pending_operation (sequence) WHERE state = 'pending'
                    """)

            // One row, holding the pull watermark. `epoch:seq`, so a server restore
            // forces a full resync rather than silently cutting this client off.
            try db.create(table: "sync_state") { t in
                t.primaryKey("id", .integer)
                t.column("watermark", .text)
            }
            try db.execute(sql: "INSERT INTO sync_state (id, watermark) VALUES (1, NULL)")
        }

        migrator.registerMigration("v2-superseded-writes") { db in
            // Work that can never be sent, kept so the user can get their text back.
            //
            // ADR 0005's third outcome only helps if it survives the moment it
            // happens: a summary returned from a sync that nothing was watching is
            // the same as losing the text.
            try db.create(table: "superseded_write") { t in
                t.primaryKey("op_id", .text)
                t.column("entity_type", .text).notNull()
                t.column("entity_id", .text).notNull()
                // The operation itself, so the user's own words are recoverable.
                t.column("payload", .text).notNull()
                // What won, when the server told us. Absent when a tombstone arrived
                // through pull and the record is simply gone.
                t.column("current", .text)
                t.column("reason", .text).notNull()
                t.column("occurred_at", .datetime).notNull()
            }
        }

        return migrator
    }
}
