import Core
import Foundation

/// Runs a tool call against the API.
///
/// MCP is online-only with no queue, so it sees ordinary REST responses: quarantine
/// and superseded never arise here (ticket 12).
public struct ToolRunner: Sendable {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    /// Default and maximum page sizes.
    ///
    /// Far smaller than the API's, because an agent has a hard context budget that a
    /// CLI user does not.
    public static let defaultLimit = 25
    public static let maximumLimit = 100

    public func call(_ name: String, arguments: JSONValue) async throws -> String {
        switch name {
        case "list_issues": try await listIssues(arguments)
        case "get_issue": try await getIssue(arguments)
        case "create_issue": try await createIssue(arguments)
        case "update_issue": try await updateIssue(arguments)
        case "add_comment": try await addComment(arguments)
        case "list_comments": try await listComments(arguments)
        case "list_projects": try await listProjects()
        case "list_labels": try await listLabels(arguments)
        case "list_users": try await listUsers()
        case "whoami": try await whoami()
        default: throw RPCError.methodNotFound(name)
        }
    }

    // MARK: Issues

    private func listIssues(_ arguments: JSONValue) async throws -> String {
        var filter = IssueFilter()
        if let key = arguments["project"]?.stringValue {
            filter.projectKey = try projectKey(key)
        }
        filter.statuses = try split(arguments["status"]).map { try status($0) }
        filter.priorities = try split(arguments["priority"]).map { try priority($0) }
        filter.query = arguments["query"]?.stringValue

        if let assignee = arguments["assignee"]?.stringValue {
            switch assignee {
            case "me": filter.assignee = .me
            case "none": filter.assignee = .unassigned
            default:
                guard let uuid = UUID(uuidString: assignee) else {
                    throw ToolFailure("assignee must be 'me', 'none', or a user id.")
                }
                filter.assignee = .user(ID(uuid))
            }
        }

        let limit = min(arguments["limit"]?.intValue ?? Self.defaultLimit, Self.maximumLimit)
        let page = try await client.send(
            IssueEndpoints.list(
                filter: filter, sort: .updatedAt(descending: true),
                page: Pagination(limit: max(limit, 1)), expand: [.assignee, .labels]),
            expecting: Paginated<ExpandedIssue>.self)

        guard !page.items.isEmpty else { return "No issues matched." }
        // A compact projection, not the raw payload: fifty issues with full Markdown
        // descriptions can consume an agent's entire context in one call. Ticket 12
        // takes this deviation knowingly, and only here — the API is unchanged.
        return page.items.map(Self.summarise).joined(separator: "\n")
    }

    static func summarise(_ expanded: ExpandedIssue) -> String {
        let issue = expanded.issue
        var parts = [
            issue.key?.wireValue ?? issue.id.rawValue.uuidString,
            issue.status.wireValue,
            issue.priority.wireValue,
        ]
        parts.append(expanded.assignee.map { "@\($0.displayName)" } ?? "unassigned")
        if let labels = expanded.labels, !labels.isEmpty {
            parts.append("[\(labels.map(\.name).joined(separator: " "))]")
        }
        parts.append(issue.title)
        return parts.joined(separator: "  ")
    }

    private func getIssue(_ arguments: JSONValue) async throws -> String {
        let issue = try await client.send(
            IssueEndpoints.get(
                try reference(arguments), expand: [.assignee, .reporter, .labels, .project]),
            expecting: ExpandedIssue.self)
        return Self.describe(issue)
    }

    static func describe(_ expanded: ExpandedIssue) -> String {
        let issue = expanded.issue
        var lines = [
            "\(issue.key?.wireValue ?? issue.id.rawValue.uuidString): \(issue.title)",
            "status: \(issue.status.wireValue)",
            "priority: \(issue.priority.wireValue)",
            "reporter: \(expanded.reporter?.displayName ?? issue.reporterId.rawValue.uuidString)",
            "assignee: \(expanded.assignee?.displayName ?? "unassigned")",
            // The whole point of `via` is answering "which of these did the bot
            // file?", so an agent should see it too.
            "filed by: \(issue.via.wireValue)",
        ]
        if let due = issue.dueDate { lines.append("due: \(due.wireValue)") }
        if let labels = expanded.labels, !labels.isEmpty {
            lines.append("labels: \(labels.map(\.name).joined(separator: ", "))")
        }
        if let project = expanded.project { lines.append("project: \(project.key.wireValue)") }
        if !issue.description.isEmpty {
            lines.append("")
            lines.append(issue.description)
        }
        return lines.joined(separator: "\n")
    }

