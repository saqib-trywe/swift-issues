import Core
import Foundation
import Hummingbird

/// Routes for the Project resource.
///
/// There is no delete: Projects archive, so archiving is a patch.
struct ProjectRoutes: Sendable {
    let database: AppDatabase

    var repository: ProjectRepository { ProjectRepository(database: database) }

    func register(on group: RouterGroup<AppRequestContext>) {
        group.get("/projects") { _, context in
            _ = context.identity
            return try EditedResponse(
                status: .ok,
                response: Paginated(items: try repository.all(), nextCursor: nil))
        }

        group.get("/projects/:id") { _, context in
            let project = try repository.find(try context.projectID())
            guard let project else { throw ProblemError.notFound(detail: "No such project.") }
            return try EditedResponse(status: .ok, response: project)
        }

        group.put("/projects/:id") { request, context in
            // Admins manage the Instance; Members do tracker work (CONTEXT.md).
            try context.require(.admin)
            let id = try context.projectID()
            let body = try await request.decode(as: ProjectCreate.self, context: context)

            let failures = Validation.projectName(body.name)
            guard failures.isEmpty else { throw ProblemError.invalid(failures) }

            // Create-only: a repeated identical PUT is the retry an offline client
            // makes when it never saw the response, and must not create twice.
            if let existing = try repository.find(id) {
                guard existing.key == body.key, existing.name == body.name,
                    existing.description == body.description
                else {
                    throw ProblemError.conflict(
                        detail: "That id already exists with different content.")
                }
                return try EditedResponse(status: .ok, response: existing)
            }

            let now = Date()
            let project = Project(
                id: id, key: body.key, name: body.name, description: body.description,
                archived: false, createdAt: now, updatedAt: now)
            try repository.save(project)
            return try EditedResponse(status: .created, response: project)
        }

        group.patch("/projects/:id") { request, context in
            try context.require(.admin)
            let id = try context.projectID()
            guard var project = try repository.find(id) else {
                throw ProblemError.notFound(detail: "No such project.")
            }
            let patch = try await request.decode(as: ProjectPatch.self, context: context)

            // Only the fields the caller named are touched. `key` is absent from
            // ProjectPatch entirely, so it cannot be changed here.
            if case .set(let name) = patch.name {
                let failures = Validation.projectName(name)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
                project.name = name
            }
            if case .set(let description) = patch.description { project.description = description }
            if case .set(let archived) = patch.archived { project.archived = archived }
            project.updatedAt = Date()

            try repository.save(project)
            return try EditedResponse(status: .ok, response: project)
        }
    }
}

extension AppRequestContext {
    /// Reads and validates the `:id` path parameter.
    func projectID() throws -> Project.ID {
        guard let raw = parameters.get("id"), let uuid = UUID(uuidString: raw) else {
            throw ProblemError.notFound(detail: "No such project.")
        }
        return Project.ID(uuid)
    }
}
