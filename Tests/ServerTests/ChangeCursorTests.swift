import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Server

@Suite("Change cursor")
struct ChangeCursorTests {

    private func database() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    private func maxSequence(_ database: AppDatabase) throws -> Int {
        try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM change_cursor") ?? 0
        }
    }

    private func cursorRows(_ database: AppDatabase) throws -> Int {
        try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_cursor") ?? 0
        }
    }

    @Test("saving an entity advances the cursor")
    func savingAdvancesTheCursor() throws {
        let database = try database()
        let repository = ProjectRepository(database: database)

        #expect(try maxSequence(database) == 0)
        try repository.save(Project.fixture())

        #expect(try maxSequence(database) == 1)
        #expect(try cursorRows(database) == 1)
    }

    @Test("each change takes the next sequence")
    func sequencesAreMonotonic() throws {
        let database = try database()
        let repository = ProjectRepository(database: database)

        try repository.save(Project.fixture(key: ProjectKey("ONE")!))
        try repository.save(Project.fixture(key: ProjectKey("TWO")!))

        #expect(try maxSequence(database) == 2)
        #expect(try cursorRows(database) == 2)
    }

    /// The cursor keeps one row per entity, moved forward — not a history. A
    /// second edit must not leave the first position behind for a client to see
    /// twice under a different sequence.
    @Test("re-saving the same entity moves its row forward rather than adding one")
    func resavingMovesTheRowForward() throws {
        let database = try database()
        let repository = ProjectRepository(database: database)
        var project = Project.fixture()

        try repository.save(project)
        project.name = "Renamed"
        try repository.save(project)

        #expect(try cursorRows(database) == 1)
        #expect(try maxSequence(database) == 2)
    }

    /// The invariant ADR 0008 calls the most expensive thing to get wrong: apply
    /// the change *and* record it, or do neither. Losing it does not crash — it
    /// produces a server whose change stream silently disagrees with its own data,
    /// found days later by a client that is quietly missing records.
    @Test("a failed write leaves the cursor untouched")
    func failedWriteLeavesCursorUntouched() throws {
        let database = try database()
        let repository = ProjectRepository(database: database)
        let key = ProjectKey("PROJ")!

        try repository.save(Project.fixture(key: key))
        #expect(try maxSequence(database) == 1)

        // A different project claiming a key that is already taken: the unique
        // constraint fires *after* the cursor would have been bumped.
        #expect(throws: (any Error).self) {
            try repository.save(Project.fixture(id: Project.ID(), key: key))
        }

        #expect(try maxSequence(database) == 1, "the cursor advanced despite a failed write")
        #expect(try cursorRows(database) == 1)
    }

    /// The test above passes even without a transaction, because `save` inserts
    /// the row before recording the change, so a duplicate key fails first. This
    /// one drives the invariant directly: record the change, *then* fail, and
    /// assert the sequence rolled back with everything else.
    @Test("a cursor bump rolls back when the surrounding transaction fails")
    func cursorBumpRollsBackWithTheTransaction() throws {
        let database = try database()
        struct Deliberate: Error {}

        #expect(throws: Deliberate.self) {
            try database.writer.write { db in
                try ChangeCursor.record(db, entity: .project, id: "some-id")
                // Everything above this line must be undone.
                throw Deliberate()
            }
        }

        #expect(try maxSequence(database) == 0)
        #expect(try cursorRows(database) == 0)
    }

    /// Guards the ordering assumption the other tests rest on: if `save` is ever
    /// reordered to record the change first, the duplicate-key test would start
    /// depending on the transaction — which is fine — but a silent reordering
    /// that also dropped the transaction would go unnoticed without this.
    @Test("a change recorded alongside a successful write is visible together")
    func changeAndWriteCommitTogether() throws {
        let database = try database()
        let project = Project.fixture()

        try ProjectRepository(database: database).save(project)

        let (rowExists, cursorExists) = try database.reader.read { db in
            (
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM project WHERE id = ?",
                    arguments: [project.id.rawValue.uuidString]) ?? 0,
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM change_cursor WHERE entity_id = ?",
                    arguments: [project.id.rawValue.uuidString]) ?? 0
            )
        }

        #expect(rowExists == 1)
        #expect(cursorExists == 1)
    }

    @Test("a saved project reads back with its fields intact")
    func savedProjectReadsBack() throws {
        let database = try database()
        let repository = ProjectRepository(database: database)
        let project = Project.fixture(name: "Platform", description: "Server work")

        try repository.save(project)
        let loaded = try repository.find(project.id)

        #expect(loaded?.name == "Platform")
        #expect(loaded?.description == "Server work")
        #expect(loaded?.key == project.key)
    }

    @Test("an unknown id reads back as nothing")
    func unknownIDReadsBackNil() throws {
        let database = try database()

        #expect(try ProjectRepository(database: database).find(Project.ID()) == nil)
    }

    /// The schema cannot express "this text is a valid ProjectKey", so a row can
    /// be malformed — after a hand-edit, a bad import, or a future migration bug.
    /// Failing loudly beats handing a caller a domain object the domain says is
    /// impossible.
    @Test("a malformed row is rejected rather than silently repaired")
    func malformedRowIsRejected() throws {
        let database = try database()
        let id = UUID()

        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO project (id, key, name, description, archived,
                                         created_at, updated_at)
                    VALUES (?, 'not a key', 'Broken', '', 0, ?, ?)
                    """,
                arguments: [id.uuidString, Date(), Date()])
        }

        #expect(throws: (any Error).self) {
            try ProjectRepository(database: database).find(Project.ID(id))
        }
    }
}
