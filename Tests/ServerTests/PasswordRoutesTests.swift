import Core
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

/// Setting and changing passwords.
///
/// Without this there is no way to give a created user a password at all, so
/// `user create` would produce an account nobody could ever log into.
@Suite("Password routes")
struct PasswordRoutesTests {

    private struct World: Sendable {
        let client: any TestClientProtocol
        let database: AppDatabase
        let admin: DomainUser
        let member: DomainUser
        let adminToken: String
        let memberToken: String
    }

    private static let memberPassword = "correct horse battery staple"

    private func withWorld(_ body: @Sendable @escaping (World) async throws -> Void) async throws {
        let database = try AppDatabase.inMemory()
        let users = UserRepository(database: database)
        let sessions = SessionRepository(database: database)

        let admin = DomainUser.fixture(
            id: DomainUser.ID(), email: "admin@example.com", displayName: "Ada", role: .admin)
        let member = DomainUser.fixture(
            id: DomainUser.ID(), email: "member@example.com", displayName: "Mel", role: .member)
        try users.save(admin)
        try users.save(member)
        try users.setPassword(try PasswordHasher.testing.hash(Self.memberPassword), for: member.id)

        let adminToken = try sessions.create(for: admin.id, kind: .human, deviceId: nil)
        let memberToken = try sessions.create(for: member.id, kind: .human, deviceId: nil)

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            try await body(
                World(
                    client: client, database: database, admin: admin, member: member,
                    adminToken: adminToken.raw, memberToken: memberToken.raw))
        }
    }

    private func setPassword(
        _ w: World, for id: DomainUser.ID, token: String, json: [String: Any]
    ) async throws -> HTTPResponse.Status {
        var headers: HTTPFields = [.authorization: "Bearer \(token)"]
        headers[.contentType] = "application/json"
        return try await w.client.execute(
            uri: "/api/v1/users/\(id.rawValue.uuidString)/password",
            method: .put, headers: headers,
            body: ByteBuffer(
                data: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
        ) { $0.status }
    }

    private func login(_ w: World, email: String, password: String) async throws
        -> HTTPResponse.Status
    {
        try await w.client.execute(
            uri: "/api/v1/auth/login", method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(
                data: try JSONSerialization.data(
                    withJSONObject: ["email": email, "password": password], options: [.sortedKeys]))
        ) { $0.status }
    }

    /// The whole point: an Admin can give a newly created account a password.
    @Test("an admin can set another user's password, and it works")
    func adminCanSetAnotherUsersPassword() async throws {
        try await withWorld { w in
            let status = try await setPassword(
                w, for: w.member.id, token: w.adminToken, json: ["password": "a brand new secret"])
            #expect(status == .noContent)

            #expect(try await login(w, email: "member@example.com", password: "a brand new secret") == .ok)
        }
    }

    /// An Admin resetting somebody else's password cannot know the current one,
    /// so requiring it would make reset impossible.
    @Test("an admin needs no current password for somebody else")
    func adminNeedsNoCurrentPasswordForSomebodyElse() async throws {
        try await withWorld { w in
            let status = try await setPassword(
                w, for: w.member.id, token: w.adminToken, json: ["password": "another new secret"])
            #expect(status == .noContent)
        }
    }

    @Test("a user can change their own password")
    func userCanChangeTheirOwnPassword() async throws {
        try await withWorld { w in
            let status = try await setPassword(
                w, for: w.member.id, token: w.memberToken,
                json: ["password": "a replacement secret", "currentPassword": Self.memberPassword])

            #expect(status == .noContent)
            #expect(try await login(w, email: "member@example.com", password: "a replacement secret") == .ok)
        }
    }

    /// Without this, a hijacked session is enough to lock the real owner out of
    /// their own account permanently.
    @Test("changing your own password requires the current one")
    func changingYourOwnRequiresTheCurrentOne() async throws {
        try await withWorld { w in
            let status = try await setPassword(
                w, for: w.member.id, token: w.memberToken,
                json: ["password": "a replacement secret", "currentPassword": "not it"])

            #expect(status == .forbidden)
            #expect(try await login(w, email: "member@example.com", password: Self.memberPassword) == .ok)
        }
    }

    @Test("changing your own password without supplying the current one is refused")
    func changingYourOwnWithoutCurrentIsRefused() async throws {
        try await withWorld { w in
            let status = try await setPassword(
                w, for: w.member.id, token: w.memberToken, json: ["password": "a replacement secret"])
            #expect(status == .forbidden)
        }
    }

    @Test("a member cannot set somebody else's password")
    func memberCannotSetSomebodyElsesPassword() async throws {
        try await withWorld { w in
            let status = try await setPassword(
                w, for: w.admin.id, token: w.memberToken, json: ["password": "not yours to set"])
            #expect(status == .forbidden)
        }
    }

    /// A changed password must end the sessions it was protecting, or "change your
    /// password" does nothing about whoever you changed it because of.
    @Test("changing a password revokes that user's other sessions")
    func changingAPasswordRevokesOtherSessions() async throws {
        try await withWorld { w in
            _ = try await setPassword(
                w, for: w.member.id, token: w.adminToken, json: ["password": "a brand new secret"])

            let afterwards = try await w.client.execute(
                uri: "/api/v1/users/me", method: .get,
                headers: [.authorization: "Bearer \(w.memberToken)"]
            ) { $0.status }
            #expect(afterwards == .unauthorized)
        }
    }

    @Test("a password below the minimum length is rejected")
    func shortPasswordIsRejected() async throws {
        try await withWorld { w in
            let status = try await setPassword(
                w, for: w.member.id, token: w.adminToken, json: ["password": "short"])

            #expect(status == .unprocessableContent)
            #expect(try await login(w, email: "member@example.com", password: Self.memberPassword) == .ok)
        }
    }

    @Test("setting a password for an unknown user is not found")
    func settingForAnUnknownUserIsNotFound() async throws {
        try await withWorld { w in
            let status = try await setPassword(
                w, for: DomainUser.ID(), token: w.adminToken, json: ["password": "a valid secret here"])
            #expect(status == .notFound)
        }
    }

    /// An Admin's agent is not an admin (ADR 0007); a token that could reset
    /// passwords would be a complete account takeover.
    @Test("an agent token cannot set a password")
    func agentTokenCannotSetAPassword() async throws {
        try await withWorld { w in
            let agent = try SessionRepository(database: w.database).create(
                for: w.admin.id, kind: .agent, deviceId: nil)

            let status = try await setPassword(
                w, for: w.member.id, token: agent.raw, json: ["password": "a valid secret here"])
            #expect(status == .forbidden)
        }
    }

    /// A user with no password set yet cannot prove a current one, so self-service
    /// must not be the way they get their first — an Admin sets it.
    @Test("a user with no password cannot set their own")
    func userWithNoPasswordCannotSetTheirOwn() async throws {
        try await withWorld { w in
            let adminSelf = try await setPassword(
                w, for: w.admin.id, token: w.adminToken,
                json: ["password": "a valid secret here", "currentPassword": ""])
            #expect(adminSelf == .forbidden)
        }
    }
}
