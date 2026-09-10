import Core
import Hummingbird

/// Resolves the bearer token on every request, or rejects it.
///
/// Role and capability checks are *not* done here: a route can state a Role
/// requirement declaratively, but ownership rules ("author or Admin") need the
/// record loaded and belong in the service layer. Ticket 07 splits them on exactly
/// that line.
public struct AuthenticationMiddleware: RouterMiddleware {
    public typealias Context = AppRequestContext

    let sessions: SessionRepository

    public init(sessions: SessionRepository) {
        self.sessions = sessions
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard
            let header = request.headers[.authorization],
            // The scheme matters: a bare token or Basic auth is not a bearer token.
            header.hasPrefix("Bearer "),
            case let raw = String(header.dropFirst("Bearer ".count)),
            !raw.isEmpty,
            let identity = try sessions.authenticate(raw)
        else {
            throw ProblemError.unauthenticated(
                detail: "Provide a valid token as `Authorization: Bearer <token>`.")
        }

        var context = context
        context.authenticated = identity
        return try await next(request, context)
    }
}
