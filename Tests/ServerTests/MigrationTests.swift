import Foundation
import GRDB
import Server
import Testing

@Suite("Schema migrations")
struct MigrationTests {

    private func migrated() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    @Test("creates every table the server needs")
    func createsExpectedTables() throws {
        let database = try migrated()

        let tables = try database.reader.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }

        // The client's six entities, plus what only the server holds.
        for expected in [
            "comment", "issue", "issue_label", "label", "project", "user",
            "change_cursor", "session", "instance",
        ] {
            #expect(tables.contains(expected), "missing table: \(expected)")
        }
    }

    /// Per-field timestamps live on the server's issue row even though they are
    /// deliberately absent from Core's Issue type: they are sync machinery, and
    /// per-field last-write-wins is resolved here.
    @Test("the issue row carries a timestamp per mutable scalar")
    func issueCarriesPerFieldTimestamps() throws {
        let database = try migrated()

        let columns = try database.reader.read { db in
            try db.columns(in: "issue").map(\.name)
        }

        for expected in [
            "title_updated_at", "description_updated_at", "status_updated_at",
            "priority_updated_at", "assignee_id_updated_at", "due_date_updated_at",
        ] {
            #expect(columns.contains(expected), "missing column: \(expected)")
        }
    }

    /// The watermark's sequence must be globally unique, or two changes could
    /// share a position and a client would skip one.
    @Test("the change cursor keys one row per entity with a unique sequence")
    func changeCursorShape() throws {
        let database = try migrated()

        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO change_cursor (entity, entity_id, seq) VALUES ('issue', 'a', 1)")
        }

        // A second row may not reuse the sequence.
        #expect(throws: (any Error).self) {
            try database.writer.write { db in
                try db.execute(
                    sql:
                        "INSERT INTO change_cursor (entity, entity_id, seq) VALUES ('issue', 'b', 1)"
                )
            }
        }
    }

    /// An Instance is created with an epoch, because a watermark is meaningless
    /// without one and a restore mints a new epoch. See ticket 09.
    @Test("a fresh instance has an epoch")
    func freshInstanceHasAnEpoch() throws {
        let database = try migrated()

        let epoch = try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT epoch FROM instance")
        }

        #expect(epoch?.isEmpty == false)
    }

    @Test("migrating an already-migrated database is a no-op")
    func migrationIsIdempotent() throws {
        let database = try migrated()

        // Running the migrator again must not throw or duplicate anything.
        try AppDatabase.migrator.migrate(database.writer)

        let count = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM instance")
        }
        #expect(count == 1)
    }
}

@Suite("On-disk database")
struct OnDiskDatabaseTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("issues-test-\(UUID().uuidString).sqlite")
    }

    /// WAL is not a performance preference here. ADR 0010 chose SQLite partly
    /// because WAL serialises writers, which is what stops the monotonic change
    /// sequence committing out of order and letting a client skip a change
    /// permanently. If this pragma is ever lost, that guarantee goes with it.
    @Test("the on-disk database runs in WAL mode")
    func onDiskUsesWAL() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let database = try AppDatabase.open(at: url)

        let mode = try database.reader.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(mode?.lowercased() == "wal")
    }

    /// Ticket 08: the server strictly rejects any reference to an id it has not
    /// seen, rather than accepting dangling references and reaping them later.
    /// That is enforced by the database, so the pragma has to actually be on.
    @Test("foreign keys are enforced, so an unknown reference is rejected")
    func onDiskEnforcesForeignKeys() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let database = try AppDatabase.open(at: url)

        #expect(throws: (any Error).self) {
            try database.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO label (id, project_id, name, color, created_at, updated_at)
                        VALUES ('l1', 'no-such-project', 'bug', '#c0392b', ?, ?)
                        """,
                    arguments: [Date(), Date()])
            }
        }
    }
}
