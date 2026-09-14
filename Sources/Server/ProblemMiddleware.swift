import Core
import Foundation
import Hummingbird

/// Makes every error leave as an RFC 9457 problem document.
///
/// Ticket 06 makes problem details the contract for failures, and everything the
/// routes throw deliberately is already a `ProblemError`. The gap is the errors
/// nobody throws on purpose: a body that will not decode, or a path that matches no
/// route, are raised by Hummingbird as `HTTPError` and render as
/// `{"error":{"message":"..."}}` — a second error shape a client would have to know
/// about, discovered by hand-rolling a `PUT` with curl.
///
/// This is a translation, not a catch-all: the status and message are preserved
/// exactly as they were raised.
struct ProblemMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let problem as ProblemError {
            throw problem
        } catch let error as HTTPError {
            throw Self.problem(for: error)
        }
    }

    /// Keeps the status and the message, and gives the client a stable `type` to
    /// branch on.
    ///
    /// The message is passed through rather than replaced: "Coding key `labelIds`
    /// not found" is the most useful sentence anyone will produce about a malformed
    /// body, and it describes the request rather than the server's internals.
    static func problem(for error: HTTPError) -> ProblemError {
        let detail = error.body

        switch error.status {
        case .notFound:
            return .notFound(detail: detail ?? "No route matches this path.")
        case .unauthorized:
            return .unauthenticated(detail: detail)
        case .forbidden:
            return .forbidden(detail: detail)
        case .gone:
            return .gone(detail: detail)
        case .conflict:
            return .conflict(detail: detail)
        case .badRequest:
            return ProblemError(
                status: .badRequest, type: ProblemError.base + "malformed-request",
                title: "Malformed request",
                // Distinct from `invalid-request`, which means the fields parsed and
                // then failed validation. This one did not parse at all, and the two
                // call for different fixes.
                detail: detail ?? "The request body could not be read.")
        default:
            return ProblemError(
                status: error.status, type: ProblemError.base + "error",
                title: error.status.reasonPhrase, detail: detail)
        }
    }
}
