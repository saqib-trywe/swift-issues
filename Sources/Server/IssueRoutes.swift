import Core
import Foundation
import Hummingbird

/// Routes for the Issue resource.
struct IssueRoutes: Sendable {
    let database: AppDatabase

    var repository: IssueRepository { IssueRepository(database: database) }

    func register(on group: RouterGroup<AppRequestContext>) {
        group.get("/issues") { request, context in
            let query = request.uri.queryParameters
            return try EditedResponse(
                status: .ok,
                response: try repository.list(
                    filter: IssueFilter(query: query),
                    sort: IssueSort(wireValue: query["sort"[...]].map(String.init)),
                    page: Pagination(query: query),
                    resolvingMeAs: context.identity.userId
                ))
        }

        // Accepts a UUID or an Issue Key: humans and agents hold keys, not UUIDs,
        // and without this every CLI and MCP call needs a lookup round trip first.
        group.get("/issues/:reference") { _, context in
            let issue = try resolve(context)
            return try EditedResponse(status: .ok, response: issue)
        }

        group.put("/issues/:reference") { request, context in
            try context.requireCapability(.write)
            let id = try context.issueID()
            let body = try await request.decode(as: IssueCreate.self, context: context)

            let failures = Validation.issue(title: body.title, description: body.description)
            guard failures.isEmpty else { throw ProblemError.invalid(failures) }

            // Create-only. A repeated identical PUT is the retry an offline client
            // makes when it never saw a response, and must not create twice.
            if let existing = try repository.find(id) {
                guard existing.deletedAt == nil else {
                    throw ProblemError.gone(detail: "That issue was deleted.")
                }
                guard existing.title == body.title, existing.projectId == body.projectId,
                    existing.description == body.description
                else {
                    throw ProblemError.conflict(
                        detail: "That id already exists with different content.")
                }
                return try EditedResponse(status: .ok, response: existing)
            }

            let now = Date()
            let issue = Issue(
                id: id,
                key: nil,  // assigned by the repository from the project's counter
                projectId: body.projectId,
                title: body.title,
                description: body.description,
                status: body.status,
                priority: body.priority,
                // From the token, never the body: the reporter is the authenticated
                // caller and is immutable thereafter.
                reporterId: context.identity.userId,
                assigneeId: body.assigneeId,
                dueDate: body.dueDate,
                // Also from the token. This is the whole point of `via`: answering
                // "which of these did the bot file?" (ADR 0007).
                via: context.identity.kind == .human ? .human : .agent,
                createdAt: now,
                updatedAt: now
            )
            return try EditedResponse(status: .created, response: try repository.create(issue))
        }

        group.patch("/issues/:reference") { request, context in
            try context.requireCapability(.write)
            let existing = try resolve(context)
            let patch = try await request.decode(as: IssuePatch.self, context: context)

            if case .set(let title) = patch.title {
                let failures = Validation.title(title)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
            }
            if case .set(let description) = patch.description {
                let failures = Validation.description(description)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
            }

            guard let updated = try repository.apply(patch, to: existing.id, at: Date()) else {
                throw ProblemError.notFound(detail: "No such issue.")
            }
            return try EditedResponse(status: .ok, response: updated)
        }

        group.delete("/issues/:reference") { _, context in
            // Agents never get this: an agent looping on a misparsed instruction is
            // exactly the actor not to hand an irreversible tombstone to (ADR 0007).
            try context.requireCapability(.destructive)
            let existing = try resolve(context)

            // Ticket 01: reporter or Admin. A Member who did not report it has the
            // `cancelled` status as their normal "make it go away" path.
            guard
                existing.reporterId == context.identity.userId
                    || context.identity.role == .admin
            else {
                throw ProblemError.forbidden(
                    detail: "Only the reporter or an Admin can delete an issue.")
            }

            try repository.delete(existing.id, at: Date())
            return Response(status: .noContent)
        }
    }

    /// Resolves `:reference` as an id or an Issue Key, answering 410 for a
    /// tombstone and 404 for something that never existed. Keys are never reused,
    /// so a deleted issue's key still resolves — to the 410.
    private func resolve(_ context: AppRequestContext) throws -> Issue {
        // The router guarantees the parameter when the pattern matched, so an
        // empty fallback simply fails the parse below rather than needing a branch
        // no test could reach.
        let raw = context.parameters.get("reference") ?? ""

        let found: Issue? =
            if let uuid = UUID(uuidString: raw) {
                try repository.find(Issue.ID(uuid))
            } else if let key = IssueKey(raw) {
                try repository.find(key: key)
            } else {
                nil
            }

        guard let issue = found else { throw ProblemError.notFound(detail: "No such issue.") }
        guard issue.deletedAt == nil else {
            throw ProblemError.gone(detail: "That issue was deleted.")
        }
        return issue
    }
}

extension AppRequestContext {
    /// A write addresses an Issue by id only: a key is server-assigned, so a client
    /// creating one offline does not have it yet.
    func issueID() throws -> Issue.ID {
        guard let raw = parameters.get("reference"), let uuid = UUID(uuidString: raw) else {
            throw ProblemError.notFound(detail: "An issue is written by id, not by key.")
        }
        return Issue.ID(uuid)
    }
}
