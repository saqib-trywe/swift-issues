import Core
import Foundation

/// Where Markdown comes from: a flag, stdin, or `$EDITOR`.
///
/// Ticket 11's git-style convention. Kept in one place because the rules are
/// subtle and identical for descriptions and comment bodies, and because getting
/// the non-terminal case wrong means a CI job that hangs on a prompt nobody can
/// see.
enum TextInput {

    /// Resolves the text, or returns `nil` for "leave it alone".
    ///
    /// - Parameters:
    ///   - required: whether an absent value is a failure. A description is
    ///     optional, so a scripted create simply gets none; a comment body is not,
    ///     so its absence must name the missing flag.
    static func resolve(
        flag: String?,
        current: String,
        instructions: [String],
        allowEditor: Bool,
        required: Bool,
        flagName: String,
        context: CommandContext
    ) throws -> String? {
        if let flag {
            // `-` means stdin, the same as it does everywhere else.
            guard flag == "-" else { return flag }
            let piped = context.readStandardInput().trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !piped.isEmpty else {
                if required { throw CLIError.missingInput(flag: "\(flagName) (stdin was empty)") }
                return ""
            }
            return piped
        }

        // An editor can only be opened at a terminal. Launching one attached to a
        // pipe leaves the process waiting on input that will never come, which is
        // indistinguishable from a hang.
        guard allowEditor, context.terminal.isInputTerminal else {
            if required { throw CLIError.missingInput(flag: flagName) }
            return nil
        }

        return try context.openEditor(
            Editor.template(current: current, instructions: instructions))
    }
}

/// Turns what somebody types for a user into a user id.
enum UserLookup {

    /// Accepts `me`, an email address, or an id.
    ///
    /// Email is here because it is what people actually know about a colleague;
    /// requiring a UUID to assign an issue would make `assign` useless.
    static func resolve(_ input: String, client: APIClient) async throws -> User.ID {
        if input == "me" {
            return try await client.send(UserEndpoints.me(), expecting: User.self).id
        }
        if let uuid = UUID(uuidString: input) { return ID(uuid) }

        let page = try await client.send(
            UserEndpoints.list(page: Pagination(limit: Pagination.maximumLimit)),
            expecting: Paginated<User>.self)

        let matches = page.items.filter {
            $0.email.lowercased() == input.lowercased()
                || $0.displayName.lowercased() == input.lowercased()
        }
        if let only = matches.first, matches.count == 1 { return only.id }

        // Two people called "Sam" must not resolve to whichever the server
        // happened to return first.
        if matches.count > 1 {
            throw CLIError.malformedConfiguration(
                "'\(input)' matches \(matches.count) users. Use an email address or a user id.")
        }
        throw CLIError.malformedConfiguration(
            "No user matching '\(input)'. Try an email address, a user id, or 'me'.")
    }
}

/// Shared rendering for the commands that return one issue.
enum Render {

    static func issue(
        _ data: Data,
        output: OutputOptions,
        context: CommandContext,
        client: APIClient,
        created: Bool
    ) throws {
        switch output.format {
        case .json:
            context.terminal.print(try JSONOutput.render(data))
        case .keys:
            let issue = try JSONCoders.decoder.decode(Issue.self, from: data)
            context.terminal.print(issue.key?.wireValue ?? issue.id.rawValue.uuidString)
        case .table:
            let issue = try JSONCoders.decoder.decode(Issue.self, from: data)
            let key = issue.key?.wireValue ?? issue.id.rawValue.uuidString
            context.terminal.print("\(created ? "Created" : "Updated") \(key)  \(issue.title)")
        }
    }
}
