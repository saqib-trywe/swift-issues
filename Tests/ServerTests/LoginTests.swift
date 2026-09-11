import Core
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

@Suite("Login")
struct LoginTests {

    private struct World: Sendable {
        let client: any TestClientProtocol
        let database: AppDatabase
        let user: User
        let password: String
    }

    private static let password = "correct horse battery staple"

    private func withWorld(
        active: Bool = true,
        _ body: @Sendable @escaping (World) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let users = UserRepository(database: database)
        let user = User.fixture(email: "me@example.com", active: active)
        try users.save(user)
        // Cheap parameters: the hash records its own, so verification is unchanged.
        try users.setPassword(
            try PasswordHasher.testing.hash(Self.password), for: user.id)

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            try await body(
                World(
                    client: client, database: database, user: user, password: Self.password))
        }
    }

    private func login(
        _ w: World, email: String, password: String
    ) async throws -> (status: HTTPResponse.Status, body: String) {
        let payload: [String: Any] = ["email": email, "password": password]
        let data: Data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let headers: HTTPFields = [.contentType: "application/json"]

        return try await w.client.execute(
            uri: "/api/v1/auth/login", method: .post, headers: headers,
            body: ByteBuffer(data: data)
        ) { raw -> (HTTPResponse.Status, String) in
            (raw.status, String(buffer: raw.body))
        }
    }

    /// Login is unauthenticated by necessity, and returns a token that works.
    @Test("correct credentials return a usable token")
    func correctCredentialsReturnAUsableToken() async throws {
        try await withWorld { w in
            let result = try await self.login(
                w, email: "me@example.com", password: w.password)
            #expect(result.status == .ok)

            let session = try JSONCoders.decoder.decode(
                LoginResponse.self, from: Data(result.body.utf8))

            // The token authenticates a subsequent request.
            try await w.client.execute(
                uri: "/api/v1/meta", method: .get,
                headers: [.authorization: "Bearer \(session.token)"]
            ) { raw in
                #expect(raw.status == .ok)
            }
        }
    }

    /// The security property that matters most here: a wrong password and an unknown
    /// account must be indistinguishable, or the endpoint becomes an account
    /// enumeration oracle. Ticket 07 makes this a server-side obligation.
    @Test("an unknown account and a wrong password are indistinguishable")
    func unknownAccountAndWrongPasswordMatch() async throws {
        try await withWorld { w in
            let wrongPassword = try await self.login(
                w, email: "me@example.com", password: "definitely not it")
            let unknownAccount = try await self.login(
                w, email: "nobody@example.com", password: "definitely not it")

            #expect(wrongPassword.status == .unauthorized)
            #expect(unknownAccount.status == .unauthorized)
            #expect(
                wrongPassword.body == unknownAccount.body,
                "the responses differ, so the endpoint enumerates accounts")
        }
    }

    /// A deactivated account must not be able to log in, and must not be
    /// distinguishable from a wrong password either.
    @Test("a deactivated account cannot log in")
    func deactivatedAccountCannotLogIn() async throws {
        try await withWorld(active: false) { w in
            let result = try await self.login(
                w, email: "me@example.com", password: w.password)

            #expect(result.status == .unauthorized)
        }
    }

    /// Ticket 07's narrow exception to the no-rate-limiting rule: an unauthenticated
    /// attacker guessing passwords is not an identifiable team member.
    @Test("repeated failures are throttled with a Retry-After")
    func repeatedFailuresAreThrottled() async throws {
        try await withWorld { w in
            for _ in 0..<5 {
                let attempt = try await self.login(
                    w, email: "me@example.com", password: "wrong")
                #expect(attempt.status == .unauthorized)
            }

            let headers: HTTPFields = [.contentType: "application/json"]
            let payload: [String: Any] = ["email": "me@example.com", "password": "wrong"]
            let data: Data = try JSONSerialization.data(withJSONObject: payload)

            try await w.client.execute(
                uri: "/api/v1/auth/login", method: .post, headers: headers,
                body: ByteBuffer(data: data)
            ) { raw in
                #expect(raw.status == .tooManyRequests)
                let retryAfter: String? = raw.headers[.retryAfter]
                #expect(retryAfter != nil, "429 without Retry-After")
                #expect(Int(retryAfter ?? "") ?? 0 > 0)
            }
        }
    }

    /// Throttling is counted per account rather than per IP: per-IP is trivially
    /// evaded and punishes everyone behind one NAT.
    @Test("throttling one account leaves another usable")
    func throttlingIsPerAccount() async throws {
        try await withWorld { w in
            let users = UserRepository(database: w.database)
            let other = User.fixture(email: "other@example.com")
            try users.save(other)
            try users.setPassword(
                try PasswordHasher.testing.hash(w.password), for: other.id)

            for _ in 0..<6 {
                _ = try await self.login(w, email: "me@example.com", password: "wrong")
            }

            let unaffected = try await self.login(
                w, email: "other@example.com", password: w.password)
            #expect(unaffected.status == .ok, "one account's lockout blocked another")
        }
    }

    /// Once you get in, the counter resets — otherwise a few mistyped attempts
    /// earlier in the day would lock you out later for no reason.
    @Test("a successful login clears the failure count")
    func successClearsTheFailureCount() async throws {
        try await withWorld { w in
            for _ in 0..<4 {
                _ = try await self.login(w, email: "me@example.com", password: "wrong")
            }
            let success = try await self.login(
                w, email: "me@example.com", password: w.password)
            #expect(success.status == .ok)

            // Four more failures must not trip the lockout, since the count reset.
            for _ in 0..<4 {
                let attempt = try await self.login(
                    w, email: "me@example.com", password: "wrong")
                #expect(attempt.status == .unauthorized)
            }
        }
    }

    @Test("a password below the minimum length is rejected on its own terms")
    func shortPasswordIsRejected() async throws {
        try await withWorld { w in
            let result = try await self.login(w, email: "me@example.com", password: "short")

            // Still unauthorized rather than 422: telling an attacker their guess was
            // too short to be anyone's password is information they should not get.
            #expect(result.status == .unauthorized)
        }
    }

    @Test("a user with no password set cannot log in")
    func userWithoutPasswordCannotLogIn() async throws {
        try await withWorld { w in
            let users = UserRepository(database: w.database)
            let passwordless = User.fixture(email: "sso@example.com")
            try users.save(passwordless)

            let result = try await self.login(
                w, email: "sso@example.com", password: w.password)
            #expect(result.status == .unauthorized)
        }
    }
}
