import Core
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

/// Personal access tokens. There is no web UI, so this is the only way to manage
/// one (ticket 07), and the rules here are what keep ADR 0007's agent profile
/// meaningful.
@Suite("Token routes")
struct TokenRoutesTests {

    private struct World: Sendable {
        let client: any TestClientProtocol
        let database: AppDatabase
        let admin: DomainUser
        let member: DomainUser
        let adminToken: String
        let memberToken: String
    }

    private static let password = "correct horse battery staple"

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
        for user in [admin, member] {
            try users.setPassword(try PasswordHasher.testing.hash(Self.password), for: user.id)
        }

        let adminToken = try sessions.create(
            for: admin.id, kind: .human, deviceId: nil, label: "admin laptop")
        let memberToken = try sessions.create(
            for: member.id, kind: .human, deviceId: nil, label: "member laptop")

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

    private func tokens(_ body: String) throws -> [SessionSummary] {
        try JSONCoders.decoder.decode(
            Paginated<SessionSummary>.self, from: Data(body.utf8)
        ).items
    }

    @Test("listing returns your own tokens")
    func listingReturnsYourOwnTokens() async throws {
        try await withWorld { w in
            let response = try await call(w, .get, "/api/v1/auth/tokens", token: w.memberToken)

            #expect(response.status == .ok)
            let listed = try tokens(response.body)
            #expect(listed.count == 1)
            #expect(listed.first?.label == "member laptop")
            #expect(listed.first?.userId == w.member.id)
        }
    }

    /// A listing is read to decide what to revoke, so it must be safe to print,
    /// log and paste. No token material may appear in it.
    @Test("a listing carries no token material")
    func listingCarriesNoTokenMaterial() async throws {
        try await withWorld { w in
            let response = try await call(w, .get, "/api/v1/auth/tokens", token: w.memberToken)

            #expect(!response.body.contains(w.memberToken))
            #expect(!response.body.contains(SessionToken.hash(w.memberToken)))
            #expect(!response.body.lowercased().contains("hash"))
        }
    }

    @Test("listing does not leak another user's tokens")
    func listingDoesNotLeakAnotherUsersTokens() async throws {
        try await withWorld { w in
            let response = try await call(w, .get, "/api/v1/auth/tokens", token: w.memberToken)
            let listed = try tokens(response.body)
            #expect(listed.allSatisfy { $0.userId == w.member.id })
        }
    }

