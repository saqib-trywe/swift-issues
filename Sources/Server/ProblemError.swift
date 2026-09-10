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

    public init(
        status: HTTPResponse.Status,
        type: String,
        title: String,
        detail: String? = nil,
        errors: [ValidationFailure]? = nil
    ) {
        self.status = status
        self.problem = Problem(
            type: type, title: title, status: status.code, detail: detail, errors: errors)
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

    /// No such id. Distinct from `gone`, which means it existed and was deleted.
    public static func notFound(detail: String? = nil) -> ProblemError {
        ProblemError(
            status: .notFound, type: base + "not-found", title: "Not found", detail: detail)
    }

    /// It existed and is gone. A CLI gives this its own exit code (ticket 11), so
    /// collapsing it into `notFound` would lose a distinction users see.
    public static func gone(detail: String? = nil) -> ProblemError {
        ProblemError(status: .gone, type: base + "gone", title: "Gone", detail: detail)
    }

    /// A conflicting record already exists — for instance re-creating an id with
    /// different content, which PUT treats as a conflict rather than an overwrite.
    public static func conflict(detail: String? = nil) -> ProblemError {
        ProblemError(
            status: .conflict, type: base + "conflict", title: "Conflict", detail: detail)
    }

    /// Field-level validation failures, carried as the `errors` extension member
    /// so clients branch on a stable code rather than the prose.
    public static func invalid(_ failures: [ValidationFailure]) -> ProblemError {
        ProblemError(
            status: .unprocessableContent, type: base + "invalid-request",
            title: "Invalid request", detail: "One or more fields are invalid.",
            errors: failures)
    }
}