    private func createIssue(_ arguments: JSONValue) async throws -> String {
        guard let projectKey = arguments["project"]?.stringValue else {
            throw ToolFailure("project is required. Call list_projects to find its key.")
        }
        guard let title = arguments["title"]?.stringValue,
            !title.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw ToolFailure("title is required and must not be empty.")
        }

        let project = try await resolveProject(try self.projectKey(projectKey))
        var body = IssueCreate(
            projectId: project.id, title: title,
            description: arguments["description"]?.stringValue ?? "")
        if let raw = arguments["status"]?.stringValue { body.status = try status(raw) }
        if let raw = arguments["priority"]?.stringValue { body.priority = try priority(raw) }
        if let raw = arguments["assignee"]?.stringValue { body.assigneeId = try await user(raw) }

        let created = try await client.send(
            try IssueEndpoints.create(id: Issue.ID(UUIDv7.generate()), body),
            expecting: Issue.self)
        return "Created \(created.key?.wireValue ?? created.id.rawValue.uuidString): \(created.title)"
    }

    private func updateIssue(_ arguments: JSONValue) async throws -> String {
        let current = try await client.send(
            IssueEndpoints.get(try reference(arguments)), expecting: Issue.self)

        var patch = IssuePatch()
        if let title = arguments["title"]?.stringValue { patch.title = .set(title) }
        if let text = arguments["description"]?.stringValue { patch.description = .set(text) }
        if let raw = arguments["status"]?.stringValue { patch.status = .set(try status(raw)) }
        if let raw = arguments["priority"]?.stringValue { patch.priority = .set(try priority(raw)) }
        if let raw = arguments["assignee"]?.stringValue {
            patch.assigneeId = raw == "none" ? .cleared : .set(try await user(raw))
        }
        guard !patch.isEmpty else {
            throw ToolFailure(
                "Nothing to change. Pass at least one of title, description, status, "
                    + "priority or assignee.")
        }

        let updated = try await client.send(
            try IssueEndpoints.patch(id: current.id, patch), expecting: Issue.self)
        return "Updated \(updated.key?.wireValue ?? updated.id.rawValue.uuidString)."
    }

    // MARK: Comments

    private func addComment(_ arguments: JSONValue) async throws -> String {
        guard let text = arguments["body"]?.stringValue,
            !text.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw ToolFailure("body is required and must not be empty.")
        }
        let issue = try await client.send(
            IssueEndpoints.get(try reference(arguments)), expecting: Issue.self)

        _ = try await client.send(
            try CommentEndpoints.create(
                id: Comment.ID(UUIDv7.generate()),
                CommentCreate(issueId: issue.id, body: text)),
            expecting: Comment.self)
        return "Commented on \(issue.key?.wireValue ?? issue.id.rawValue.uuidString)."
    }

    private func listComments(_ arguments: JSONValue) async throws -> String {
        let issue = try await client.send(
            IssueEndpoints.get(try reference(arguments)), expecting: Issue.self)
        let page = try await client.send(
            CommentEndpoints.list(issueId: issue.id, page: Pagination(limit: Self.maximumLimit)),
            expecting: Paginated<Comment>.self)

        guard !page.items.isEmpty else { return "No comments." }
        return page.items.map { comment in
            // A deleted comment keeps its place: a thread that closes its gaps reads
            // as if the exchange never happened.
            let body = comment.body ?? "(deleted)"
            return "\(comment.via.wireValue) \(JSONCoders.instantString(comment.createdAt)): \(body)"
        }.joined(separator: "\n\n")
    }

    // MARK: The rest

    private func listProjects() async throws -> String {
        let page = try await client.send(
            ProjectEndpoints.list(page: Pagination(limit: Self.maximumLimit)),
            expecting: Paginated<Project>.self)
        let active = page.items.filter { !$0.archived }

        guard !active.isEmpty else { return "No projects." }
        return active.map { "\($0.key.wireValue)  \($0.name)" }.joined(separator: "\n")
    }

    private func listLabels(_ arguments: JSONValue) async throws -> String {
        guard let key = arguments["project"]?.stringValue else {
            throw ToolFailure("project is required.")
        }
        let project = try await resolveProject(try projectKey(key))
        let page = try await client.send(
            LabelEndpoints.list(projectId: project.id), expecting: Paginated<Label>.self)

        guard !page.items.isEmpty else { return "No labels in \(key)." }
        return page.items.map(\.name).joined(separator: "\n")
    }

    private func listUsers() async throws -> String {
        let page = try await client.send(
            UserEndpoints.list(page: Pagination(limit: Self.maximumLimit)),
            expecting: Paginated<User>.self)
        return page.items
            .filter(\.active)
            .map { "\($0.id.rawValue.uuidString)  \($0.displayName)  \($0.email)" }
            .joined(separator: "\n")
    }

    private func whoami() async throws -> String {
        let me = try await client.send(UserEndpoints.me(), expecting: User.self)
        return """
            \(me.displayName) <\(me.email)>
            role: \(me.role.wireValue)

            This token is an agent token. It can read and write issues, comments and \
            labels. It cannot manage users, delete anything, or administer the instance.
            """
    }

    // MARK: Resolving

    private func reference(_ arguments: JSONValue) throws -> IssueRef {
        guard let raw = arguments["issue"]?.stringValue else {
            throw ToolFailure("issue is required.")
        }
        if let key = IssueKey(raw) { return .key(key) }
        if let uuid = UUID(uuidString: raw) { return .id(ID(uuid)) }
        throw ToolFailure("'\(raw)' is neither an issue key like PLAT-142 nor an issue id.")
    }

    private func projectKey(_ raw: String) throws -> ProjectKey {
        guard let key = ProjectKey(raw) else {
            throw ToolFailure(
                "'\(raw)' is not a project key. Keys are two to ten characters, A-Z and 0-9.")
        }
        return key
    }

    private func resolveProject(_ key: ProjectKey) async throws -> Project {
        let page = try await client.send(
            ProjectEndpoints.list(page: Pagination(limit: Self.maximumLimit)),
            expecting: Paginated<Project>.self)
        guard let project = page.items.first(where: { $0.key == key }) else {
            throw ToolFailure(
                "No project with key '\(key.wireValue)'. Known keys: "
                    + page.items.map(\.key.wireValue).sorted().joined(separator: ", ") + ".")
        }
        return project
    }

    private func user(_ raw: String) async throws -> User.ID {
        if raw == "me" {
            return try await client.send(UserEndpoints.me(), expecting: User.self).id
        }
        guard let uuid = UUID(uuidString: raw) else {
            throw ToolFailure("assignee must be a user id or 'me'. Call list_users to find one.")
        }
        return ID(uuid)
    }

    private func split(_ value: JSONValue?) -> [String] {
        guard let raw = value?.stringValue else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func status(_ raw: String) throws -> Status {
        let value = Status(wireValue: raw)
        if case .unknown = value {
            throw ToolFailure(
                "Unknown status '\(raw)'. Known statuses: "
                    + Status.known.map(\.wireValue).joined(separator: ", ") + ".")
        }
        return value
    }

    private func priority(_ raw: String) throws -> Priority {
        let value = Priority(wireValue: raw)
        if case .unknown = value {
            throw ToolFailure(
                "Unknown priority '\(raw)'. Known priorities: "
                    + Priority.known.map(\.wireValue).joined(separator: ", ") + ".")
        }
        return value
    }
}

/// Something an agent can act on.
public struct ToolFailure: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
