import Core
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

@Suite("First-run bootstrap")
struct BootstrapTests {

    private static let password = "correct horse battery staple"

    private func payload(_ token: String, email: String = "admin@example.com") throws -> ByteBuffer {
        let object: [String: Any] = [
            "token": token, "email": email, "displayName": "Admin",
            "password": Self.password,
        ]
        let data: Data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ByteBuffer(data: data)
    }

    private func withServer(
        _ body:
            @Sendable @escaping (any TestClientProtocol, AppDatabase, String) async throws ->
            Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        // A fresh instance mints a one-time token, the Jenkins initialAdminPassword
        // pattern. Rejected alternative: "first user to register becomes Admin",
        // which on an exposed server is a race an attacker wins.
        let token = try BootstrapService(database: database).beginIfNeeded()
        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            try await body(client, database, try #require(token))
        }
    }

    private func post(
        _ client: any TestClientProtocol, _ body: ByteBuffer
    ) async throws -> HTTPResponse.Status {
        try await client.execute(
            uri: "/api/v1/auth/bootstrap", method: .post,
            headers: [.contentType: "application/json"], body: body
        ) { raw -> HTTPResponse.Status in raw.status }
    }

    @Test("a fresh instance mints a token, and that token creates the first Admin")
    func tokenCreatesFirstAdmin() async throws {
        try await withServer { client, database, token in
            let status = try await self.post(client, try self.payload(token))
            #expect(status == .created)

            let admin = try #require(
                try UserRepository(database: database).credentials(
                    forEmail: "admin@example.com"))
            #expect(admin.user.role == .admin)
            #expect(admin.user.active)
        }
    }

    @Test("the created Admin can log in")
    func createdAdminCanLogIn() async throws {
        try await withServer { client, _, token in
            _ = try await self.post(client, try self.payload(token))

            let credentials: [String: Any] = [
                "email": "admin@example.com", "password": Self.password,
            ]
            let data: Data = try JSONSerialization.data(withJSONObject: credentials)
            try await client.execute(
                uri: "/api/v1/auth/login", method: .post,
                headers: [.contentType: "application/json"], body: ByteBuffer(data: data)
            ) { raw in
                #expect(raw.status == .ok)
            }
        }
    }

    @Test("a wrong token is refused")
    func wrongTokenIsRefused() async throws {
        try await withServer { client, _, _ in
            let status = try await self.post(client, try self.payload("issues_bootstrap_wrong"))
            #expect(status == .unauthorized)
        }
    }

    /// Single use. A token that kept working would be a permanent back door sitting
    /// in a log file.
    @Test("the token works once and then stops")
    func tokenIsSingleUse() async throws {
        try await withServer { client, _, token in
            #expect(try await self.post(client, try self.payload(token)) == .created)

            let second = try await self.post(
                client, try self.payload(token, email: "second@example.com"))
            #expect(second != .created)
        }
    }

    /// Once anybody exists, bootstrap is closed regardless of the token — otherwise
    /// a leaked token from first-run would still create an Admin months later.
    @Test("bootstrap is refused once a user exists")
    func refusedOnceAUserExists() async throws {
        try await withServer { client, database, token in
            try UserRepository(database: database).save(User.fixture())

            let status = try await self.post(client, try self.payload(token))
            #expect(status != .created)
        }
    }

    @Test("a short password is rejected with a field-level error")
    func shortPasswordRejected() async throws {
        try await withServer { client, _, token in
            let object: [String: Any] = [
                "token": token, "email": "admin@example.com", "displayName": "Admin",
                "password": "short",
            ]
            let data: Data = try JSONSerialization.data(withJSONObject: object)

            try await client.execute(
                uri: "/api/v1/auth/bootstrap", method: .post,
                headers: [.contentType: "application/json"], body: ByteBuffer(data: data)
            ) { raw in
                #expect(raw.status == .unprocessableContent)
                let problem = try JSONCoders.decoder.decode(
                    Problem.self, from: Data(buffer: raw.body))
                #expect(problem.errors?.first?.field == "password")
            }
        }
    }

    @Test("an expired token is refused")
    func expiredTokenIsRefused() async throws {
        try await withServer { client, database, token in
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE instance SET bootstrap_expires_at = ? WHERE id = 1",
                    arguments: [Date(timeIntervalSinceNow: -60)])
            }

            let status = try await self.post(client, try self.payload(token))
            #expect(status == .unauthorized)
        }
    }

    /// A second call on an already-bootstrapped instance must not mint a new token —
    /// that would reopen the door every restart.
    @Test("an instance that already has a user mints no token")
    func alreadyBootstrappedMintsNoToken() throws {
        let database = try AppDatabase.inMemory()
        try UserRepository(database: database).save(User.fixture())

        #expect(try BootstrapService(database: database).beginIfNeeded() == nil)
    }

    /// Env seeding exists because a one-time token in a log is hostile to automation
    /// (ticket 07).
    @Test("environment seeding creates the Admin without a token")
    func environmentSeedingCreatesAdmin() throws {
        let database = try AppDatabase.inMemory()
        let service = BootstrapService(database: database)

        let created = try service.seedFromEnvironment([
            "ISSUES_BOOTSTRAP_ADMIN_EMAIL": "seed@example.com",
            "ISSUES_BOOTSTRAP_ADMIN_PASSWORD": Self.password,
        ])

        #expect(created)
        let admin = try #require(
            try UserRepository(database: database).credentials(forEmail: "seed@example.com"))
        #expect(admin.user.role == .admin)
    }

    @Test("environment seeding does nothing when the variables are absent")
    func environmentSeedingIsOptional() throws {
        let database = try AppDatabase.inMemory()

        #expect(try BootstrapService(database: database).seedFromEnvironment([:]) == false)
    }

    @Test("environment seeding is refused on an instance that already has a user")
    func environmentSeedingRefusedWhenPopulated() throws {
        let database = try AppDatabase.inMemory()
        try UserRepository(database: database).save(User.fixture())

        let created = try BootstrapService(database: database).seedFromEnvironment([
            "ISSUES_BOOTSTRAP_ADMIN_EMAIL": "seed@example.com",
            "ISSUES_BOOTSTRAP_ADMIN_PASSWORD": Self.password,
        ])
        #expect(created == false)
    }
}

