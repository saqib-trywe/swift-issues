import Core
import Foundation
import GRDB
import Hummingbird

/// First-run bootstrap.
///
/// An empty database has no Admin and no way to make one through an authenticated
/// API, so a fresh instance mints a one-time token — the Jenkins
/// `initialAdminPassword` pattern. Rejected alternative, recorded in ADR 0006:
/// "first user to register becomes Admin", which on a server exposed before anyone
/// logs in is a race an attacker wins.
public struct BootstrapService: Sendable {
    let database: AppDatabase
    let hasher: PasswordHasher

    /// Ticket 07: valid until used or sixty minutes, whichever comes first.
    public static let validity: TimeInterval = 60 * 60

    public init(database: AppDatabase, hasher: PasswordHasher = .production) {
        self.database = database
        self.hasher = hasher
    }

    /// Mints a token if the instance has no users yet, otherwise `nil`.
    ///
    /// Returning `nil` for a populated instance matters: minting one every restart
    /// would reopen the door indefinitely.
    public func beginIfNeeded() throws -> String? {
        try database.writer.write { db in
            guard try Self.isEmpty(db) else { return nil }

            let token = "issues_bootstrap_" + Self.randomHex(24)
            try db.execute(
                sql: """
                    UPDATE instance
                    SET bootstrap_token_hash = ?, bootstrap_expires_at = ?
                    WHERE id = 1
                    """,
                arguments: [
                    SessionToken.hash(token), Date().addingTimeInterval(Self.validity),
                ])
            return token
        }
    }

    /// Creates the first Admin, consuming the token.
    ///
    /// Throws rather than returning a flag, so a caller cannot ignore a failure and
    /// carry on as if an Admin existed.
    public func completeBootstrap(
        token: String, email: String, displayName: String, password: String
    ) throws -> User {
        let failures = Validation.password(password)
        guard failures.isEmpty else { throw ProblemError.invalid(failures) }

        let hash = try hasher.hash(password)
        let user = User(
            id: User.ID(), email: email.lowercased(), displayName: displayName,
            role: .admin, active: true, createdAt: Date(), updatedAt: Date())

        try database.writer.write { db in
            // Closed once anybody exists, regardless of the token: a token leaked
            // from first-run must not still create an Admin months later.
            guard try Self.isEmpty(db) else {
                throw ProblemError.conflict(
                    detail: "This instance has already been set up.")
            }
            guard
                let storedHash = try String.fetchOne(
                    db, sql: "SELECT bootstrap_token_hash FROM instance WHERE id = 1"),
                let expiry = try Date.fetchOne(
                    db, sql: "SELECT bootstrap_expires_at FROM instance WHERE id = 1"),
                expiry > Date(),
                storedHash == SessionToken.hash(token)
            else {
                throw ProblemError.unauthenticated(
                    detail: "That setup token is not valid.")
            }

            try Self.insert(user, passwordHash: hash, into: db)

            // Single use: a token that kept working would be a permanent back door
            // sitting in a log file.
            try db.execute(
                sql: """
                    UPDATE instance
                    SET bootstrap_token_hash = NULL, bootstrap_expires_at = NULL
                    WHERE id = 1
                    """)
        }

        return user
    }

    /// Creates the first Admin from `ISSUES_BOOTSTRAP_ADMIN_*`, returning whether it
    /// did.
    ///
    /// Exists because a one-time token printed to a log is hostile to automation
    /// (ticket 07). Silently does nothing on a populated instance, so a scripted
    /// deploy can run it unconditionally.
    @discardableResult
    public func seedFromEnvironment(_ environment: [String: String]) throws -> Bool {
        guard let email = environment["ISSUES_BOOTSTRAP_ADMIN_EMAIL"],
            let password = environment["ISSUES_BOOTSTRAP_ADMIN_PASSWORD"],
            Validation.password(password).isEmpty
        else { return false }

        let hash = try hasher.hash(password)
        let user = User(
            id: User.ID(), email: email.lowercased(), displayName: email,
            role: .admin, active: true, createdAt: Date(), updatedAt: Date())

        return try database.writer.write { db in
            guard try Self.isEmpty(db) else { return false }
            try Self.insert(user, passwordHash: hash, into: db)
            return true
        }
    }

    /// Writes the token where an admin who did not run the binary interactively can
    /// read it.
    ///
    /// Ticket 07 requires exactly that, and under launchd nobody sees stdout. A
    /// `0600` file they `cat` once beats telling them to grep a log for a secret,
    /// which is fragile and encourages leaving secrets in logs.
    public static func publish(token: String, to url: URL) throws {
        try Data(token.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes the published token once it has been used or has expired.
    public static func unpublish(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func isEmpty(_ db: Database) throws -> Bool {
        (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user") ?? 0) == 0
    }

    private static func insert(_ user: User, passwordHash: String, into db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO user
                    (id, email, display_name, role, active, password_hash, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                user.id.rawValue.uuidString, user.email, user.displayName,
                user.role.wireValue, user.active, passwordHash, user.createdAt,
                user.updatedAt,
            ])
        try ChangeCursor.record(db, entity: .user, id: user.id.rawValue.uuidString)
    }

    private static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

struct BootstrapRequest: Codable, Sendable {
    let token: String
    let email: String
    let displayName: String
    let password: String
}

extension LoginRoutes {
    /// Bootstrap sits beside login, outside the authenticated group: there is nobody
    /// to authenticate as yet.
    func registerBootstrap(on group: RouterGroup<AppRequestContext>) {
        group.post("/auth/bootstrap") { request, context in
            let body = try await request.decode(as: BootstrapRequest.self, context: context)
            let user = try BootstrapService(database: database, hasher: hasher)
                .completeBootstrap(
                    token: body.token, email: body.email, displayName: body.displayName,
                    password: body.password)
            return try EditedResponse(status: .created, response: user)
        }
    }
}
