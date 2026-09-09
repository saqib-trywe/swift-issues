import Core
import Foundation
import TestSupport
import Testing

@Suite("APIClient")
struct APIClientTests {

    private let issueId = Core.Issue.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000020")!)

    @Test("attaches the bearer token and asks for JSON")
    func attachesBearerToken() async throws {
        let transport = FakeTransport.returning(status: 200, json: #""PROJ""#)
        let client = APIClient(transport: transport, token: { "tok_123" })

        _ = try await client.send(IssueEndpoints.get(.id(issueId)), expecting: ProjectKey.self)

        let sent = try #require(await transport.requests.first)
        #expect(sent.headers["Authorization"] == "Bearer tok_123")
        #expect(sent.headers["Accept"] == "application/json")
    }

    /// `/health` is unauthenticated (ticket 06), so a client with no token must
    /// still be able to call it rather than sending an empty Authorization header.
    @Test("omits the Authorization header entirely when there is no token")
    func omitsAuthorizationWithoutToken() async throws {
        let transport = FakeTransport.returning(status: 200, json: #""PROJ""#)
        let client = APIClient(transport: transport, token: { nil })

        _ = try await client.send(IssueEndpoints.get(.id(issueId)), expecting: ProjectKey.self)

        let sent = try #require(await transport.requests.first)
        #expect(sent.headers["Authorization"] == nil)
    }

    /// The token is fetched per request, not captured once: a session can be
    /// replaced by re-login while a client instance lives on.
    @Test("reads the token afresh for each request")
    func readsTokenPerRequest() async throws {
        let tokens = TokenSequence(["first", "second"])
        let transport = FakeTransport.returning(status: 200, json: #""PROJ""#)
        let client = APIClient(transport: transport, token: { await tokens.next() })

        _ = try await client.send(IssueEndpoints.get(.id(issueId)), expecting: ProjectKey.self)
        _ = try await client.send(IssueEndpoints.get(.id(issueId)), expecting: ProjectKey.self)

        let sent = await transport.requests
        #expect(sent.map { $0.headers["Authorization"] } == ["Bearer first", "Bearer second"])
    }

    @Test("decodes a successful response")
    func decodesSuccess() async throws {
        let transport = FakeTransport.returning(status: 200, json: #""PROJ""#)
        let client = APIClient(transport: transport, token: { "t" })

        let key = try await client.send(
            IssueEndpoints.get(.id(issueId)), expecting: ProjectKey.self)

        #expect(key == ProjectKey("PROJ"))
    }

    @Test("surfaces a failure status as a typed APIError")
    func surfacesTypedError() async {
        let transport = FakeTransport.returning(status: 410, json: "")
        let client = APIClient(transport: transport, token: { "t" })

        await #expect(throws: APIError.gone(nil)) {
            try await client.send(IssueEndpoints.get(.id(issueId)), expecting: Core.Issue.self)
        }
    }

    @Test("a call expecting no value still checks the status")
    func voidCallChecksStatus() async throws {
        let ok = APIClient(transport: FakeTransport.returning(status: 204), token: { "t" })
        try await ok.send(IssueEndpoints.delete(issueId))

        let failing = APIClient(transport: FakeTransport.returning(status: 403), token: { "t" })
        await #expect(throws: APIError.forbidden(nil)) {
            try await failing.send(IssueEndpoints.delete(issueId))
        }
    }

    /// The fake records what it was asked for, which is what makes endpoint
    /// assertions possible end-to-end rather than only against a builder.
    @Test("the fake transport records every request it received, in order")
    func fakeRecordsRequests() async throws {
        let transport = FakeTransport.returning(status: 204)
        let client = APIClient(transport: transport, token: { "t" })

        try await client.send(IssueEndpoints.delete(issueId))
        try await client.send(IssueEndpoints.delete(issueId))

        #expect(await transport.requests.count == 2)
        #expect(await transport.requests.allSatisfy { $0.method == "DELETE" })
    }

    /// A responder lets a test vary by request, which the sync harness in
    /// ticket 13 will need.
    @Test("the fake can respond differently per request")
    func fakeCanVaryByRequest() async throws {
        let transport = FakeTransport { request in
            request.method == "DELETE"
                ? HTTPResponse(status: 204)
                : HTTPResponse(status: 200, body: Data(#""PROJ""#.utf8))
        }
        let client = APIClient(transport: transport, token: { "t" })

        try await client.send(IssueEndpoints.delete(issueId))
        let key = try await client.send(
            IssueEndpoints.get(.id(issueId)), expecting: ProjectKey.self)

        #expect(key == ProjectKey("PROJ"))
    }
}

/// A tiny helper for the per-request token test.
private actor TokenSequence {
    private var values: [String]
    init(_ values: [String]) { self.values = values }
    func next() -> String? { values.isEmpty ? nil : values.removeFirst() }
}
