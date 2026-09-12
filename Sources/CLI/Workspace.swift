import Core
import Foundation

/// Turns the names people type into the ids the API wants.
///
/// The API addresses Projects and Labels by id, but nobody holds a UUID. This
/// resolves once per invocation and caches, so a command that needs both a
/// project and its labels costs one extra request, not two.
actor Workspace {
    private let client: APIClient
    private var projects: [Project]?
    private var labelsByProject: [Project.ID: [Label]] = [:]

    init(client: APIClient) {
        self.client = client
    }

    /// The project a command should act on.
    ///
    /// `--project`, then the configured or per-directory default. Failing here
    /// names both ways of setting it, because "no project" is otherwise a puzzle.
    func project(key: ProjectKey?) async throws -> Project {
        guard let key else {
            throw CLIError.missingInput(
                flag: "--project (or set one with `issues config set project <KEY>`, "
                    + "or add a .issues.toml to this directory)")
        }
        let all = try await allProjects()
        guard let project = all.first(where: { $0.key == key }) else {
            throw CLIError.malformedConfiguration(
                "No project with key '\(key.wireValue)'. Known projects: "
                    + known(all.map(\.key.wireValue)) + ".")
        }
        return project
    }

    /// The project an issue belongs to.
    ///
    /// A label change on an existing issue never needs `--project`: the issue
    /// already names its own project, and asking again would let somebody apply a
    /// label from the wrong one.
    func project(id: Project.ID) async throws -> Project {
        let all = try await allProjects()
        guard let project = all.first(where: { $0.id == id }) else {
            throw CLIError.malformedConfiguration("The issue's project is not visible to you.")
        }
        return project
    }

    /// Resolves label names within a project.
    ///
    /// An unknown name is refused rather than created. Labels are a shared,
    /// project-wide vocabulary, and a tracker where every typo silently becomes a
    /// new label fills up with near-duplicates nobody ever cleans out.
    func labelIDs(named names: [String], in project: Project) async throws -> [Label.ID] {
        guard !names.isEmpty else { return [] }
        let labels = try await labels(in: project)

        return try names.map { name in
            // Case-insensitive: nobody remembers whether it was "Bug" or "bug",
            // and the server already treats names as a display concern.
            guard let match = labels.first(where: { $0.name.lowercased() == name.lowercased() })
            else {
                throw CLIError.malformedConfiguration(
                    "No label '\(name)' in \(project.key.wireValue). Known labels: "
                        + known(labels.map(\.name))
                        + ". Create one with `issues label create \(name)`.")
            }
            return match.id
        }
    }

    private func allProjects() async throws -> [Project] {
        if let projects { return projects }
        let page = try await client.send(
            ProjectEndpoints.list(page: Pagination(limit: Pagination.maximumLimit)),
            expecting: Paginated<Project>.self)
        projects = page.items
        return page.items
    }

    private func labels(in project: Project) async throws -> [Label] {
        if let cached = labelsByProject[project.id] { return cached }
        let labels = try await client.send(
            LabelEndpoints.list(projectId: project.id), expecting: Paginated<Label>.self)
        labelsByProject[project.id] = labels.items
        return labels.items
    }

    /// Lists what *is* available, because a rejection that does not say what would
    /// have worked leaves someone guessing.
    private func known(_ names: [String]) -> String {
        names.isEmpty ? "none yet" : names.sorted().joined(separator: ", ")
    }
}
