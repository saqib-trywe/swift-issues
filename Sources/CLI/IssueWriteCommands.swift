import ArgumentParser
import Core
import Foundation

/// Fields that can be cleared.
///
/// Only the nullable ones appear: `Settable` makes "clear the status" impossible
/// to express in the API at all, so `--unset status` must be rejected by name
/// rather than sent and refused.
enum ClearableField: String, CaseIterable, ExpressibleByArgument {
    case assignee
    case due

    static var listed: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// The flags shared by `create` and `edit`.
struct IssueFieldOptions: ParsableArguments {
    @Option(name: [.short, .long], help: "The issue's title.")
    var title: String?

    @Option(
        name: [.short, .long],
        help: "Markdown description. Pass '-' to read stdin; omit to open $EDITOR.")
    var description: String?

    @Flag(help: "Do not open $EDITOR for the description.")
    var noEdit = false

    @Option(help: "Status: \(Status.known.map(\.wireValue).joined(separator: ", ")).")
    var status: String?

    @Option(help: "Priority: \(Priority.known.map(\.wireValue).joined(separator: ", ")).")
    var priority: String?

    @Option(help: "Assignee: 'me', an email address, or a user id.")
    var assignee: String?

    @Option(help: "Due date, as YYYY-MM-DD.")
    var due: String?

    @Option(name: [.customLong("label"), .customShort("l")], help: "Label name, repeatable.")
    var labels: [String] = []

    func parsedStatus() throws -> Status? {
        try status.map { raw in
            let value = Status(wireValue: raw)
            guard case .unknown = value else { return value }
            throw ValidationError(
                "Unknown status '\(raw)'. Known statuses: \(Status.known.map(\.wireValue).joined(separator: ", "))."
            )
        }
    }

    func parsedPriority() throws -> Priority? {
        try priority.map { raw in
            let value = Priority(wireValue: raw)
            guard case .unknown = value else { return value }
            throw ValidationError(
                "Unknown priority '\(raw)'. Known priorities: \(Priority.known.map(\.wireValue).joined(separator: ", "))."
            )
        }
    }

    func parsedDueDate() throws -> CivilDate? {
        try due.map { raw in
            guard let date = CivilDate(wireValue: raw) else {
                throw ValidationError("'\(raw)' is not a calendar date. Use YYYY-MM-DD.")
            }
            return date
        }
    }
}

extension IssueCommand {

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create an issue.",
            discussion: """
                The id is generated here, not by the server, so a create that is \
                retried after a lost response cannot produce two issues.
                """)

        @Option(name: [.short, .long], help: "Project key. Defaults to the configured project.")
        var project: String?

        @OptionGroup var fields: IssueFieldOptions
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let workspace = Workspace(client: client)

