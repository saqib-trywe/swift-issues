import Core
import Foundation
import Testing

@Suite("HTTP values")
struct HTTPTests {

    @Test("identical requests are equal and hash alike")
    func identicalRequestsAreEqual() {
        let one = HTTPRequest(
            method: "PATCH", path: "/api/v1/issues/x",
            query: [(name: "expand", value: "labels")],
            headers: ["Authorization": "Bearer t"], body: Data("{}".utf8))
        let two = HTTPRequest(
            method: "PATCH", path: "/api/v1/issues/x",
            query: [(name: "expand", value: "labels")],
            headers: ["Authorization": "Bearer t"], body: Data("{}".utf8))

        #expect(one == two)
        #expect(one.hashValue == two.hashValue)
    }

    /// Query equality is order-sensitive by design: endpoint tests assert the
    /// exact query a call produces, and treating a reordering as equal would let
    /// a genuine change pass unnoticed.
    @Test("query order is significant")
    func queryOrderIsSignificant() {
        let ascending = HTTPRequest(
            method: "GET", path: "/x",
            query: [(name: "a", value: "1"), (name: "b", value: "2")])
        let descending = HTTPRequest(
            method: "GET", path: "/x",
            query: [(name: "b", value: "2"), (name: "a", value: "1")])

        #expect(ascending != descending)
    }

    @Test("requests differing only in body are not equal")
    func bodyIsSignificant() {
        let empty = HTTPRequest(method: "PUT", path: "/x")
        let filled = HTTPRequest(method: "PUT", path: "/x", body: Data("{}".utf8))

        #expect(empty != filled)
    }

    @Test("a 204 with no body is a success that yields no value")
    func noContentIsSuccess() throws {
        try HTTPResponse(status: 204).discardingValue()
    }

    @Test("a failure still throws when no value is expected")
    func failureThrowsWithoutValue() {
        #expect(throws: APIError.gone(nil)) {
            try HTTPResponse(status: 410).discardingValue()
        }
    }

    /// A status we have no classification for must surface as itself rather than
    /// being lumped into a neighbouring case.
    @Test("an unclassified status surfaces with its code")
    func unclassifiedStatusSurfaces() {
        #expect(throws: APIError.unexpectedStatus(302)) {
            try HTTPResponse(status: 302).discardingValue()
        }
    }

    @Test("a decoded value is reachable from the instance method too")
    func instanceDecodeWorks() throws {
        let response = HTTPResponse(status: 200, body: Data(#""PROJ""#.utf8))

        #expect(try response.decoded(ProjectKey.self) == ProjectKey("PROJ"))
    }

    @Test("a Problem can be constructed directly, carrying field failures")
    func problemCarriesFieldFailures() {
        let problem = Problem(
            type: "about:blank", title: "Invalid", status: 422,
            detail: "One field failed.",
            errors: [ValidationFailure(field: "title", code: .required, message: "Required.")])

        #expect(problem.detail == "One field failed.")
        #expect(problem.errors?.count == 1)
    }
}
