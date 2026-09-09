import Core
import Foundation
import Testing

@Suite("Response interpretation")
struct ResponseInterpretationTests {

    private func response(_ status: Int, _ body: String, headers: [String: String] = [:])
        -> HTTPResponse
    {
        HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
    }

    private func problem(_ type: String, _ status: Int) -> String {
        #"{"type":"\#(type)","title":"Nope","status":\#(status)}"#
    }

    @Test("a 200 decodes into the expected value")
    func successDecodes() throws {
        let decoded = try HTTPResponse.value(
            ProjectKey.self, from: response(200, #""PROJ""#))

        #expect(decoded == ProjectKey("PROJ"))
    }

    /// 410 must not collapse into 404. "This existed and is gone" is a different
    /// message from "no such id", and ticket 11 gives them different CLI exit
    /// codes, so the distinction has to survive this layer.
    @Test("410 is distinct from 404")
    func goneIsDistinctFromNotFound() {
        #expect(throws: APIError.gone(nil)) {
            try HTTPResponse.value(Project.self, from: response(410, ""))
        }
        #expect(throws: APIError.notFound(nil)) {
            try HTTPResponse.value(Project.self, from: response(404, ""))
        }
    }

    /// 401 means "your session is not valid" and 403 means "your session is fine
    /// but you may not do this". Conflating them would send a user to re-login
    /// over a permissions problem — and, per ADR 0006, a 401 mid-sync must
    /// preserve the pending queue while a 403 must not.
    @Test("401 and 403 are distinct")
    func unauthenticatedIsDistinctFromForbidden() {
        #expect(throws: APIError.unauthenticated(nil)) {
            try HTTPResponse.value(Project.self, from: response(401, ""))
        }
        #expect(throws: APIError.forbidden(nil)) {
            try HTTPResponse.value(Project.self, from: response(403, ""))
        }
    }

    @Test("409 surfaces as a conflict")
    func conflictSurfaces() {
        #expect(throws: APIError.conflict(nil)) {
            try HTTPResponse.value(Project.self, from: response(409, ""))
        }
    }

    @Test("an RFC 9457 body is decoded and attached to the error")
    func problemIsAttached() throws {
        let thrown = #expect(throws: APIError.self) {
            try HTTPResponse.value(
                Project.self,
                from: response(404, problem("https://example.test/not-found", 404)))
        }

        guard case .notFound(let problem) = try #require(thrown) else {
            Issue.record("expected notFound")
            return
        }
        #expect(problem?.type == "https://example.test/not-found")
        #expect(problem?.title == "Nope")
    }

    /// Validation failures arrive as the `errors` extension member, and clients
    /// branch on the stable code rather than the prose.
    @Test("field-level validation failures survive into the error")
    func validationFailuresSurvive() throws {
        let body = """
            {"type":"about:blank","title":"Invalid","status":422,
             "errors":[{"field":"title","code":"required","message":"A title is required."}]}
            """
        let thrown = #expect(throws: APIError.self) {
            try HTTPResponse.value(Project.self, from: response(422, body))
        }

        guard case .invalidRequest(let problem) = try #require(thrown) else {
            Issue.record("expected invalidRequest")
            return
        }
        #expect(problem?.errors?.first?.code == .required)
        #expect(problem?.errors?.first?.field == "title")
    }

    /// Ticket 12 requires agents to honour Retry-After rather than retry through
    /// it, so the value has to reach them rather than being discarded.
    @Test("429 carries Retry-After")
    func rateLimitedCarriesRetryAfter() throws {
        let thrown = #expect(throws: APIError.self) {
            try HTTPResponse.value(
                Project.self, from: response(429, "", headers: ["Retry-After": "720"]))
        }

        guard case .rateLimited(let retryAfter, _) = try #require(thrown) else {
            Issue.record("expected rateLimited")
            return
        }
        #expect(retryAfter == 720)
    }

    @Test("a 5xx is reported as a server error carrying its status")
    func serverErrorCarriesStatus() throws {
        let thrown = #expect(throws: APIError.self) {
            try HTTPResponse.value(Project.self, from: response(503, ""))
        }

        guard case .server(let status, _) = try #require(thrown) else {
            Issue.record("expected server")
            return
        }
        #expect(status == 503)
    }

    /// An error body that is not problem+json must not mask the status. Servers
    /// behind a proxy return HTML error pages, and losing the status there would
    /// turn a 502 into an unexplained decode failure.
    @Test("a non-problem error body still yields the right error case")
    func nonProblemBodyStillClassifies() {
        #expect(throws: APIError.notFound(nil)) {
            try HTTPResponse.value(Project.self, from: response(404, "<html>Not Found</html>"))
        }
    }
}
