import Core
import Foundation
import Hummingbird

/// Routes for Labels and their membership on Issues.
///
/// Labels are nested under their Project throughout: a Label is project-scoped by
/// definition, so a bare `/labels` would be meaningless.
struct LabelRoutes: Sendable {
    let database: AppDatabase

    var repository: LabelRepository { LabelRepository(database: database) }

    // The project parameter is named `:id` to match ProjectRoutes. Two different
    // parameter names at the same path position are a router-level conflict, not
    // merely a style inconsistency.

    func register(on group: RouterGroup<AppRequestContext>) {
        group.get("/projects/:id/labels") { _, context in
            let projectId = try context.id(Project.self, from: "id")
            return try EditedResponse(
                status: .ok,
                response: Paginated(items: try repository.all(in: projectId), nextCursor: nil))
        }

        group.put("/projects/:id/labels/:labelId") { request, context in
            try context.requireCapability(.write)
            let projectId = try context.id(Project.self, from: "id")
            let labelId = try context.id(Label.self, from: "labelId")
            let body = try await request.decode(as: LabelCreate.self, context: context)

            let failures = Validation.labelName(body.name) + Validation.labelColor(body.color)
            guard failures.isEmpty else { throw ProblemError.invalid(failures) }

            // The id must be the derived one. An invented id would let two clients
            // create the same label twice, which is exactly what ADR 0003 chose
            // derivation to prevent — so convergence is enforced, not merely hoped.
            let derived = Label.deriveID(projectId: projectId, name: body.name)
            guard labelId == derived else {
                throw ProblemError.invalid([
                    ValidationFailure(
                        field: "id", code: .required,
                        message:
                            "A label id must be derived from its project and name; expected \(derived)."
                    )
                ])
            }

            if let existing = try repository.find(labelId), existing.deletedAt == nil {
                // Two clients creating the same label offline land here: the second
                // write is the idempotent retry, not a duplicate.
                return try EditedResponse(status: .ok, response: existing)
            }

            let now = Date()
            let label = Label(
                id: derived, projectId: projectId, name: body.name, color: body.color,
                createdAt: now, updatedAt: now)
            return try EditedResponse(status: .created, response: try repository.save(label))
        }

        group.patch("/projects/:id/labels/:labelId") { request, context in
            try context.requireCapability(.write)
            var label = try resolve(context)
            let patch = try await request.decode(as: LabelPatch.self, context: context)

            if case .set(let name) = patch.name {
                let failures = Validation.labelName(name)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
                // The id deliberately does not change with the name: derivation is a
                // creation-time device, and the id is opaque thereafter (ADR 0003).
                label.name = name
            }
            if case .set(let color) = patch.color {
                let failures = Validation.labelColor(color)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
                label.color = color
            }
            label.updatedAt = Date()

            return try EditedResponse(status: .ok, response: try repository.save(label))
        }

        group.delete("/projects/:id/labels/:labelId") { _, context in
            try context.requireCapability(.destructive)
            let label = try resolve(context)
            try repository.delete(label.id, at: Date())
            return Response(status: .noContent)
        }

        // A delta rather than a replacement set, so two people concurrently adding
        // different labels both survive (ADR 0003). The link records stay internal.
        group.patch("/issues/:reference/labels") { request, context in
            try context.requireCapability(.write)
            let issueId = try context.id(Issue.self, from: "reference")
            guard let issue = try IssueRepository(database: database).find(issueId),
                issue.deletedAt == nil
            else {
                throw ProblemError.notFound(detail: "No such issue.")
            }

            let delta = try await request.decode(as: LabelDelta.self, context: context)
            let now = Date()

            for labelId in delta.add {
                // A Label belongs to one Project, and applying it outside that
                // Project would let project-scoped labels leak between projects.
                guard let label = try repository.find(labelId), label.deletedAt == nil else {
                    throw ProblemError.invalid([
                        ValidationFailure(
                            field: "add", code: .required,
                            message: "No such label: \(labelId).")
                    ])
                }
                guard label.projectId == issue.projectId else {
                    throw ProblemError.invalid([
                        ValidationFailure(
                            field: "add", code: .required,
                            message:
                                "Label \(labelId) belongs to a different project from this issue."
                        )
                    ])
                }
                try repository.attach(labelId: labelId, to: issueId, at: now)
            }

            for labelId in delta.remove {
                try repository.detach(labelId: labelId, from: issueId, at: now)
            }

            return try EditedResponse(
                status: .ok,
                response: Paginated(
                    items: try repository.labelIds(for: issueId).compactMap {
                        try repository.find($0)
                    },
                    nextCursor: nil))
        }
    }

    private func resolve(_ context: AppRequestContext) throws -> Label {
        let labelId = try context.id(Label.self, from: "labelId")
        guard let label = try repository.find(labelId) else {
            throw ProblemError.notFound(detail: "No such label.")
        }
        guard label.deletedAt == nil else {
            throw ProblemError.gone(detail: "That label was deleted.")
        }
        return label
    }
}

extension AppRequestContext {
    /// Reads a typed id from a path parameter.
    func id<Entity>(_ type: Entity.Type, from name: String) throws -> ID<Entity> {
        guard let raw = parameters.get(name), let uuid = UUID(uuidString: raw) else {
            throw ProblemError.notFound(detail: "\(name) is not a valid identifier.")
        }
        return ID<Entity>(uuid)
    }
}
