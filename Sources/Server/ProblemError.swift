import Core
import Foundation
import Hummingbird

/// An error that renders as an RFC 9457 problem document.
///
/// Every endpoint reports failures this way (ticket 06). The `type` is a stable
/// slug clients branch on; the prose is for humans and may change.
public struct ProblemError: Error, HTTPResponseError {
    public let status: HTTPResponse.Status
    public let problem: Problem

    public init(status: HTTPResponse.Status, type: String, title: String, detail: String? = nil) {
        self.status = status
        self.problem = Problem(
            type: type, title: title, status: status.code, detail: detail)
    }

    public func response(from request: Request, context: some RequestContext) throws -> Response {
        var headers: HTTPFields = [:]
        headers[.contentType] = "application/problem+json"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: .init(data: try JSONCoders.encoder.encode(problem)))
        )
    }

    static let base = "https://trywe.co.uk/problems/"

    /// No usable credentials. Distinct from `forbidden`: per ADR 0006 a 401
    /// mid-sync preserves the client's pending queue and prompts re-login.
    public static func unauthenticated(detail: String? = nil) -> ProblemError {
        ProblemError(
            status: .unauthorized, type: base + "unauthenticated",
            title: "Authentication required", detail: detail)
    }

    /// Valid credentials, insufficient authority. Must not send a user to
    /// re-login.
    public static func forbidden(detail: String? = nil) -> ProblemError {
        ProblemError(
            status: .forbidden, type: base + "forbidden", title: "Not permitted", detail: detail)
    }
}
