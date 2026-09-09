import Core
import Foundation
import Testing

@Suite("URLRequest mapping")
struct URLRequestMappingTests {

    private let base = URL(string: "https://issues.example.test")!

    @Test("composes the base URL and the request path")
    func composesURL() throws {
        let request = try URLRequest(
            HTTPRequest(method: "GET", path: "/api/v1/issues"), relativeTo: base)

        #expect(request.url?.absoluteString == "https://issues.example.test/api/v1/issues")
    }

    /// A trailing slash on the configured base URL is the single most likely
    /// misconfiguration, and it must not produce a double slash.
    @Test("a trailing slash on the base URL does not double up")
    func trailingSlashDoesNotDouble() throws {
        let request = try URLRequest(
            HTTPRequest(method: "GET", path: "/api/v1/issues"),
            relativeTo: URL(string: "https://issues.example.test/")!)

        #expect(request.url?.absoluteString == "https://issues.example.test/api/v1/issues")
    }

    /// A self-hoster may serve the API under a sub-path behind a proxy.
    @Test("a base URL with a path prefix is preserved")
    func pathPrefixIsPreserved() throws {
        let request = try URLRequest(
            HTTPRequest(method: "GET", path: "/api/v1/issues"),
            relativeTo: URL(string: "https://example.test/issues")!)

        #expect(request.url?.absoluteString == "https://example.test/issues/api/v1/issues")
    }

    /// The `q` filter carries arbitrary user text, so anything that is not
    /// percent-encoded here becomes a broken or ambiguous URL.
    @Test("query values are percent-encoded")
    func queryValuesAreEncoded() throws {
        let request = try URLRequest(
            HTTPRequest(
                method: "GET", path: "/api/v1/issues",
                query: [(name: "q", value: "index & sort=1"), (name: "limit", value: "50")]),
            relativeTo: base)

        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("q=index%20%26%20sort%3D1"))
        #expect(url.contains("limit=50"))
        #expect(url.contains("?"))
    }

    @Test("method, headers and body are carried across")
    func carriesMethodHeadersAndBody() throws {
        let body = Data(#"{"title":"x"}"#.utf8)
        let request = try URLRequest(
            HTTPRequest(
                method: "PATCH", path: "/api/v1/issues/x",
                headers: ["Authorization": "Bearer t", "Content-Type": "application/json"],
                body: body),
            relativeTo: base)

        #expect(request.httpMethod == "PATCH")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == body)
    }

    @Test("a request with no query has no question mark")
    func noQueryNoQuestionMark() throws {
        let request = try URLRequest(
            HTTPRequest(method: "GET", path: "/health"), relativeTo: base)

        #expect(request.url?.absoluteString.contains("?") == false)
    }
}

@Suite("HTTPResponse mapping")
struct HTTPResponseMappingTests {

    @Test("carries status, headers and body across")
    func carriesStatusHeadersAndBody() throws {
        let url = URL(string: "https://issues.example.test/api/v1/issues")!
        let raw = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "720"]))
        let body = Data("busy".utf8)

        let response = HTTPResponse(raw, body: body)

        #expect(response.status == 429)
        #expect(response.body == body)
        #expect(response.headers["Retry-After"] == "720")
    }

    /// HTTP header names are case-insensitive and the case a server sends is not
    /// ours to rely on, so Retry-After must be found whatever the casing.
    @Test("header lookup survives whatever casing the server used")
    func headerLookupIsCaseInsensitive() throws {
        let url = URL(string: "https://issues.example.test/x")!
        let raw = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["retry-after": "30"]))

        let thrown = #expect(throws: APIError.self) {
            try HTTPResponse(raw, body: Data()).discardingValue()
        }

        guard case .rateLimited(let retryAfter, _) = try #require(thrown) else {
            Issue.record("expected rateLimited")
            return
        }
        #expect(retryAfter == 30)
    }
}