@Suite("Session reaping")
struct SessionReapingTests {

    /// Ticket 04: the background work is small — expired-session reaping, under
    /// ServiceLifecycle rather than cron or an external scheduler.
    @Test("reaping removes expired sessions and leaves live ones")
    func reapingRemovesOnlyExpired() throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture()
        try UserRepository(database: database).save(user)
        let sessions = SessionRepository(database: database)

        let live = try sessions.create(for: user.id, kind: .human, deviceId: "live")
        let stale = try sessions.create(for: user.id, kind: .human, deviceId: "stale")

        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE session SET expires_at = ? WHERE device_id = 'stale'",
                arguments: [Date(timeIntervalSinceNow: -60)])
        }

        let removed: Int = try sessions.reapExpired(before: Date())

        #expect(removed == 1)
        #expect(try sessions.authenticate(live.raw) != nil)
        #expect(try sessions.authenticate(stale.raw) == nil)
    }

    /// Reaping is not a substitute for checking expiry on every request: a session
    /// that expires between sweeps must still be refused.
    @Test("an expired session is refused even before it is reaped")
    func expiredSessionRefusedBeforeReaping() throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture()
        try UserRepository(database: database).save(user)
        let sessions = SessionRepository(database: database)
        let token = try sessions.create(for: user.id, kind: .human, deviceId: nil)

        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE session SET expires_at = ?",
                arguments: [Date(timeIntervalSinceNow: -1)])
        }

        #expect(try sessions.authenticate(token.raw) == nil)
        #expect(try sessions.reapExpired(before: Date()) == 1)
    }
}

@Suite("Bootstrap token publication")
struct BootstrapPublicationTests {

