import Core
import Foundation
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

/// Ticket 06 makes RFC 9457 the contract for failures. A client that learned to
/// read problem details should never meet a second error shape.
@Suite("Every error is a problem document")
struct ProblemShapeTests {

    private func withClient(
        _ body: @Sendable @escaping (any TestClientProtocol, HTTPFields) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .admin)
        try UserRepository(database: database).save(user)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: nil)
        let headers: HTTPFields = [
            .authorization: "Bearer \(token.raw)", .contentType: "application/json",
        ]
        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in try await body(client, headers) }
    }

    private func problem(_ response: TestResponse) throws -> Problem {
        try JSONCoders.decoder.decode(Problem.self, from: Data(buffer: response.body))
    }

    /// The one that was actually wrong: a body that will not decode came back as
    /// Hummingbird's `{"error":{"message":...}}`.
    @Test("a body that will not decode is a problem document")
    func malformedBodyIsAProblem() async throws {
        try await withClient { client, headers in
            let id = UUID().uuidString
            try await client.execute(
                uri: "/api/v1/issues/\(id)", method: .put, headers: headers,
                body: ByteBuffer(string: #"{"title":"No other fields"}"#)
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.headers[.contentType] == "application/problem+json")

                let problem = try self.problem(response)
                #expect(problem.status == 400)
                #expect(problem.type.hasSuffix("malformed-request"))
                // The most useful sentence anyone will write about a bad body is
                // the one naming the field, so it is passed through.
                #expect(problem.detail?.isEmpty == false)
            }
        }
    }

    /// Distinct types, because the two call for different fixes: one body did not
    /// parse, the other parsed and then failed validation.
    @Test("a body that parses and fails validation is a different type")
    func validationIsADifferentType() async throws {
        try await withClient { client, headers in
            let project = UUID().uuidString
            try await client.execute(
                uri: "/api/v1/projects/\(project)", method: .put, headers: headers,
                // A key that parses. An invalid one never reaches validation: the
                // wire types refuse it while decoding, which is its own answer.
                body: ByteBuffer(string: #"{"key":"PROJ","name":"","description":""}"#)
            ) { response in
                let problem = try self.problem(response)
                #expect(problem.type.hasSuffix("invalid-request"))
                #expect(problem.type != ProblemError.base + "malformed-request")
            }
        }
    }

    @Test("an unmatched path is a problem document, not an empty body")
    func unmatchedPathIsAProblem() async throws {
        try await withClient { client, headers in
            try await client.execute(
                uri: "/api/v1/nothing-here", method: .get, headers: headers
            ) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[.contentType] == "application/problem+json")
                let problem = try self.problem(response)
                #expect(problem.status == 404)
            }
        }
    }

    /// The route is real; the method is not. Previously an empty 404 as well.
    @Test("a wrong method on a real path is a problem document")
    func wrongMethodIsAProblem() async throws {
        try await withClient { client, headers in
            try await client.execute(uri: "/api/v1/meta", method: .delete, headers: headers) {
                response in
                #expect(response.headers[.contentType] == "application/problem+json")
            }
        }
    }

    /// Deliberate failures must pass through untouched — the middleware translates,
    /// it does not re-label.
    @Test("a thrown problem keeps its own type and detail")
    func deliberateProblemsAreUntouched() async throws {
        try await withClient { client, headers in
            let missing = UUID().uuidString
            try await client.execute(
                uri: "/api/v1/issues/\(missing)", method: .get, headers: headers
            ) { response in
                #expect(response.status == .notFound)
                let problem = try self.problem(response)
                #expect(problem.type.hasSuffix("not-found"))
            }
        }
    }

    @Test("an unauthenticated request is still a problem document")
    func unauthenticatedIsAProblem() async throws {
        try await withClient { client, _ in
            try await client.execute(uri: "/api/v1/meta", method: .get) { response in
                #expect(response.status == .unauthorized)
                #expect(response.headers[.contentType] == "application/problem+json")
                let problem = try self.problem(response)
                #expect(problem.type.hasSuffix("unauthenticated"))
            }
        }
    }

    // MARK: The translation on its own

    @Test(
        "each status keeps itself and gains a stable type",
        arguments: [
            (HTTPResponse.Status.notFound, "not-found"),
            (.unauthorized, "unauthenticated"),
            (.forbidden, "forbidden"),
            (.gone, "gone"),
            (.conflict, "conflict"),
            (.badRequest, "malformed-request"),
            (.internalServerError, "error"),
        ])
    func statusesMap(status: HTTPResponse.Status, slug: String) {
        let problem = ProblemMiddleware.problem(for: HTTPError(status, message: "the reason"))

        #expect(problem.status == status)
        #expect(problem.problem.type.hasSuffix(slug))
        #expect(problem.problem.detail == "the reason")
    }

    /// A status with no message still needs a readable document, since a client may
    /// show `detail` directly.
    @Test("a message-less error still says something")
    func messagelessErrorStillSaysSomething() {
        #expect(ProblemMiddleware.problem(for: HTTPError(.notFound)).problem.detail?.isEmpty == false)
        #expect(ProblemMiddleware.problem(for: HTTPError(.badRequest)).problem.detail?.isEmpty == false)
    }
}