            guard let title = fields.title, !title.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw CLIError.missingInput(flag: "--title")
            }

            let key =
                try project.map { raw -> ProjectKey in
                    guard let parsed = ProjectKey(raw) else {
                        throw ValidationError("'\(raw)' is not a valid project key.")
                    }
                    return parsed
                } ?? (try context.configuration().defaultProject)
            let resolved = try await workspace.project(key: key)

            // A description is optional, so no editor and no terminal simply means
            // no description — failing a scripted create over an optional field
            // would be wrong.
            let description =
                try TextInput.resolve(
                    flag: fields.description,
                    current: "",
                    instructions: ["Describe '\(title)' in Markdown. Leave empty for no description."],
                    allowEditor: !fields.noEdit,
                    required: false,
                    flagName: "--description",
                    context: context) ?? ""

            var body = IssueCreate(
                projectId: resolved.id,
                title: title,
                description: description,
                labelIds: try await workspace.labelIDs(named: fields.labels, in: resolved))
            if let status = try fields.parsedStatus() { body.status = status }
            if let priority = try fields.parsedPriority() { body.priority = priority }
            if let due = try fields.parsedDueDate() { body.dueDate = due }
            if let assignee = fields.assignee {
                body.assigneeId = try await UserLookup.resolve(assignee, client: client)
            }

            // UUIDv7 so the id itself carries creation order, which keeps an
            // offline-created issue sortable before the server ever sees it.
            let id = Issue.ID(UUIDv7.generate())
            let data = try await client.data(for: try IssueEndpoints.create(id: id, body))
            try Render.issue(data, output: output, context: context, client: client, created: true)
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change an issue.",
            discussion: """
                Only the fields you name are touched. Use --unset to clear one \
                (\(ClearableField.listed)); omitting a flag leaves the field alone. \
                With no flags at all, $EDITOR opens on the description.
                """)

        @Argument(help: "An issue key like PROJ-142, or an issue id.")
        var issue: String

        @OptionGroup var fields: IssueFieldOptions

        @Option(help: "Clear a field: \(ClearableField.listed). Repeatable.")
        var unset: [ClearableField] = []

        @Option(help: "Remove a label. Repeatable.")
        var removeLabel: [String] = []

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let reference = try IssueCommand.Show.reference(for: issue)

            // Everything that can be judged from argv alone is judged before any
            // request. `issues edit PROJ-1 --status finished` should say the status
            // is unknown, not that the issue is missing — the typo is the problem,
            // and it is the same problem whether or not PROJ-1 exists.
            var patch = IssuePatch()
            if let title = fields.title { patch.title = .set(title) }
            if let status = try fields.parsedStatus() { patch.status = .set(status) }
            if let priority = try fields.parsedPriority() { patch.priority = .set(priority) }
            if let due = try fields.parsedDueDate() { patch.dueDate = .set(due) }

            // Read next: the id is needed to write, and the editor needs the
            // current description to seed its buffer.
            let current = try await client.send(
                IssueEndpoints.get(reference), expecting: Issue.self)

            if let assignee = fields.assignee {
                patch.assigneeId = .set(try await UserLookup.resolve(assignee, client: client))
            }

            for field in unset {
                switch field {
                // `.cleared` is the third Merge Patch state — an explicit null,
                // which is different from omitting the key.
                case .assignee: patch.assigneeId = .cleared
                case .due: patch.dueDate = .cleared
                }
            }

            let changesAnythingElse =
                !fields.labels.isEmpty || !removeLabel.isEmpty || !patch.isEmpty
            let description = try TextInput.resolve(
                flag: fields.description,
                current: current.description,
                instructions: ["Edit the description of \(issue) in Markdown."],
                // The editor only opens when nothing else was asked for, so
                // `issues edit PROJ-1 --status done` does not stop for a text editor.
                allowEditor: !fields.noEdit && !changesAnythingElse,
                required: false,
                flagName: "--description",
                context: context)
            if let description, description != current.description {
                patch.description = .set(description)
            }

            var labelIDs: (add: [Label.ID], remove: [Label.ID]) = ([], [])
            if !fields.labels.isEmpty || !removeLabel.isEmpty {
                let workspace = Workspace(client: client)
                // The issue already knows its project, so a label change never
                // needs --project or a configured default.
                let owning = try await workspace.project(id: current.projectId)
                labelIDs.add = try await workspace.labelIDs(named: fields.labels, in: owning)
                labelIDs.remove = try await workspace.labelIDs(named: removeLabel, in: owning)
            }

            guard !patch.isEmpty || !labelIDs.add.isEmpty || !labelIDs.remove.isEmpty else {
                // Silently succeeding would look like the edit was applied.
                throw CLIError.missingInput(
                    flag:
                        "a field to change (--title, --status, --priority, --assignee, --due, --label, --unset)"
                )
            }

            // The patch response is the updated issue, so no extra read is needed
            // for the common case.
            var data: Data?
            if !patch.isEmpty {
                data = try await client.data(
                    for: try IssueEndpoints.patch(id: current.id, patch))
            }
            if !labelIDs.add.isEmpty || !labelIDs.remove.isEmpty {
                // This route answers with the issue's labels, not the issue, so the
                // issue is re-read only when labels actually changed.
                try await client.send(
                    try IssueEndpoints.changeLabels(
                        id: current.id, add: labelIDs.add, remove: labelIDs.remove))
                data = try await client.data(for: IssueEndpoints.get(reference))
            }

            // Unreachable: the guard above rejects a patch that changes nothing.
            guard let data else { throw CLIError.cancelled }
            try Render.issue(data, output: output, context: context, client: client, created: false)
        }
    }

    struct Comment: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Comment on an issue.",
            discussion: "Pass '-' to read the body from stdin; omit --message to open $EDITOR.")

        @Argument(help: "An issue key like PROJ-142, or an issue id.")
        var issue: String

        @Option(name: [.short, .long], help: "The comment body, as Markdown.")
        var message: String?

        @Flag(help: "Do not open $EDITOR.")
        var noEdit = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let reference = try IssueCommand.Show.reference(for: issue)
            let target = try await client.send(IssueEndpoints.get(reference), expecting: Issue.self)

            // A body is required, so this is where ticket 11's "fail naming the
            // missing flag" applies: an empty comment is not a comment.
            guard
                let body = try TextInput.resolve(
                    flag: message,
                    current: "",
                    instructions: ["Write a comment on \(issue) in Markdown."],
                    allowEditor: !noEdit,
                    required: true,
                    flagName: "--message",
                    context: context)
            else { throw CLIError.cancelled }

            let id = Core.Comment.ID(UUIDv7.generate())
            let data = try await client.data(
                for: try CommentEndpoints.create(
                    id: id, CommentCreate(issueId: target.id, body: body)))

            switch output.format {
            case .json: context.terminal.print(try JSONOutput.render(data))
            case .keys: context.terminal.print(id.rawValue.uuidString)
            case .table: context.terminal.print("Commented on \(issue).")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete an issue.",
            discussion: """
                Deletion is a tombstone and is not undoable from the CLI. The \
                confirmation names the issue's title, because a key alone gives you \
                nothing to notice you have the wrong one.
                """)

        @Argument(help: "An issue key like PROJ-142, or an issue id.")
        var issue: String

        @Flag(name: [.customLong("yes"), .customShort("y")], help: "Skip the confirmation.")
        var assumeYes = false

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let reference = try IssueCommand.Show.reference(for: issue)

            // Read before asking: the title is the whole point of the prompt.
            let target = try await client.send(IssueEndpoints.get(reference), expecting: Issue.self)
            try context.confirm(
                "Delete \(target.key?.wireValue ?? issue) \"\(target.title)\"? This cannot be undone.",
                assumeYes: assumeYes)

            try await client.send(IssueEndpoints.delete(target.id))
            context.terminal.print("Deleted \(target.key?.wireValue ?? issue).")
        }
    }
}

