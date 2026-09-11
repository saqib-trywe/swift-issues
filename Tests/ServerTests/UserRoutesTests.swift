import Core
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

typealias DomainUser = Core.User

/// The User resource. Ticket 06 specifies it and every client needs `/users/me`
/// to know who it is talking as; it was missing until the CLI tried to use it.
@Suite("User routes")
struct UserRoutesTests {

    private struct World: Sendable {
        let client: any TestClientProtocol
        let database: AppDatabase
        let admin: DomainUser
        let member: DomainUser
        let adminToken: String
        let memberToken: String
    }

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

    private func call(
        _ w: World, _ method: HTTPRequest.Method, _ uri: String,
        token: String, json: [String: Any]? = nil
    ) async throws -> (status: HTTPResponse.Status, body: String) {
        var headers: HTTPFields = [.authorization: "Bearer \(token)"]
        var buffer: ByteBuffer?
        if let json {
            headers[.contentType] = "application/json"
            buffer = ByteBuffer(
                data: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
        }
        return try await w.client.execute(uri: uri, method: method, headers: headers, body: buffer) {
            ($0.status, String(buffer: $0.body))
        }
    }

    /// Every client needs this to render "assigned to me" without first being
    /// told its own id out of band.
    @Test("me returns the authenticated caller")
    func meReturnsTheCaller() async throws {
        try await withWorld { w in
            let response = try await call(w, .get, "/api/v1/users/me", token: w.memberToken)
            #expect(response.status == .ok)

            let user = try JSONCoders.decoder.decode(DomainUser.self, from: Data(response.body.utf8))
            #expect(user.id == w.member.id)
            #expect(user.email == "member@example.com")
        }
    }

    /// `/users/me` and `/users/:id` sit at the same path depth. Hummingbird has
    /// to prefer the literal, and a regression here would send `me` to the id
    /// handler and 404 for everyone.
    @Test("me is not shadowed by the id route")
    func meIsNotShadowedByTheIdRoute() async throws {
        try await withWorld { w in
            let byMe = try await call(w, .get, "/api/v1/users/me", token: w.adminToken)
            let byId = try await call(
                w, .get, "/api/v1/users/\(w.admin.id.rawValue.uuidString)", token: w.adminToken)

            #expect(byMe.status == .ok)
            #expect(byId.status == .ok)
            #expect(byMe.body == byId.body)
        }
    }

    @Test("a member can list users")
    func aMemberCanListUsers() async throws {
        try await withWorld { w in
            let response = try await call(w, .get, "/api/v1/users", token: w.memberToken)
            #expect(response.status == .ok)

            let page = try JSONCoders.decoder.decode(
                Paginated<DomainUser>.self, from: Data(response.body.utf8))
            #expect(page.items.count == 2)
        }
    }

    @Test("an unknown id is not found")
    func anUnknownIdIsNotFound() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .get, "/api/v1/users/\(UUID().uuidString)", token: w.memberToken)
            #expect(response.status == .notFound)
        }
    }

    @Test("an admin can create a user")
    func anAdminCanCreateAUser() async throws {
        try await withWorld { w in
            let id = UUID().uuidString
            let response = try await call(
                w, .put, "/api/v1/users/\(id)", token: w.adminToken,
                json: ["email": "new@example.com", "displayName": "Nia", "role": "member"])

            #expect(response.status == .created)
            let created = try JSONCoders.decoder.decode(
                DomainUser.self, from: Data(response.body.utf8))
            #expect(created.email == "new@example.com")
            #expect(created.active)
        }
    }

    /// The allow case beside the deny case: without it, a rule that rejects
    /// everybody would pass its own test.
    @Test("a member cannot create a user")
    func aMemberCannotCreateAUser() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .put, "/api/v1/users/\(UUID().uuidString)", token: w.memberToken,
                json: ["email": "new@example.com", "displayName": "Nia", "role": "member"])
            #expect(response.status == .forbidden)
        }
    }

    /// The retry an offline client makes when it never saw the response must not
    /// create a second account.
    @Test("repeating an identical create is not an error")
    func repeatingAnIdenticalCreateIsNotAnError() async throws {
        try await withWorld { w in
            let id = UUID().uuidString
            let body: [String: Any] = ["email": "new@example.com", "displayName": "Nia", "role": "member"]

            let first = try await call(w, .put, "/api/v1/users/\(id)", token: w.adminToken, json: body)
            let second = try await call(w, .put, "/api/v1/users/\(id)", token: w.adminToken, json: body)

            #expect(first.status == .created)
            #expect(second.status == .ok)
        }
    }

    @Test("re-creating an id with different content conflicts")
    func recreatingAnIdWithDifferentContentConflicts() async throws {
        try await withWorld { w in
            let id = UUID().uuidString
            _ = try await call(
                w, .put, "/api/v1/users/\(id)", token: w.adminToken,
                json: ["email": "new@example.com", "displayName": "Nia", "role": "member"])
            let again = try await call(
                w, .put, "/api/v1/users/\(id)", token: w.adminToken,
                json: ["email": "other@example.com", "displayName": "Nia", "role": "member"])

            #expect(again.status == .conflict)
        }
    }

    /// Email uniqueness is what login resolves against, so a duplicate would make
    /// one of the two accounts unreachable.
    @Test("a duplicate email conflicts")
    func aDuplicateEmailConflicts() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .put, "/api/v1/users/\(UUID().uuidString)", token: w.adminToken,
                json: ["email": "member@example.com", "displayName": "Copy", "role": "member"])
            #expect(response.status == .conflict)
        }
    }

    @Test("an invalid email is rejected")
    func anInvalidEmailIsRejected() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .put, "/api/v1/users/\(UUID().uuidString)", token: w.adminToken,
                json: ["email": "not-an-email", "displayName": "Nia", "role": "member"])
            #expect(response.status == .unprocessableContent)
        }
    }

    @Test("an admin can deactivate a user")
    func anAdminCanDeactivateAUser() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .patch, "/api/v1/users/\(w.member.id.rawValue.uuidString)",
                token: w.adminToken, json: ["active": false])

            #expect(response.status == .ok)
            let updated = try JSONCoders.decoder.decode(
                DomainUser.self, from: Data(response.body.utf8))
            #expect(!updated.active)
        }
    }

    /// Deactivation has to end the session too. Leaving live tokens working would
    /// make "deactivate" mean nothing until they expired, up to sixty days later.
    @Test("deactivation revokes the user's sessions")
    func deactivationRevokesSessions() async throws {
        try await withWorld { w in
            _ = try await call(
                w, .patch, "/api/v1/users/\(w.member.id.rawValue.uuidString)",
                token: w.adminToken, json: ["active": false])

            let afterwards = try await call(w, .get, "/api/v1/users/me", token: w.memberToken)
            #expect(afterwards.status == .unauthorized)
        }
    }

    @Test("a member may rename themselves")
    func aMemberMayRenameThemselves() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .patch, "/api/v1/users/\(w.member.id.rawValue.uuidString)",
                token: w.memberToken, json: ["displayName": "Mel R."])

            #expect(response.status == .ok)
            let updated = try JSONCoders.decoder.decode(
                DomainUser.self, from: Data(response.body.utf8))
            #expect(updated.displayName == "Mel R.")
        }
    }

    @Test("a member may not rename somebody else")
    func aMemberMayNotRenameSomebodyElse() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .patch, "/api/v1/users/\(w.admin.id.rawValue.uuidString)",
                token: w.memberToken, json: ["displayName": "Not Ada"])
            #expect(response.status == .forbidden)
        }
    }

    /// Self-promotion would make the Admin role meaningless.
    @Test("a member may not promote themselves")
    func aMemberMayNotPromoteThemselves() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .patch, "/api/v1/users/\(w.member.id.rawValue.uuidString)",
                token: w.memberToken, json: ["role": "admin"])

            #expect(response.status == .forbidden)
            let unchanged = try UserRepository(database: w.database).find(w.member.id)
            #expect(unchanged?.role == .member)
        }
    }

    /// The allow case beside the deny: without it, a rule that refused everybody
    /// would pass every test written for it.
    @Test("an admin can promote a member")
    func anAdminCanPromoteAMember() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .patch, "/api/v1/users/\(w.member.id.rawValue.uuidString)",
                token: w.adminToken, json: ["role": "admin"])

            #expect(response.status == .ok)
            let updated = try JSONCoders.decoder.decode(
                DomainUser.self, from: Data(response.body.utf8))
            #expect(updated.role == .admin)
        }
    }

    /// Reactivation has to work, or a mistaken deactivation is permanent.
    @Test("an admin can reactivate a user")
    func anAdminCanReactivateAUser() async throws {
        try await withWorld { w in
            _ = try await call(
                w, .patch, "/api/v1/users/\(w.member.id.rawValue.uuidString)",
                token: w.adminToken, json: ["active": false])
            let response = try await call(
                w, .patch, "/api/v1/users/\(w.member.id.rawValue.uuidString)",
                token: w.adminToken, json: ["active": true])

            #expect(response.status == .ok)
            let updated = try JSONCoders.decoder.decode(
                DomainUser.self, from: Data(response.body.utf8))
            #expect(updated.active)
        }
    }

    @Test("patching an unknown user is not found")
    func patchingAnUnknownUserIsNotFound() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .patch, "/api/v1/users/\(UUID().uuidString)",
                token: w.adminToken, json: ["displayName": "Nobody"])
            #expect(response.status == .notFound)
        }
    }

    /// A path parameter that is not a UUID is a missing user, not a crash and not
    /// a 500.
    @Test(
        "a malformed id is not found rather than a server error",
        arguments: [
            "not-a-uuid", "12345",
        ])
    func malformedIdIsNotFound(_ raw: String) async throws {
        try await withWorld { w in
            let response = try await call(w, .get, "/api/v1/users/\(raw)", token: w.memberToken)
            #expect(response.status == .notFound)
        }
    }

    /// An Admin's agent is not an admin (ADR 0007), so a token that could create
    /// accounts would quietly widen every agent's authority to the maximum.
    @Test("an agent token cannot create a user")
    func anAgentTokenCannotCreateAUser() async throws {
        try await withWorld { w in
            let agent = try SessionRepository(database: w.database).create(
                for: w.admin.id, kind: .agent, deviceId: nil)

            let response = try await call(
                w, .put, "/api/v1/users/\(UUID().uuidString)", token: agent.raw,
                json: ["email": "agent@example.com", "displayName": "Bot", "role": "member"])
            #expect(response.status == .forbidden)
        }
    }
}