    @Test("minting returns a token that works")
    func mintingReturnsAWorkingToken() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .post, "/api/v1/auth/tokens", token: w.memberToken,
                json: ["password": Self.password, "kind": "agent", "label": "mcp"])

            #expect(response.status == .created)
            let issued = try JSONCoders.decoder.decode(
                TokenIssued.self, from: Data(response.body.utf8))
            #expect(issued.session.kind == .agent)
            #expect(issued.session.label == "mcp")

            // The real proof: the minted token authenticates.
            let used = try await call(w, .get, "/api/v1/users/me", token: issued.token)
            #expect(used.status == .ok)
        }
    }

    /// Without the password, a leaked token could mint children and revoking the
    /// original would leave them working — the compromise would outlive the
    /// revocation.
    @Test("minting requires the password even with a valid token")
    func mintingRequiresThePassword() async throws {
        try await withWorld { w in
            let wrong = try await call(
                w, .post, "/api/v1/auth/tokens", token: w.memberToken,
                json: ["password": "not it", "kind": "human"])
            #expect(wrong.status == .forbidden)

            let missing = try await call(
                w, .post, "/api/v1/auth/tokens", token: w.memberToken, json: ["kind": "human"])
            #expect(missing.status == .badRequest || missing.status == .unprocessableContent)

            let listed = try tokens(
                try await call(w, .get, "/api/v1/auth/tokens", token: w.memberToken).body)
            #expect(listed.count == 1, "a token was minted without a correct password")
        }
    }

    /// An agent that could mint a human-kind token would escape ADR 0007's profile
    /// entirely, by granting itself its owner's full authority.
    @Test("an agent token may not mint tokens", arguments: ["human", "agent"])
    func agentMayNotMintTokens(_ kind: String) async throws {
        try await withWorld { w in
            let agent = try SessionRepository(database: w.database).create(
                for: w.admin.id, kind: .agent, deviceId: nil, label: "mcp")

            let response = try await call(
                w, .post, "/api/v1/auth/tokens", token: agent.raw,
                json: ["password": Self.password, "kind": kind])
            #expect(response.status == .forbidden)
        }
    }

    /// An unknown kind would authenticate and then grant no capabilities at all,
    /// which is confusing rather than safe.
    @Test("an unknown kind is refused")
    func unknownKindIsRefused() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .post, "/api/v1/auth/tokens", token: w.memberToken,
                json: ["password": Self.password, "kind": "superuser"])

            #expect(response.status == .unprocessableContent)
            #expect(response.body.contains("agentReadonly"))
        }
    }

    @Test("revoking your own token stops it working")
    func revokingYourOwnTokenStopsItWorking() async throws {
        try await withWorld { w in
            let issued = try JSONCoders.decoder.decode(
                TokenIssued.self,
                from: Data(
                    try await call(
                        w, .post, "/api/v1/auth/tokens", token: w.memberToken,
                        json: ["password": Self.password, "kind": "agent", "label": "mcp"]
                    ).body.utf8))

            let revoked = try await call(
                w, .delete, "/api/v1/auth/tokens/\(issued.session.id.rawValue.uuidString)",
                token: w.memberToken)
            #expect(revoked.status == .noContent)

            let used = try await call(w, .get, "/api/v1/users/me", token: issued.token)
            #expect(used.status == .unauthorized)
        }
    }

    /// Revoking one token must not log every device out.
    @Test("revoking one token leaves the others working")
    func revokingOneLeavesOthersWorking() async throws {
        try await withWorld { w in
            let issued = try JSONCoders.decoder.decode(
                TokenIssued.self,
                from: Data(
                    try await call(
                        w, .post, "/api/v1/auth/tokens", token: w.memberToken,
                        json: ["password": Self.password, "kind": "agent"]
                    ).body.utf8))

            _ = try await call(
                w, .delete, "/api/v1/auth/tokens/\(issued.session.id.rawValue.uuidString)",
                token: w.memberToken)

            let stillWorks = try await call(w, .get, "/api/v1/users/me", token: w.memberToken)
            #expect(stillWorks.status == .ok)
        }
    }

    /// That is how a departing colleague or a leaked token gets dealt with.
    @Test("an admin may revoke anybody's token")
    func adminMayRevokeAnybodysToken() async throws {
        try await withWorld { w in
            let id = try #require(
                try SessionRepository(database: w.database).list(for: w.member.id).first?.id)

            let response = try await call(
                w, .delete, "/api/v1/auth/tokens/\(id.rawValue.uuidString)", token: w.adminToken)
            #expect(response.status == .noContent)

            let used = try await call(w, .get, "/api/v1/users/me", token: w.memberToken)
            #expect(used.status == .unauthorized)
        }
    }

    @Test("a member may not revoke somebody else's token")
    func memberMayNotRevokeSomebodyElsesToken() async throws {
        try await withWorld { w in
            let id = try #require(
                try SessionRepository(database: w.database).list(for: w.admin.id).first?.id)

            let response = try await call(
                w, .delete, "/api/v1/auth/tokens/\(id.rawValue.uuidString)", token: w.memberToken)
            #expect(response.status == .forbidden)

            let stillWorks = try await call(w, .get, "/api/v1/users/me", token: w.adminToken)
            #expect(stillWorks.status == .ok)
        }
    }

    /// A script needs to tell "I revoked it" from "somebody already had".
    @Test("revoking twice reports gone the second time")
    func revokingTwiceReportsGone() async throws {
        try await withWorld { w in
            let id = try #require(
                try SessionRepository(database: w.database).list(for: w.member.id).first?.id)

            let first = try await call(
                w, .delete, "/api/v1/auth/tokens/\(id.rawValue.uuidString)", token: w.adminToken)
            let second = try await call(
                w, .delete, "/api/v1/auth/tokens/\(id.rawValue.uuidString)", token: w.adminToken)

            #expect(first.status == .noContent)
            #expect(second.status == .gone)
        }
    }

    @Test(
        "revoking an unknown or malformed id is not found",
        arguments: [
            UUID().uuidString, "not-a-uuid",
        ])
    func revokingAnUnknownIdIsNotFound(_ raw: String) async throws {
        try await withWorld { w in
            let response = try await call(
                w, .delete, "/api/v1/auth/tokens/\(raw)", token: w.adminToken)
            #expect(response.status == .notFound)
        }
    }

    @Test("an admin may list another user's tokens")
    func adminMayListAnotherUsersTokens() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .get, "/api/v1/users/\(w.member.id.rawValue.uuidString)/tokens",
                token: w.adminToken)

            #expect(response.status == .ok)
            #expect(try tokens(response.body).count == 1)
        }
    }

    @Test("a member may not list another user's tokens")
    func memberMayNotListAnotherUsersTokens() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .get, "/api/v1/users/\(w.admin.id.rawValue.uuidString)/tokens",
                token: w.memberToken)
            #expect(response.status == .forbidden)
        }
    }

    @Test("a member may list their own tokens through the user path")
    func memberMayListTheirOwnThroughTheUserPath() async throws {
        try await withWorld { w in
            let response = try await call(
                w, .get, "/api/v1/users/\(w.member.id.rawValue.uuidString)/tokens",
                token: w.memberToken)
            #expect(response.status == .ok)
        }
    }

    /// Deactivation already ends sessions; the listing must reflect that rather
    /// than showing tokens that no longer work.
    @Test("deactivating a user empties their token list")
    func deactivatingAUserEmptiesTheirTokenList() async throws {
        try await withWorld { w in
            _ = try await call(
                w, .patch, "/api/v1/users/\(w.member.id.rawValue.uuidString)",
                token: w.adminToken, json: ["active": false])

            let response = try await call(
                w, .get, "/api/v1/users/\(w.member.id.rawValue.uuidString)/tokens",
                token: w.adminToken)
            #expect(try tokens(response.body).isEmpty)
        }
    }
}

/// A revocation list is only useful if its rows can be told apart.
@Suite("Token labelling")
struct TokenLabellingTests {

    @Test("a session created by logging in is labelled")
    func loginSessionIsLabelled() async throws {
        let database = try AppDatabase.inMemory()
        let users = UserRepository(database: database)
        let user = DomainUser.fixture(email: "me@example.com")
        try users.save(user)
        try users.setPassword(try PasswordHasher.testing.hash("correct horse battery staple"), for: user.id)

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            _ = try await client.execute(
                uri: "/api/v1/auth/login", method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(
                    data: try JSONSerialization.data(
                        withJSONObject: [
                            "email": "me@example.com", "password": "correct horse battery staple",
                        ], options: [.sortedKeys]))
            ) { $0.status }
        }

        let listed = try SessionRepository(database: database).list(for: user.id)
        #expect(listed.first?.label != nil)
        #expect(listed.first?.label?.isEmpty == false)
    }
}
