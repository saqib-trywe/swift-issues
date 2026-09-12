import Core
import Foundation
import Hummingbird

extension TokenIssued: ResponseEncodable {}
extension SessionSummary: ResponseEncodable {}

/// Personal access tokens: listing, minting and revoking.
///
/// There is no web UI, so this is the only place a token can be managed from
/// (ticket 07). The rules here are the ones that keep ADR 0007's agent profile
/// meaningful.
struct TokenRoutes: Sendable {
    let database: AppDatabase
    // No hasher: verification uses the static `PasswordHasher.verify`, which reads
    // its parameters from the stored hash. Nothing here ever hashes.

    var sessions: SessionRepository { SessionRepository(database: database) }

    func register(on group: RouterGroup<AppRequestContext>) {
        group.get("/auth/tokens") { _, context in
            // Your own tokens only. An Admin reviewing somebody else's uses
            // `/users/:id/tokens` below, which is an explicit act rather than a
            // side effect of listing.
            try EditedResponse(
                status: .ok,
                response: Paginated(
                    items: try sessions.list(for: context.identity.userId), nextCursor: nil))
        }

        group.get("/users/:id/tokens") { _, context in
            let id = try context.userID()
            guard context.identity.userId == id || (try? context.require(.admin)) != nil else {
                throw ProblemError.forbidden(
                    detail: "You may only list your own tokens.")
            }
            return try EditedResponse(
                status: .ok,
                response: Paginated(items: try sessions.list(for: id), nextCursor: nil))
        }

        group.post("/auth/tokens") { request, context in
            // An agent must never mint a token. An agent that could issue a
            // human-kind token would escape ADR 0007's profile entirely, by simply
            // granting itself its owner's full authority.
            guard context.identity.kind == .human else {
                throw ProblemError.forbidden(detail: "An agent token may not mint tokens.")
            }

            let body = try await request.decode(as: TokenRequest.self, context: context)

            // The password is required even though the caller already holds a valid
            // token. Without it, a leaked token could mint children and revoking
            // the original would leave them working — the compromise would outlive
            // the revocation.
            guard
                let stored = try UserRepository(database: database)
                    .credentials(forId: context.identity.userId),
                try PasswordHasher.verify(body.password, against: stored)
            else {
                throw ProblemError.forbidden(detail: "That password is not correct.")
            }

            // An unrecognised kind would be stored verbatim and then grant no
            // capabilities at all, producing a token that authenticates and can do
            // nothing — confusing rather than safe. Refused at the door instead.
            guard body.kind.isHuman != nil else {
                throw ProblemError.invalid([
                    ValidationFailure(
                        field: "kind", code: .invalid,
                        message:
                            "Unknown token kind '\(body.kind.wireValue)'. Known kinds: "
                            + TokenKind.known.map(\.wireValue).joined(separator: ", ") + ".")
                ])
            }

            let issued = try sessions.create(
                for: context.identity.userId, kind: body.kind,
                deviceId: body.deviceId, label: body.label)

            guard let summary = try sessions.find(id: issued.id) else {
                throw ProblemError.notFound(detail: "The token was created but could not be read.")
            }
            // 201 with the raw token, which exists in this response and nowhere else.
            return try EditedResponse(
                status: .created, response: TokenIssued(token: issued.raw, session: summary))
        }

        group.delete("/auth/tokens/:tokenId") { _, context in
            guard let raw = context.parameters.get("tokenId"), let uuid = UUID(uuidString: raw) else {
                throw ProblemError.notFound(detail: "No such token.")
            }
            let id = SessionSummary.ID(uuid)

            guard let summary = try sessions.find(id: id) else {
                throw ProblemError.notFound(detail: "No such token.")
            }
            // An Admin may revoke anybody's — that is how a departing colleague or a
            // leaked token is dealt with. Anybody else, only their own.
            guard
                summary.userId == context.identity.userId
                    || (try? context.require(.admin)) != nil
            else {
                throw ProblemError.forbidden(detail: "You may only revoke your own tokens.")
            }

            guard try sessions.revoke(id: id) else {
                // Already revoked. Reported as gone rather than as success, so a
                // script can tell "I revoked it" from "somebody already had".
                throw ProblemError.gone(detail: "That token was already revoked.")
            }
            return HTTPResponse.Status.noContent
        }
    }
}
