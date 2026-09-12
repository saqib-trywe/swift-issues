import ArgumentParser
import Core
import Foundation

/// The implied noun. `issues list` reaches these.
struct IssueCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "issue",
        abstract: "Work with issues.",
        subcommands: [
            List.self, Show.self, Create.self, Edit.self, Comment.self,
            Assign.self, Close.self, Start.self, Cancel.self, Reopen.self, Delete.self,
        ]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List issues.",
            discussion: """
                Values within one filter are OR-ed; different filters are AND-ed. \
                So --status todo,inProgress --priority high means "todo or in \
                progress, and high priority".
                """)

        @Option(name: [.short, .long], help: "Project key. Defaults to the configured project.")
        var project: String?

        // Completion lists the known values: `inProgress` is the one nobody
        // remembers the spelling of, which is exactly what completion is for.
        @Option(
            help: "Status, repeatable or comma-separated.",
            completion: .list(Status.known.map(\.wireValue)))
        var status: [String] = []

        @Option(
            help: "Priority, repeatable or comma-separated.",
            completion: .list(Priority.known.map(\.wireValue)))
        var priority: [String] = []

        @Option(
            help: "Assignee: 'me', 'none', or a user id.",
            completion: .list(["me", "none"]))
        var assignee: String?

        @Option(help: "Label name, repeatable or comma-separated.")
        var label: [String] = []

        // No short form: ticket 11 reserves -q for --quiet, which is the flag
        // people pipe into xargs and the one that must not surprise anybody.
        @Option(name: .customLong("query"), help: "Match text in the title or description.")
        var query: String?

        @Option(
            help: "Order by: updated, created, priority, due.",
            completion: .list(["updated", "created", "priority", "due"]))
        var sort: String?

        // A leading '-' also reverses, matching the wire format, but argv makes
        // `--sort -updated` look like a flag — it only works as `--sort=-updated`.
        // This flag is the form that cannot be got wrong.
        @Flag(help: "Reverse the sort order.")
        var reverse = false

        @Option(help: "Maximum number of issues to return.")
        var limit: Int = 50

        @Flag(help: "Return every match, ignoring --limit.")
        var all = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()

            let filter = try buildFilter(context)
            let order = try parseSort()
            // Cursors are an API mechanism, not a user concept (ticket 11), so
            // paging is walked here and never surfaced.
            let wanted = all ? Int.max : max(limit, 1)

            var collected: [Any] = []
            var cursor: String?
            repeat {
                let pageSize = min(wanted - collected.count, Pagination.maximumLimit)
                let request = IssueEndpoints.list(
                    filter: filter, sort: order,
                    page: Pagination(cursor: cursor, limit: pageSize),
                    // Only for the human table: --json must stay the plain payload a
                    // script expects, and --quiet needs nothing but keys.
                    expand: output.format == .table ? [.assignee] : [])
                let data = try await client.data(for: request)
                collected.append(contentsOf: try JSONOutput.items(in: data))
                cursor = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                    .flatMap { $0["nextCursor"] as? String }
            } while cursor != nil && collected.count < wanted

            if collected.count > wanted { collected.removeLast(collected.count - wanted) }

            try await render(collected, context: context, client: client)
        }

        private func buildFilter(_ context: CommandContext) throws -> IssueFilter {
            var filter = IssueFilter()

            let projectKey = try project ?? context.configuration().defaultProject?.wireValue
            if let projectKey {
                guard let parsed = ProjectKey(projectKey) else {
                    throw ValidationError("'\(projectKey)' is not a valid project key.")
                }
                filter.projectKey = parsed
            }

            filter.statuses = try Self.split(status).map { raw in
                let value = Status(wireValue: raw)
                // An unknown status is almost always a typo, and filtering by one
                // silently returns nothing — which reads as "no issues" rather
                // than "you misspelled it".
                guard case .unknown = value else { return value }
                throw ValidationError(
                    "Unknown status '\(raw)'. Known statuses: \(Status.known.map(\.wireValue).joined(separator: ", "))."
                )
            }
            filter.priorities = try Self.split(priority).map { raw in
                let value = Priority(wireValue: raw)
                guard case .unknown = value else { return value }
                throw ValidationError(
                    "Unknown priority '\(raw)'. Known priorities: \(Priority.known.map(\.wireValue).joined(separator: ", "))."
                )
            }
            filter.labels = Self.split(label)
            filter.query = query

            if let assignee {
                switch assignee {
                case "me": filter.assignee = .me
                case "none": filter.assignee = .unassigned
                default:
                    guard let uuid = UUID(uuidString: assignee) else {
                        throw ValidationError("--assignee takes 'me', 'none', or a user id.")
                    }
                    filter.assignee = .user(ID(uuid))
                }
            }

            return filter
        }

        private func parseSort() throws -> IssueSort? {
            guard let sort else { return nil }
            let prefixed = sort.hasPrefix("-")
            // Either form reverses; both together cancel, which is what a reader
            // of `--sort=-updated --reverse` would expect.
            let descending = prefixed != reverse
            let field = prefixed ? String(sort.dropFirst()) : sort
            switch field {
            case "updated", "updatedAt": return .updatedAt(descending: descending)
            case "created", "createdAt": return .createdAt(descending: descending)
            case "priority": return .priority(descending: descending)
            case "due", "dueDate": return .dueDate(descending: descending)
            default:
                throw ValidationError("Unknown sort '\(field)'. Try: updated, created, priority, due.")
            }
        }

        /// Accepts both repetition and comma separation, because the API's own
        /// OR-within-a-parameter rule is expressed with commas and people will
        /// type it that way.
        static func split(_ values: [String]) -> [String] {
            values.flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        private func render(_ items: [Any], context: CommandContext, client: APIClient) async throws {
            switch output.format {
            case .json:
                context.terminal.print(try JSONOutput.render(items))
            case .keys:
                for item in items {
                    guard let object = item as? [String: Any], let key = object["key"] as? String
                    else { continue }
                    context.terminal.print(key)
                }
            case .table:
                guard !items.isEmpty else {
                    context.terminal.print("No issues matched.")
                    return
                }
                let issues = try JSONCoders.decoder.decode(
                    [ExpandedIssue].self, from: try JSONSerialization.data(withJSONObject: items))

                var table = Table(headers: ["KEY", "STATUS", "PRI", "ASSIGNEE", "TITLE"])
                for expanded in issues {
                    let issue = expanded.issue
                    table.append([
                        issue.key?.wireValue ?? "—",
                        issue.status.wireValue,
                        issue.priority.wireValue,
                        expanded.assignee?.displayName ?? "—",
                        issue.title.truncated(to: 60),
                    ])
                }
                context.terminal.print(table.rendered())
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one issue.")

        @Argument(help: "An issue key like PROJ-142, or an issue id.")
        var issue: String

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let reference = try Self.reference(for: issue)

            let data = try await client.data(
                for: IssueEndpoints.get(
                    reference, expand: output.format == .table ? [.assignee, .reporter] : []))

            switch output.format {
            case .json:
                context.terminal.print(try JSONOutput.render(data))
            case .keys:
                let issue = try JSONCoders.decoder.decode(Issue.self, from: data)
                context.terminal.print(issue.key?.wireValue ?? issue.id.rawValue.uuidString)
            case .table:
                let value = try JSONCoders.decoder.decode(ExpandedIssue.self, from: data)
                context.terminal.print(Self.describe(value))
            }
        }

        /// Accepts either addressing form, because a human holds a key and a script
        /// holds an id, and making either look the thing up first is a round trip
        /// the API added key addressing specifically to avoid.
        static func reference(for input: String) throws -> IssueRef {
            if let key = IssueKey(input) { return .key(key) }
            if let uuid = UUID(uuidString: input) { return .id(ID(uuid)) }
            throw ValidationError("'\(input)' is neither an issue key like PROJ-142 nor an issue id.")
        }

        static func describe(_ expanded: ExpandedIssue) -> String {
            let issue = expanded.issue
            var lines = [
                "\(issue.key?.wireValue ?? issue.id.rawValue.uuidString)  \(issue.title)",
                "",
                "Status:    \(issue.status.wireValue)",
                "Priority:  \(issue.priority.wireValue)",
                "Reporter:  \(expanded.reporter?.displayName ?? issue.reporterId.rawValue.uuidString)",
                "Assignee:  \(expanded.assignee?.displayName ?? (issue.assigneeId == nil ? "unassigned" : issue.assigneeId!.rawValue.uuidString))",
            ]
            if let due = issue.dueDate { lines.append("Due:       \(due.wireValue)") }
            if issue.via != .human { lines.append("Created by: \(issue.via.wireValue)") }
            // A deleted issue still renders: the server returns 410 with a body,
            // and "this is the thing you deleted" is more use than a bare error.
            if let deletedAt = issue.deletedAt {
                lines.append("Deleted:   \(JSONCoders.instantString(deletedAt))")
            }
            if !issue.description.isEmpty {
                lines.append(contentsOf: ["", issue.description])
            }
            return lines.joined(separator: "\n")
        }
    }
}
