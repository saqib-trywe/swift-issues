import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Server

/// Tokens need a public identifier so they can be listed and revoked.
@Suite("Session identity")
struct SessionIdentityTests {

    private func world() throws -> (database: AppDatabase, user: DomainUser) {
        let database = try AppDatabase.inMemory()
        let user = DomainUser.fixture()
        try UserRepository(database: database).save(user)
        return (database, user)
    }

    @Test("a created session has an id that is not its hash")
    func createdSessionHasAnIdThatIsNotItsHash() throws {
        let (database, user) = try world()
        let sessions = SessionRepository(database: database)

        let token = try sessions.create(for: user.id, kind: .human, deviceId: nil, label: "laptop")
        let listed = try sessions.list(for: user.id)

        let only = try #require(listed.first)
        #expect(listed.count == 1)
        #expect(only.label == "laptop")
        #expect(only.id.rawValue.uuidString != SessionToken.hash(token.raw))
    }

    /// Ids must be unique, or revoking one would revoke another.
    @Test("every session gets a distinct id")
    func everySessionGetsADistinctId() throws {
        let (database, user) = try world()
        let sessions = SessionRepository(database: database)

        for index in 0..<5 {
            _ = try sessions.create(
                for: user.id, kind: .human, deviceId: nil, label: "device \(index)")
        }

        let ids = try sessions.list(for: user.id).map(\.id)
        #expect(Set(ids).count == 5)
    }

    /// Ordered by creation time. The times are set explicitly rather than relying
    /// on two `create` calls landing in different milliseconds — they routinely do
    /// not, and a test that depends on that is flaky by construction.
    @Test("sessions list newest first")
    func sessionsListNewestFirst() throws {
        let (database, user) = try world()
        let sessions = SessionRepository(database: database)

        for label in ["oldest", "middle", "newest"] {
            _ = try sessions.create(for: user.id, kind: .human, deviceId: nil, label: label)
        }
        try database.writer.write { db in
            for (offset, label) in ["oldest", "middle", "newest"].enumerated() {
                try db.execute(
                    sql: "UPDATE session SET created_at = ? WHERE label = ?",
                    arguments: [Date().addingTimeInterval(TimeInterval(offset) * 60), label])
            }
        }

        let labels = try sessions.list(for: user.id).map(\.label)
        #expect(labels == ["newest", "middle", "oldest"])
    }

    /// UUIDv7's tail is random within a millisecond, so without a tie-break two
    /// tokens minted together would come back in arbitrary order — and a listing
    /// that reshuffles between calls is one nobody can act on.
    @Test("tokens minted in the same millisecond have a stable order")
    func sameMillisecondOrderIsStable() throws {
        let (database, user) = try world()
        let sessions = SessionRepository(database: database)
        for index in 0..<8 {
            _ = try sessions.create(
                for: user.id, kind: .human, deviceId: nil, label: "token \(index)")
        }

        let first = try sessions.list(for: user.id).map(\.id)
        let second = try sessions.list(for: user.id).map(\.id)
        #expect(first == second)
        #expect(first.count == 8)
    }

    @Test("a session lists its kind, so an Admin can spot an agent")
    func sessionListsItsKind() throws {
        let (database, user) = try world()
        let sessions = SessionRepository(database: database)

        _ = try sessions.create(for: user.id, kind: .agent, deviceId: nil, label: "mcp")
        let only = try #require(try sessions.list(for: user.id).first)
        #expect(only.kind == .agent)
    }

    /// The raw token must never come back from a listing: it exists once, at
    /// creation, and only a hash is stored.
    @Test("a listing carries no token material")
    func listingCarriesNoTokenMaterial() throws {
        let (database, user) = try world()
        let sessions = SessionRepository(database: database)
        let token = try sessions.create(for: user.id, kind: .human, deviceId: nil, label: "laptop")

        let encoded = try JSONCoders.encoder.encode(try sessions.list(for: user.id))
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.contains(token.raw))
        #expect(!text.contains(SessionToken.hash(token.raw)))
    }

    @Test("revoking by id stops that token working")
    func revokingByIdStopsThatToken() throws {
        let (database, user) = try world()
        let sessions = SessionRepository(database: database)
        let token = try sessions.create(for: user.id, kind: .human, deviceId: nil, label: "laptop")

        let id = try #require(try sessions.list(for: user.id).first?.id)
        #expect(try sessions.revoke(id: id) == true)
        #expect(try sessions.authenticate(token.raw) == nil)
    }

    /// Revoking one token must not touch the others, or logging a device out would
    /// log everything out.
    @Test("revoking one token leaves the others working")
    func revokingOneLeavesOthersWorking() throws {
        let (database, user) = try world()
        let sessions = SessionRepository(database: database)
        let doomed = try sessions.create(for: user.id, kind: .human, deviceId: nil, label: "old")
        let kept = try sessions.create(for: user.id, kind: .human, deviceId: nil, label: "new")

        let id = try #require(
            try sessions.list(for: user.id).first(where: { $0.label == "old" })?.id)
        _ = try sessions.revoke(id: id)

        #expect(try sessions.authenticate(doomed.raw) == nil)
        #expect(try sessions.authenticate(kept.raw) != nil)
    }

    @Test("revoking an unknown id reports that nothing happened")
    func revokingAnUnknownIdReportsNothingHappened() throws {
        let (database, _) = try world()
        #expect(try SessionRepository(database: database).revoke(id: ID(UUID())) == false)
    }

    /// A revoked token stays listed with the fact recorded, so an Admin reviewing
    /// what happened can still see it.
    @Test("a revoked session is still listed, marked revoked")
    func revokedSessionIsStillListed() throws {
        let (database, user) = try world()
        let sessions = SessionRepository(database: database)
        _ = try sessions.create(for: user.id, kind: .human, deviceId: nil, label: "laptop")

        let id = try #require(try sessions.list(for: user.id).first?.id)
        _ = try sessions.revoke(id: id)

        let only = try #require(try sessions.list(for: user.id).first)
        #expect(only.revokedAt != nil)
    }

    /// Existing tokens must be listable straight after an upgrade — otherwise the
    /// one an admin most wants to revoke is the one they cannot name.
    @Test("the migration backfills ids for sessions created before it")
    func migrationBackfillsIds() throws {
        let database = try AppDatabase.inMemory()
        let user = DomainUser.fixture()
        try UserRepository(database: database).save(user)

        // Simulates a pre-v5 row by clearing the id the repository set.
        let sessions = SessionRepository(database: database)
        let token = try sessions.create(for: user.id, kind: .human, deviceId: nil, label: "old")
        try database.writer.write { db in
            try db.execute(sql: "UPDATE session SET id = NULL")
        }

        try AppDatabase.backfillSessionIDs(database)

        let only = try #require(try sessions.list(for: user.id).first)
        #expect(only.label == "old")
        #expect(try sessions.authenticate(token.raw) != nil)
    }
}
