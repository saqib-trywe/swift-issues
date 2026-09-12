import Core
import Foundation
import GRDB
import Hummingbird

// `LoginRequest` and `LoginResponse` live in Core so the server and every client
// encode the same shape. Hummingbird needs the response to be encodable as a
// response body, which Core cannot know about.
extension LoginResponse: ResponseEncodable {}

/// Login, and the throttle that protects it.
struct LoginRoutes: Sendable {
    let database: AppDatabase
    let hasher: PasswordHasher

    /// Ticket 07: back off after five consecutive failures, capped at fifteen
    /// minutes.
    static let failuresBeforeLockout = 5
    static let maximumLockout: TimeInterval = 15 * 60

    func register(on group: RouterGroup<AppRequestContext>) {
        // Deliberately outside the authenticated group: this is how you get a token
        // in the first place.
        group.post("/auth/login") { request, context in
            let body = try await request.decode(as: LoginRequest.self, context: context)
            let email = body.email.lowercased()

            if let retryAfter = try lockout(for: email) {
                throw ProblemError.throttled(retryAfter: retryAfter)
            }

            // One failure response for every reason: wrong password, unknown
            // account, no password set, deactivated user. Distinguishing them turns
            // this endpoint into an account enumeration oracle (ticket 07).
            guard
                let found = try UserRepository(database: database)
                    .credentials(forEmail: email),
                found.user.active,
                try PasswordHasher.verify(body.password, against: found.passwordHash)
            else {
                try recordFailure(for: email)
                throw ProblemError.unauthenticated(
                    detail: "Those credentials are not valid.")
            }

            try clearFailures(for: email)
            // Labelled, so it is identifiable in `auth token list`. An unlabelled
            // row in a revocation list tells an Admin nothing about what it is.
            let token = try SessionRepository(database: database).create(
                for: found.user.id, kind: .human, deviceId: nil, label: "password login")
            return try EditedResponse(
                status: .ok, response: LoginResponse(token: token.raw, user: found.user))
        }
    }

    /// Remaining lockout in seconds, or `nil` if the account is not locked.
    private func lockout(for email: String) throws -> Int? {
        try database.reader.read { db in
            guard
                let until = try Date.fetchOne(
                    db, sql: "SELECT locked_until FROM login_attempt WHERE email = ?",
                    arguments: [email])
            else { return nil }
            let remaining = until.timeIntervalSinceNow
            return remaining > 0 ? Int(remaining.rounded(.up)) : nil
        }
    }

    /// Exponential backoff past the threshold, capped. The cap matters: an
    /// unbounded backoff would let an attacker lock a colleague out indefinitely.
    private func recordFailure(for email: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO login_attempt (email, failures) VALUES (?, 1)
                    ON CONFLICT (email) DO UPDATE SET failures = failures + 1
                    """,
                arguments: [email])

            let failures: Int =
                try Int.fetchOne(
                    db, sql: "SELECT failures FROM login_attempt WHERE email = ?",
                    arguments: [email]) ?? 0

            guard failures >= Self.failuresBeforeLockout else { return }
            let excess = failures - Self.failuresBeforeLockout
            let backoff = min(
                Self.maximumLockout, pow(2.0, Double(excess)) * 30.0)
            try db.execute(
                sql: "UPDATE login_attempt SET locked_until = ? WHERE email = ?",
                arguments: [Date().addingTimeInterval(backoff), email])
        }
    }

    /// Getting in resets the count: a few mistyped attempts earlier should not lock
    /// someone out hours later.
    private func clearFailures(for email: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM login_attempt WHERE email = ?", arguments: [email])
        }
    }
}

extension ProblemError {
    /// 429 with `Retry-After`, which ticket 12 requires agents to honour rather than
    /// retry through.
    static func throttled(retryAfter seconds: Int) -> ProblemError {
        ProblemError(
            status: .tooManyRequests, type: base + "throttled", title: "Too many attempts",
            detail: "Try again in \(seconds) seconds.", retryAfter: seconds)
    }
}
