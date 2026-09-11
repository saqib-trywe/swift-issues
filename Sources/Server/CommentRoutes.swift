import Core
import Foundation
import Hummingbird

/// Routes for the Comment resource.
///
/// The collection is nested under its Issue; the individual resource is top-level,
/// matching how Issues are addressed.
struct CommentRoutes: Sendable {
    let database: AppDatabase

    var repository: CommentRepository { CommentRepository(database: database) }

    func register(on group: RouterGroup<AppRequestContext>) {
        group.get("/issues/:reference/comments") { _, context in
            guard let raw = context.parameters.get("reference"), let uuid = UUID(uuidString: raw)
            else { throw ProblemError.notFound(detail: "No such issue.") }
            return try EditedResponse(
                status: .ok,
                response: Paginated(
                    items: try repository.thread(for: Issue.ID(uuid)), nextCursor: nil))
        }

        group.get("/comments/:id") { _, context in
            try EditedResponse(status: .ok, response: try resolve(context))
        }

        group.put("/comments/:id") { request, context in
            try context.requireCapability(.write)
            let id = try context.commentID()
            let body = try await request.decode(as: CommentCreate.self, context: context)

            let failures = Validation.comment(body: body.body)
            guard failures.isEmpty else { throw ProblemError.invalid(failures) }

            if let existing = try repository.find(id) {
                guard existing.deletedAt == nil else {
                    throw ProblemError.gone(detail: "That comment was deleted.")
                }
                guard existing.body == body.body, existing.issueId == body.issueId else {
                    throw ProblemError.conflict(
                        detail: "That id already exists with different content.")
                }
                return try EditedResponse(status: .ok, response: existing)
            }

            let now = Date()
            let comment = Comment(
                id: id,
                issueId: body.issueId,
                // From the token, never the body.
                authorId: context.identity.userId,
                body: body.body,
                via: context.identity.kind == .human ? .human : .agent,
                createdAt: now,
                updatedAt: now
            )
            do {
                try repository.save(comment)
            } catch {
                // A reference the server has not seen is rejected outright
                // (ticket 08) rather than stored as a dangling row.
                throw ProblemError.notFound(detail: "No such issue.")
            }
            return try EditedResponse(status: .created, response: comment)
        }

        group.patch("/comments/:id") { request, context in
            try context.requireCapability(.write)
            var existing = try resolve(context)

            // Ticket 01: edit is author-only, Admin included. Rewriting someone
            // else's words in a discussion thread is a trust problem, not a
            // permissions one.
            guard existing.authorId == context.identity.userId else {
                throw ProblemError.forbidden(detail: "Only the author can edit a comment.")
            }

            let patch = try await request.decode(as: CommentPatch.self, context: context)
            if case .set(let body) = patch.body {
                let failures = Validation.comment(body: body)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
                existing.body = body
                // Surfaced as "edited": silent edits in a thread are a trust problem.
                existing.updatedAt = Date()
            }

            try repository.save(existing)
            return try EditedResponse(status: .ok, response: existing)
        }

        group.delete("/comments/:id") { _, context in
            try context.requireCapability(.destructive)
            let existing = try resolve(context)

            // Ticket 01: delete is author or Admin — wider than edit, because
            // removing an intemperate remark is moderation rather than forgery.
            guard
                existing.authorId == context.identity.userId
                    || context.identity.role == .admin
            else {
                throw ProblemError.forbidden(
                    detail: "Only the author or an Admin can delete a comment.")
            }

            try repository.delete(existing.id, at: Date())
            return Response(status: .noContent)
        }
    }

    private func resolve(_ context: AppRequestContext) throws -> Comment {
        guard let comment = try repository.find(try context.commentID()) else {
            throw ProblemError.notFound(detail: "No such comment.")
        }
        guard comment.deletedAt == nil else {
            throw ProblemError.gone(detail: "That comment was deleted.")
        }
        return comment
    }
}

extension AppRequestContext {
    func commentID() throws -> Comment.ID {
        guard let raw = parameters.get("id"), let uuid = UUID(uuidString: raw) else {
            throw ProblemError.notFound(detail: "No such comment.")
        }
        return Comment.ID(uuid)
    }
}
