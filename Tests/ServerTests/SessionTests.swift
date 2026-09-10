import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Server

@Suite("Session tokens")
struct SessionTokenTests {

    /// 256 bits of CSPRNG. There is nothing to brute-force, which is why these are
    /// hashed with SHA-256 rather than a slow KDF — a KDF would add latency to
    /// every authenticated request and buy nothing.
    @Test("a generated token is unguessable and unique")
    func generatedTokensAreUnique() {
        let tokens = Set((0..<200).map { _ in SessionToken.generate().raw })

        #expect(tokens.count == 200)
        // Prefixed so it is greppable in a leaked config (ticket 07).
        #expect(tokens.allSatisfy { $0.hasPrefix("issues_pat_") })
        #expect(tokens.allSatisfy { $0.count > 40 })
    }

    @Test("hashing is stable and differs per token")
    func hashingIsStable() {
        let token = SessionToken.generate()

        #expect(SessionToken.hash(token.raw) == SessionToken.hash(token.raw))
        #expect(SessionToken.hash(token.raw) != SessionToken.hash(SessionToken.generate().raw))
    }
}

@Suite("Session repository")
struct SessionRepositoryTests {

    private func fixture() throws -> (AppDatabase, User, SessionRepository) {
        let database = try AppDatabase.inMemory()
        let user = User.fixture()
        try UserRepository(database: database).save(user)
        return (database, user, SessionRepository(database: database))
    }

    /// A database leak must not hand out usable tokens, so only the hash is
    /// stored — the raw value exists once, at creation, and is never persisted.
    @Test("only the hash is stored, never the token itself")
    func storesOnlyTheHash() throws {
        let (database, user, sessions) = try fixture()

        let token = try sessions.create(for: user.id, kind: .human, deviceId: "mac-1")

        let stored = try database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT token_hash FROM session")
        }
        #expect(stored.count == 1)
        #expect(stored.first != token.raw)
        #expect(stored.first == SessionToken.hash(token.raw))
    }

    @Test("a valid token resolves to its user and kind")
    func validTokenResolves() throws {
        let (_, user, sessions) = try fixture()
        let token = try sessions.create(for: user.id, kind: .agent, deviceId: nil)

        let resolved = try sessions.authenticate(token.raw)

        #expect(resolved?.userId == user.id)
        #expect(resolved?.kind == .agent)
    }

    @Test("an unknown token resolves to nothing")
    func unknownTokenResolvesToNothing() throws {
        let (_, _, sessions) = try fixture()

        #expect(try sessions.authenticate("issues_pat_nonsense") == nil)
    }

    /// Revocation has to be immediate: it is the reason ADR 0006 chose opaque
    /// server-side tokens over JWTs in the first place.
    @Test("a revoked token stops working immediately")
    func revokedTokenStopsWorking() throws {
        let (_, user, sessions) = try fixture()
        let token = try sessions.create(for: user.id, kind: .human, deviceId: nil)

        try sessions.revoke(token.raw)

        #expect(try sessions.authenticate(token.raw) == nil)
    }

    /// 60-day idle expiry (ADR 0006). Deliberately long, because an offline-first
    /// client can legitimately be offline for weeks.
    @Test("an idle-expired token stops working")
    func expiredTokenStopsWorking() throws {
        let (database, user, sessions) = try fixture()
        let token = try sessions.create(for: user.id, kind: .human, deviceId: nil)

        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE session SET expires_at = ?",
                arguments: [Date(timeIntervalSinceNow: -60)])
        }

        #expect(try sessions.authenticate(token.raw) == nil)
    }

    /// A deactivated User's sessions must stop working at once — ADR 0006 records
    /// that this strands their pending writes, which is accepted, but a
    /// deactivated account must not keep writing.
    @Test("a deactivated user's token stops working")
    func deactivatedUserTokenStopsWorking() throws {
        let (database, user, sessions) = try fixture()
        let token = try sessions.create(for: user.id, kind: .human, deviceId: nil)

        var deactivated = user
        deactivated.active = false
        try UserRepository(database: database).save(deactivated)

        #expect(try sessions.authenticate(token.raw) == nil)
    }

    /// Writing last-used on every request turns every authenticated read into a
    /// write. Ticket 07 asks for coarse tracking: update only when the stored
    /// value is over an hour old.
    @Test("last-used is tracked coarsely rather than on every request")
    func lastUsedIsCoarse() throws {
        let (database, user, sessions) = try fixture()
        let token = try sessions.create(for: user.id, kind: .human, deviceId: nil)

        func lastUsed() throws -> Date? {
            try database.reader.read { db in
                try Date.fetchOne(db, sql: "SELECT last_used_at FROM session")
            }
        }

        _ = try sessions.authenticate(token.raw)
        let first = try lastUsed()

        _ = try sessions.authenticate(token.raw)
        #expect(try lastUsed() == first, "last-used was rewritten within the hour")

        // Compared against a value that is unambiguously old: two "now" values
        // milliseconds apart can land in the same stored millisecond.
        let stale = Date(timeIntervalSinceNow: -7200)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE session SET last_used_at = ?", arguments: [stale])
        }
        _ = try sessions.authenticate(token.raw)

        let refreshed = try #require(try lastUsed())
        #expect(refreshed.timeIntervalSince(stale) > 3600, "last-used was not refreshed")
    }
}