/// The arguments every status shortcut shares.
///
/// A `ParsableArguments` rather than a base command: ArgumentParser cannot nest
/// one command inside another, and each shortcut needs its own help text anyway.
struct StatusShortcutOptions: ParsableArguments {
    @Argument(help: "An issue key like PROJ-142, or an issue id.")
    var issue: String

    @OptionGroup var output: OutputOptions

    /// `close`, `start`, `cancel` and `reopen` are sugar over `edit --status`.
    ///
    /// Kept deliberately (ticket 11): these are the verbs typed dozens of times a
    /// day, and making everyone spell out a status enum for the commonest state
    /// change is the kind of purity that gets a CLI abandoned.
    func apply(_ status: Status) async throws {
        let context = Runtime.require()
        let client = try context.client()
        let reference = try IssueCommand.Show.reference(for: issue)
        let current = try await client.send(IssueEndpoints.get(reference), expecting: Issue.self)

        var patch = IssuePatch()
        patch.status = .set(status)
        let data = try await client.data(for: try IssueEndpoints.patch(id: current.id, patch))
        try Render.issue(data, output: output, context: context, client: client, created: false)
    }
}

extension IssueCommand {

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mark an issue done.")
        @OptionGroup var shortcut: StatusShortcutOptions
        func run() async throws { try await shortcut.apply(.done) }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mark an issue in progress.")
        @OptionGroup var shortcut: StatusShortcutOptions
        func run() async throws { try await shortcut.apply(.inProgress) }
    }

    struct Cancel: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mark an issue cancelled.")
        @OptionGroup var shortcut: StatusShortcutOptions
        func run() async throws { try await shortcut.apply(.cancelled) }
    }

    struct Reopen: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move an issue back to todo.")
        @OptionGroup var shortcut: StatusShortcutOptions
        func run() async throws { try await shortcut.apply(.todo) }
    }

    struct Assign: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Assign an issue, or unassign it.",
            discussion: "Pass --to none to unassign; that is the same as `edit --unset assignee`.")

        @Argument(help: "An issue key like PROJ-142, or an issue id.")
        var issue: String

        @Option(help: "'me', 'none', an email address, or a user id.")
        var to: String

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let reference = try IssueCommand.Show.reference(for: issue)
            let current = try await client.send(IssueEndpoints.get(reference), expecting: Issue.self)

            var patch = IssuePatch()
            patch.assigneeId =
                to == "none" ? .cleared : .set(try await UserLookup.resolve(to, client: client))

            let data = try await client.data(for: try IssueEndpoints.patch(id: current.id, patch))
            try Render.issue(data, output: output, context: context, client: client, created: false)
        }
    }
}
