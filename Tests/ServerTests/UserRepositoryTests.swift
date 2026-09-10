import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Server

@Suite("User repository")
struct UserRepositoryTests {

    private func fixture() throws -> (AppDatabase, UserRepository) {
        let database = try AppDatabase.inMemory()
        return (database, UserRepository(database: database))
    }

    @Test("a saved user reads back with its fields intact")
    func savedUserReadsBack() throws {
        let (_, users) = try fixture()
        let user = User.fixture(email: "jo@example.com", displayName: "Jo", role: .admin)

        try users.save(user)
        let loaded = try users.find(user.id)

        #expect(loaded?.email == "jo@example.com")
        #expect(loaded?.displayName == "Jo")
        #expect(loaded?.role == .admin)
        #expect(loaded?.active == true)
    }

    @Test("an unknown id reads back as nothing")
    func unknownIDReadsBackNil() throws {
        let (_, users) = try fixture()

        #expect(try users.find(User.ID()) == nil)
    }

    /// Deactivation is an update, not a delete: a User is referenced as reporter,
    /// assignee and comment author permanently.
    @Test("deactivating updates in place rather than removing the row")
    func deactivationUpdatesInPlace() throws {
        let (database, users) = try fixture()
        var user = User.fixture()
        try users.save(user)

        user.active = false
        try users.save(user)

        #expect(try users.find(user.id)?.active == false)
        let rows = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user") ?? 0
        }
        #expect(rows == 1, "deactivation should not add or remove rows")
    }

    /// Users replicate to clients so an assignee can be rendered by name, so a
    /// change to one has to reach the change stream like any other entity.
    @Test("saving a user advances the change cursor")
    func savingAdvancesTheCursor() throws {
        let (database, users) = try fixture()

        try users.save(User.fixture())

        let recorded = try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT entity FROM change_cursor")
        }
        #expect(recorded == "user")
    }

    /// An unrecognised role must not be coerced. A server that gains a role this
    /// build has never heard of should not have it silently read as `member`.
    @Test("an unknown role survives a round trip through the database")
    func unknownRoleSurvives() throws {
        let (database, users) = try fixture()
        let user = User.fixture()
        try users.save(user)

        try database.writer.write { db in
            try db.execute(sql: "UPDATE user SET role = 'auditor'")
        }

        #expect(try users.find(user.id)?.role == .unknown("auditor"))
    }
}
