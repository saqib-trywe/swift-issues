import ArgumentParser
import Core
import Foundation

/// Labels, which are project-scoped by definition.
struct LabelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label",
        abstract: "Work with a project's labels.",
        discussion: """
            A label belongs to one project and may only be applied to issues in it. \
            The project comes from --project, the configured default, or a \
            .issues.toml in this directory.
            """,
        subcommands: [List.self, Create.self, Edit.self, Delete.self]
    )

    /// The project every label command needs.
    struct Scope: ParsableArguments {
        @Option(name: [.short, .long], help: "Project key. Defaults to the configured project.")
        var project: String?

        func resolve(_ context: CommandContext, client: APIClient) async throws -> Project {
            if let project { return try await ProjectCommand.resolve(project, client: client) }
            guard let key = try context.configuration().defaultProject else {
                throw CLIError.missingInput(
                    flag: "--project (or set one with `issues config set project <KEY>`, "
                        + "or add a .issues.toml to this directory)")
            }
            return try await ProjectCommand.resolve(key.wireValue, client: client)
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a project's labels.")

        @OptionGroup var scope: Scope
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let project = try await scope.resolve(context, client: client)

            let data = try await client.data(for: LabelEndpoints.list(projectId: project.id))
            let items = try JSONOutput.items(in: data)
            let labels = try JSONCoders.decoder.decode(
                [Label].self, from: try JSONSerialization.data(withJSONObject: items))

            switch output.format {
            case .json:
                context.terminal.print(try JSONOutput.render(items))
            case .keys:
                for label in labels { context.terminal.print(label.name) }
            case .table:
                guard !labels.isEmpty else {
                    context.terminal.print("No labels in \(project.key.wireValue) yet.")
                    return
                }
                var table = Table(headers: ["NAME", "COLOUR"])
                for label in labels { table.append([label.name, label.color]) }
                context.terminal.print(table.rendered())
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a label.",
            discussion: """
                With no --color, one is chosen from a small palette by hashing the \
                name, so the same label name always gets the same colour — including \
                on two machines that created it independently while offline.
                """)

        @Argument(help: "The label's name.")
        var name: String

        @Option(help: "A colour as #RRGGBB. Derived from the name if omitted.")
        var color: String?

        @OptionGroup var scope: Scope
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()

            let chosen = color ?? Label.defaultColor(forName: name)
            let failures = Validation.labelColor(chosen)
            guard failures.isEmpty else {
                throw ValidationError(failures.map(\.message).joined(separator: " "))
            }

            let project = try await scope.resolve(context, client: client)
            let data = try await client.data(
                for: try LabelEndpoints.create(
                    projectId: project.id, LabelCreate(name: name, color: chosen)))

            switch output.format {
            case .json: context.terminal.print(try JSONOutput.render(data))
            case .keys: context.terminal.print(name)
            case .table:
                context.terminal.print(
                    "Created label '\(name)' \(chosen) in \(project.key.wireValue).")
            }
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rename a label or change its colour.",
            discussion: """
                Renaming does not change the label's id: derivation is a creation-time \
                device so two clients converge, and the id is opaque afterwards.
                """)

        @Argument(help: "The label's current name.")
        var name: String

        @Option(help: "A new name.")
        var newName: String?

        @Option(help: "A new colour as #RRGGBB.")
        var color: String?

        @OptionGroup var scope: Scope
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()

            var patch = LabelPatch()
            if let newName { patch.name = .set(newName) }
            if let color {
                let failures = Validation.labelColor(color)
                guard failures.isEmpty else {
                    throw ValidationError(failures.map(\.message).joined(separator: " "))
                }
                patch.color = .set(color)
            }
            guard !(patch.name.isUnchanged && patch.color.isUnchanged) else {
                throw CLIError.missingInput(flag: "a field to change (--new-name or --color)")
            }

            let project = try await scope.resolve(context, client: client)
            let label = try await LabelCommand.find(name, in: project, client: client)
            let data = try await client.data(
                for: try LabelEndpoints.patch(projectId: project.id, id: label.id, patch))

            switch output.format {
            case .json: context.terminal.print(try JSONOutput.render(data))
            case .keys: context.terminal.print(newName ?? name)
            case .table: context.terminal.print("Updated label '\(name)'.")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a label.",
            discussion: "The label is removed from every issue that carries it.")

        @Argument(help: "The label's name.")
        var name: String

        @Flag(name: [.customLong("yes"), .customShort("y")], help: "Skip the confirmation.")
        var assumeYes = false

        @OptionGroup var scope: Scope

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let project = try await scope.resolve(context, client: client)
            let label = try await LabelCommand.find(name, in: project, client: client)

            try context.confirm(
                "Delete label '\(label.name)' from \(project.key.wireValue)? "
                    + "It will be removed from every issue that carries it.",
                assumeYes: assumeYes)

            try await client.send(LabelEndpoints.delete(projectId: project.id, id: label.id))
            context.terminal.print("Deleted label '\(label.name)'.")
        }
    }

    /// Finds a label by name within a project, case-insensitively.
    static func find(_ name: String, in project: Project, client: APIClient) async throws -> Label {
        let page = try await client.send(
            LabelEndpoints.list(projectId: project.id), expecting: Paginated<Label>.self)

        guard let match = page.items.first(where: { $0.name.lowercased() == name.lowercased() })
        else {
            throw CLIError.malformedConfiguration(
                "No label '\(name)' in \(project.key.wireValue). Known labels: "
                    + (page.items.isEmpty
                        ? "none yet" : page.items.map(\.name).sorted().joined(separator: ", "))
                    + ".")
        }
        return match
    }
}
