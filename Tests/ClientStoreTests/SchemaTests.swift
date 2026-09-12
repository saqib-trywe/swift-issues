import Core
import Foundation
import GRDB
import Testing

@testable import ClientStore

@Suite("Replica schema")
struct SchemaTests {

    @Test("the migration runs")
    func migrationRuns() throws {
        _ = try ReplicaDatabase.inMemory()
    }

    @Test("every table the client needs exists")
    func everyTableExists() throws {
        let database = try ReplicaDatabase.inMemory()
        let names = try database.reader.read { db in
            try String.fetchSet(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }

        for table in [
            "project", "user", "issue", "label", "issue_label", "comment",
            "pending_operation", "sync_state",
        ] {
            #expect(names.contains(table), "'\(table)' is missing")
        }
    }

    /// ADR 0004's no-head-of-line-blocking guarantee is expressed as a partial
    /// index, so the next-batch query never scans quarantined rows. A plain index
    /// here would make it a code convention instead.
    @Test("the pending-operation index is partial")
    func pendingOperationIndexIsPartial() throws {
        let database = try ReplicaDatabase.inMemory()
        let sql = try database.reader.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT sql FROM sqlite_master
                    WHERE type = 'index' AND name = 'pending_operation_ready'
                    """)
        }

        let definition = try #require(sql)
        #expect(definition.contains("WHERE"))
        #expect(definition.contains("pending"))
    }

    /// Pull order is change order, so a comment can arrive hundreds of pages before
    /// its issue. Enforcing foreign keys here breaks first sync; orphans are stored
    /// and simply not displayed.
    @Test("foreign keys are off, so an orphan can be stored")
    func foreignKeysAreOff() throws {
        let database = try ReplicaDatabase.inMemory()

        try database.writer.write { db in
            // A comment whose issue has not arrived yet.
            try db.execute(
                sql: """
                    INSERT INTO comment
                        (id, issue_id, author_id, body, via, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, UUID().uuidString, UUID().uuidString,
                    "Arrived early", "human", Date(), Date(),
                ])
        }

        let stored = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comment")
        }
        #expect(stored == 1)
    }

    /// In-memory and on-disk must agree, or tests accept states production rejects.
    /// This is a mistake already made once on the server.
    @Test("the on-disk database has the same schema and enables WAL")
    func onDiskMatchesInMemory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "replica-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try ReplicaDatabase.open(at: directory.appending(path: "issues.sqlite"))

        let journal = try database.reader.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(journal?.lowercased() == "wal")

        let onDisk = try database.reader.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        let inMemory = try ReplicaDatabase.inMemory().reader.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(onDisk == inMemory)
    }

    @Test("the watermark starts empty, which is what forces a first full sync")
    func watermarkStartsEmpty() throws {
        let database = try ReplicaDatabase.inMemory()
        let watermark = try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT watermark FROM sync_state WHERE id = 1")
        }
        #expect(watermark == nil)
    }

    /// Two operations made in the same millisecond must still have a defined order,
    /// which `created_at` alone cannot give. This is the UUIDv7 trap that has
    /// already cost time twice.
    @Test("pending operations have a monotonic sequence independent of the clock")
    func pendingOperationsHaveAMonotonicSequence() throws {
        let database = try ReplicaDatabase.inMemory()
        let now = Date()

        try database.writer.write { db in
            for index in 0..<5 {
                try db.execute(
                    sql: """
                        INSERT INTO pending_operation
                            (op_id, entity_type, entity_id, kind, payload, created_at, state)
                        VALUES (?, ?, ?, ?, ?, ?, 'pending')
                        """,
                    arguments: [
                        UUID().uuidString, "issue", UUID().uuidString, "patch",
                        "{}", now,  // deliberately identical timestamps
                    ])
                _ = index
            }
        }

        let sequences = try database.reader.read { db in
            try Int.fetchAll(db, sql: "SELECT sequence FROM pending_operation ORDER BY sequence")
        }
        #expect(sequences.count == 5)
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == 5)
    }
}
