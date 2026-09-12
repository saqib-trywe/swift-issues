import ArgumentParser
import Core
import Foundation

/// Projects. Admin-only for writes, because a Project is instance structure
/// rather than tracker work (CONTEXT.md).
struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Work with projects.",
        discussion: """
            Creating, editing and archiving a project require the Admin role. \
            Those commands are listed here for everyone, and rejected at call: \
            hiding them would make --help depend on who you are, which means help \
            needs a network round trip and a valid token to render.
            """,
        subcommands: [List.self, Show.self, Create.self, Edit.self, Archive.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List projects.")

        @Flag(help: "Include archived projects.")
        var all = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let data = try await context.client().data(
                for: ProjectEndpoints.list(page: Pagination(limit: Pagination.maximumLimit)))
            let items = try JSONOutput.items(in: data)

            let projects = try JSONCoders.decoder.decode(
                [Project].self, from: try JSONSerialization.data(withJSONObject: items))
            let visible = all ? projects : projects.filter { !$0.archived }

            switch output.format {
            case .json:
                context.terminal.print(try JSONOutput.render(items))
            case .keys:
                for project in visible { context.terminal.print(project.key.wireValue) }
            case .table:
                guard !visible.isEmpty else {
                    context.terminal.print(
                        all ? "No projects yet." : "No active projects. Try --all.")
                    return
                }
                var table = Table(headers: ["KEY", "NAME", "STATE"])
                for project in visible {
                    table.append([
                        project.key.wireValue,
                        project.name.truncated(to: 40),
                        project.archived ? "archived" : "active",
                    ])
                }
                context.terminal.print(table.rendered())
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one project.")

        @Argument(help: "A project key like PROJ, or a project id.")
        var project: String

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let resolved = try await ProjectCommand.resolve(project, client: client)

            let data = try await client.data(for: ProjectEndpoints.get(resolved.id))
            switch output.format {
            case .json: context.terminal.print(try JSONOutput.render(data))
            case .keys: context.terminal.print(resolved.key.wireValue)
            case .table:
                context.terminal.print("\(resolved.key.wireValue)  \(resolved.name)")
                context.terminal.print("")
                context.terminal.print("State:     \(resolved.archived ? "archived" : "active")")
                if !resolved.description.isEmpty {
                    context.terminal.print("")
                    context.terminal.print(resolved.description)
                }
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a project. Admin only.")

        @Argument(help: "The project key: two to ten characters, A-Z and 0-9.")
        var key: String

        @Option(name: [.short, .long], help: "The project's name.")
        var name: String

        @Option(name: [.short, .long], help: "A description.")
        var description: String?

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            guard let parsed = ProjectKey(key) else {
                throw ValidationError(
                    "'\(key)' is not a valid project key: two to ten characters, A-Z and 0-9.")
            }

            let body = ProjectCreate(key: parsed, name: name, description: description ?? "")
            let data = try await context.client().data(
                for: try ProjectEndpoints.create(id: Project.ID(UUIDv7.generate()), body))

            switch output.format {
            case .json: context.terminal.print(try JSONOutput.render(data))
            case .keys: context.terminal.print(parsed.wireValue)
            case .table: context.terminal.print("Created \(parsed.wireValue)  \(name)")
            }
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a project. Admin only.")

        @Argument(help: "A project key like PROJ, or a project id.")
        var project: String

        @Option(name: [.short, .long], help: "A new name.")
        var name: String?

        @Option(name: [.short, .long], help: "A new description.")
        var description: String?

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()

            var patch = ProjectPatch()
            if let name { patch.name = .set(name) }
            if let description { patch.description = .set(description) }
            guard !(patch.name.isUnchanged && patch.description.isUnchanged) else {
                throw CLIError.missingInput(flag: "a field to change (--name or --description)")
            }

            let resolved = try await ProjectCommand.resolve(project, client: client)
            let data = try await client.data(for: try ProjectEndpoints.patch(id: resolved.id, patch))

            switch output.format {
            case .json: context.terminal.print(try JSONOutput.render(data))
            case .keys: context.terminal.print(resolved.key.wireValue)
            case .table: context.terminal.print("Updated \(resolved.key.wireValue)")
            }
        }
    }

    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Archive or unarchive a project. Admin only.",
            discussion: """
                Archiving hides a project without deleting anything; its issues keep \
                their keys and stay readable.
                """)

        @Argument(help: "A project key like PROJ, or a project id.")
        var project: String

        @Flag(help: "Unarchive instead.")
        var undo = false

        @Flag(name: [.customLong("yes"), .customShort("y")], help: "Skip the confirmation.")
        var assumeYes = false

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let resolved = try await ProjectCommand.resolve(project, client: client)

            if !undo {
                // Names the project, not just its key: a key alone gives you nothing
                // to notice you have the wrong one.
                try context.confirm(
                    "Archive \(resolved.key.wireValue) \"\(resolved.name)\"?", assumeYes: assumeYes)
            }

            var patch = ProjectPatch()
            patch.archived = .set(!undo)
            _ = try await client.data(for: try ProjectEndpoints.patch(id: resolved.id, patch))
            context.terminal.print(
                "\(undo ? "Unarchived" : "Archived") \(resolved.key.wireValue).")
        }
    }

    /// Accepts a key or an id.
    ///
    /// Projects have no key addressing server-side, so a key is resolved against
    /// the list. A human holds a key; a script may hold either.
    static func resolve(_ input: String, client: APIClient) async throws -> Project {
        let page = try await client.send(
            ProjectEndpoints.list(page: Pagination(limit: Pagination.maximumLimit)),
            expecting: Paginated<Project>.self)

        if let uuid = UUID(uuidString: input) {
            guard let match = page.items.first(where: { $0.id == ID(uuid) }) else {
                throw APIError.notFound(nil)
            }
            return match
        }
        guard let key = ProjectKey(input) else {
            throw ValidationError("'\(input)' is neither a project key nor a project id.")
        }
        guard let match = page.items.first(where: { $0.key == key }) else {
            throw CLIError.malformedConfiguration(
                "No project with key '\(key.wireValue)'. Known projects: "
                    + (page.items.isEmpty
                        ? "none yet" : page.items.map(\.key.wireValue).sorted().joined(separator: ", "))
                    + ".")
        }
        return match
    }
}
