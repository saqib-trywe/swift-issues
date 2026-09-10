import Core
import Foundation
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

@Suite("Authentication middleware")
struct AuthenticationMiddlewareTests {

    /// Builds a router with the middleware plus a few routes exercising the
    /// authority rules, and runs it through Hummingbird's in-memory test client —
    /// no socket, so this stays inside ticket 13's 60-second budget.
    private func withServer(
        role: Role = .member,
        kind: TokenKind = .human,
        _ body: @Sendable @escaping (any TestClientProtocol, String) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: role)
        try UserRepository(database: database).save(user)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: kind, deviceId: nil)

        let router = Router(context: AppRequestContext.self)
        router.add(middleware: AuthenticationMiddleware(sessions: SessionRepository(database: database)))
        router.get("/whoami") { _, context in context.identity.userId.description }
        router.get("/admin-only") { _, context in
            try context.require(.admin)
            return "ok"
        }
        router.delete("/destructive") { _, context in
            try context.requireCapability(.destructive)
            return "ok"
        }
        router.post("/write") { _, context in
            try context.requireCapability(.write)
            return "ok"
        }

        try await Application(router: router).test(.router) { client in
            try await body(client, token.raw)
        }
    }

    @Test("a request with no token is unauthenticated")
    func noTokenIsUnauthenticated() async throws {
        try await withServer { client, _ in
            try await client.execute(uri: "/whoami", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    /// The scheme matters: a bare token, or Basic auth, is not a bearer token and
    /// must not be treated as one.
    @Test(
        "a malformed Authorization header is unauthenticated",
        arguments: ["", "Basic abc", "bearer", "Token issues_pat_x"]
    )
    func malformedHeaderIsUnauthenticated(header: String) async throws {
        try await withServer { client, _ in
            try await client.execute(
                uri: "/whoami", method: .get, headers: [.authorization: header]
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("an unknown token is unauthenticated")
    func unknownTokenIsUnauthenticated() async throws {
        try await withServer { client, _ in
            try await client.execute(
                uri: "/whoami", method: .get,
                headers: [.authorization: "Bearer issues_pat_nope"]
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("a valid token reaches the handler with an identity")
    func validTokenReachesHandler() async throws {
        try await withServer { client, token in
            try await client.execute(
                uri: "/whoami", method: .get, headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).isEmpty == false)
            }
        }
    }

    /// 401 and 403 must stay distinct: a permissions failure must not send a user
    /// to re-login, and per ADR 0006 a 401 mid-sync preserves the pending queue
    /// while a 403 does not.
    @Test("a member on an admin route is forbidden, not unauthenticated")
    func memberOnAdminRouteIsForbidden() async throws {
        try await withServer(role: .member) { client, token in
            try await client.execute(
                uri: "/admin-only", method: .get, headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("an admin on an admin route is allowed")
    func adminOnAdminRouteIsAllowed() async throws {
        try await withServer(role: .admin) { client, token in
            try await client.execute(
                uri: "/admin-only", method: .get, headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// ADR 0007: an agent's authority is fixed and narrower than its owner's,
    /// *regardless* of that owner's role. An Admin's agent is still not an admin.
    @Test("an admin's agent token cannot reach an admin route")
    func adminsAgentIsStillNotAnAdmin() async throws {
        try await withServer(role: .admin, kind: .agent) { client, token in
            try await client.execute(
                uri: "/admin-only", method: .get, headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("an agent token cannot perform a destructive action")
    func agentCannotDelete() async throws {
        try await withServer(role: .admin, kind: .agent) { client, token in
            try await client.execute(
                uri: "/destructive", method: .delete, headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("a read-only agent cannot write, but a normal agent can")
    func readOnlyAgentCannotWrite() async throws {
        try await withServer(kind: .agentReadonly) { client, token in
            try await client.execute(
                uri: "/write", method: .post, headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        try await withServer(kind: .agent) { client, token in
            try await client.execute(
                uri: "/write", method: .post, headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// Errors are RFC 9457 problem documents (ticket 06), and clients branch on
    /// the stable `type` rather than the prose.
    @Test("a rejection is an RFC 9457 problem document")
    func rejectionIsAProblemDocument() async throws {
        try await withServer { client, _ in
            try await client.execute(uri: "/whoami", method: .get) { response in
                #expect(
                    response.headers[.contentType]?.contains("application/problem+json") == true)

                let problem = try JSONCoders.decoder.decode(
                    Problem.self, from: Data(buffer: response.body))
                #expect(problem.status == 401)
                #expect(problem.type.isEmpty == false)
            }
        }
    }

    /// The agent restrictions above are only half the contract. A capability
    /// profile that quietly locked out humans would pass every one of those tests
    /// and break the product.
    @Test("a human member can write and delete")
    func humanMemberCanWriteAndDelete() async throws {
        try await withServer(role: .member, kind: .human) { client, token in
            try await client.execute(
                uri: "/write", method: .post, headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/destructive", method: .delete,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("a human admin can write and delete too")
    func humanAdminCanWriteAndDelete() async throws {
        try await withServer(role: .admin, kind: .human) { client, token in
            try await client.execute(
                uri: "/write", method: .post, headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/destructive", method: .delete,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
