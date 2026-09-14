import Core
import Foundation
import GRDB

/// What an operator can do on the host, without going through the API.
///
/// `reset-password` exists because the API cannot help here: if the only Admin
/// forgets their password there is nobody left to ask, so ticket 07 makes this the
/// sole lockout recovery path. It authenticates by filesystem access to the
/// database, which is the same authority that could read every issue anyway.
public enum AdminOperations {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noSuchUser(String)
        case rejected([String])
        case deactivated(String)

        public var description: String {
            switch self {
            case .noSuchUser(let email):
                "No user has the email \(email)."
            case .rejected(let reasons):
                reasons.joined(separator: " ")
            case .deactivated(let email):
                "\(email) is deactivated, so a password would grant nothing. Reactivate the account first."
            }
        }
    }

    /// Sets a user's password, ends their sessions, and clears any login lockout.
    @discardableResult
    public static func resetPassword(
        _ password: String, forEmail email: String, in database: AppDatabase,
        hasher: PasswordHasher = .production
    ) throws -> User {
        let users = UserRepository(database: database)
        guard let user = try users.find(email: email) else { throw Failure.noSuchUser(email) }
        guard user.active else { throw Failure.deactivated(email) }

        // The same rules the API applies. A password set on the host is not a
        // password held to a lower standard.
        let failures = Validation.password(password)
        guard failures.isEmpty else { throw Failure.rejected(failures.map(\.message)) }

        try users.setPassword(try hasher.hash(password), for: user.id)

        // Matches the HTTP path: a changed password must end the sessions it was
        // protecting, or changing it does nothing about whoever you changed it for.
        try SessionRepository(database: database).revokeAll(for: user.id)

        // Lockout is counted per account (ticket 07). A reset that left the lock in
        // place would hand back an account the owner still cannot log into — which
        // is the exact situation this command exists to end.
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM login_attempt WHERE email = ? COLLATE NOCASE",
                arguments: [user.email])
        }
        return user
    }
}