    /// Ticket 07 requires the token to be reachable by an admin who did not run the
    /// binary interactively — under launchd nobody sees stdout. A `0600` file they
    /// `cat` once beats grepping a log for a secret.
    @Test("the token file is written readable only by its owner")
    func tokenFileIsPrivate() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "issues-token-\(UUID().uuidString)")
        defer { BootstrapService.unpublish(at: url) }

        try BootstrapService.publish(token: "issues_bootstrap_abc", to: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "issues_bootstrap_abc")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600)
    }

    /// Self-deleting on use: a token file left behind is a secret sitting on disk
    /// after it has stopped being needed.
    @Test("the token file is removed once it is no longer needed")
    func tokenFileIsRemoved() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "issues-token-\(UUID().uuidString)")
        try BootstrapService.publish(token: "issues_bootstrap_abc", to: url)

        BootstrapService.unpublish(at: url)

        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("the standard paths sit under Application Support")
    func standardPaths() {
        let support = URL(filePath: "/Users/someone/Library/Application Support")

        #expect(
            ServerEntryPoint.databaseURL(applicationSupport: support).path
                == "/Users/someone/Library/Application Support/Issues/issues.sqlite")
        #expect(
            ServerEntryPoint.configurationURL(applicationSupport: support).path
                == "/Users/someone/Library/Application Support/Issues/config.toml")
        #expect(
            ServerEntryPoint.bootstrapTokenURL(applicationSupport: support).path
                == "/Users/someone/Library/Application Support/Issues/bootstrap-token")
    }
}

@Suite("Session reaper service")
struct SessionReaperServiceTests {

    /// The reaper runs on a timer under ServiceLifecycle. Driven here with a very
    /// short interval, then cancelled — the point is that the loop actually sweeps
    /// rather than that any particular interval elapsed.
    @Test("the service sweeps expired sessions while it runs")
    func serviceSweepsWhileRunning() async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture()
        try UserRepository(database: database).save(user)
        let sessions = SessionRepository(database: database)
        _ = try sessions.create(for: user.id, kind: .human, deviceId: "stale")
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE session SET expires_at = ?",
                arguments: [Date(timeIntervalSinceNow: -60)])
        }

        let reaper = SessionReaper(sessions: sessions, interval: .milliseconds(10))
        let task = Task { try await reaper.run() }

        // Give the loop a few intervals, then stop it.
        var remaining: Int = 1
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            remaining = try await database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session") ?? 0
            }
            if remaining == 0 { break }
        }
        task.cancel()

        #expect(remaining == 0, "the reaper never swept")
    }
}

@Suite("First-run precedence")
struct FirstRunPrecedenceTests {

    private func temporaryTokenURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "issues-firstrun-\(UUID().uuidString)")
    }

    /// Env seeding wins: a scripted deploy should never have to read a one-time
    /// token out of a log.
    @Test("environment seeding takes precedence and mints no token")
    func environmentSeedingTakesPrecedence() throws {
        let database = try AppDatabase.inMemory()
        let url = temporaryTokenURL()
        defer { BootstrapService.unpublish(at: url) }

        let token = try ServerEntryPoint.prepareFirstRun(
            database: database,
            environment: [
                "ISSUES_BOOTSTRAP_ADMIN_EMAIL": "seed@example.com",
                "ISSUES_BOOTSTRAP_ADMIN_PASSWORD": "correct horse battery staple",
            ],
            tokenURL: url)

        #expect(token == nil, "a token was minted even though seeding succeeded")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("with no seeding, a token is minted and published")
    func tokenMintedWithoutSeeding() throws {
        let database = try AppDatabase.inMemory()
        let url = temporaryTokenURL()
        defer { BootstrapService.unpublish(at: url) }

        let token = try ServerEntryPoint.prepareFirstRun(
            database: database, environment: [:], tokenURL: url)

        #expect(token != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A restart of an already-configured instance must not reopen the door.
    @Test("an already-configured instance mints nothing on restart")
    func configuredInstanceMintsNothing() throws {
        let database = try AppDatabase.inMemory()
        try UserRepository(database: database).save(User.fixture())
        let url = temporaryTokenURL()
        defer { BootstrapService.unpublish(at: url) }

        let token = try ServerEntryPoint.prepareFirstRun(
            database: database, environment: [:], tokenURL: url)

        #expect(token == nil)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }
}
