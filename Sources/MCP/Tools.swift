import Core
import Foundation

/// One tool an agent can call.
public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    var listing: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }
}

/// The tool surface.
///
/// Ten fine-grained tools rather than a few coarse ones with a mode parameter:
/// agents select by tool name and description, and reason about that far more
/// reliably than about an argument (ticket 12).
public enum Tools {

    /// Shared wording. Every tool that can be rate limited says so, because an
    /// agent that retries through a 429 is the failure the limit exists to stop.
    static let rateLimitNote =
        " If the server replies with a 429, wait the number of seconds it gives and "
        + "do not retry sooner."

    public static let all: [Tool] = [
        Tool(
            name: "list_issues",
            description:
                "List issues, newest first. Returns a compact summary of each — key, "
                + "title, status, priority, assignee, labels and when it changed — and "
                + "deliberately omits the description, which can be long. Use get_issue "
                + "for the full text of one issue." + rateLimitNote,
            inputSchema: object([
                "project": string("Project key, such as PLAT. Omit for every project."),
                "status": string(
                    "Comma-separated statuses to include: "
                        + Status.known.map(\.wireValue).joined(separator: ", ") + "."),
                "priority": string("Comma-separated priorities."),
                "assignee": string("'me', 'none', or a user id."),
                "query": string("Match text in the title or description."),
                "limit": integer("How many to return. Default 25, maximum 100."),
            ])),
        Tool(
            name: "get_issue",
            description:
                "Fetch one issue in full, including its description." + rateLimitNote,
            inputSchema: object(
                ["issue": string("An issue key like PLAT-142, or an issue id.")],
                required: ["issue"])),
        Tool(
            name: "create_issue",
            description:
                "Create an issue. The title is the only thing required. Issues you "
                + "create are attributed to an agent, which people can see."
                + rateLimitNote,
            inputSchema: object(
                [
                    "project": string("Project key, such as PLAT."),
                    "title": string("A short summary of the work."),
                    "description": string("Markdown detail. Optional."),
                    "status": string(Status.known.map(\.wireValue).joined(separator: ", ")),
                    "priority": string(Priority.known.map(\.wireValue).joined(separator: ", ")),
                    "assignee": string("A user id, or 'me'."),
                ],
                required: ["project", "title"])),
        Tool(
            name: "update_issue",
            description:
                "Change fields on an issue. Only the fields you pass are touched; "
                + "everything else is left alone. To close something, set status to "
                + "done; to abandon it, set status to cancelled. There is no way to "
                + "delete an issue, by design." + rateLimitNote,
            inputSchema: object(
                [
                    "issue": string("An issue key like PLAT-142, or an issue id."),
                    "title": string("A new title."),
                    "description": string("New Markdown detail."),
                    "status": string(Status.known.map(\.wireValue).joined(separator: ", ")),
                    "priority": string(Priority.known.map(\.wireValue).joined(separator: ", ")),
                    "assignee": string("A user id, 'me', or 'none' to unassign."),
                ],
                required: ["issue"])),
        Tool(
            name: "add_comment",
            description:
                "Comment on an issue. Comments you add are attributed to an agent."
                + rateLimitNote,
            inputSchema: object(
                [
                    "issue": string("An issue key like PLAT-142, or an issue id."),
                    "body": string("Markdown."),
                ],
                required: ["issue", "body"])),
        Tool(
            name: "list_comments",
            description: "Read an issue's comment thread, oldest first." + rateLimitNote,
            inputSchema: object(
                ["issue": string("An issue key like PLAT-142, or an issue id.")],
                required: ["issue"])),
        Tool(
            name: "list_projects",
            description:
                "List projects with their keys. Call this first if you do not know "
                + "which project key to use." + rateLimitNote,
            inputSchema: object([:])),
        Tool(
            name: "list_labels",
            description: "List a project's labels." + rateLimitNote,
            inputSchema: object(
                ["project": string("Project key, such as PLAT.")], required: ["project"])),
        Tool(
            name: "list_users",
            description:
                "List people, so a name can be resolved to the id that assignment "
                + "needs." + rateLimitNote,
            inputSchema: object([:])),
        Tool(
            name: "whoami",
            description:
                "Who this token belongs to, and what it may do. An agent token can "
                + "read and write issues, comments and labels, but cannot manage "
                + "users, delete anything, or administer the instance." + rateLimitNote,
            inputSchema: object([:])),
    ]

    public static func named(_ name: String) -> Tool? {
        all.first { $0.name == name }
    }

    // MARK: Schema helpers

    static func object(
        _ properties: [String: JSONValue], required: [String] = []
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
