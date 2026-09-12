import ArgumentParser
import Core
import Foundation

/// Users. There is no delete: a User is referenced as reporter, assignee and
/// comment author permanently, so removal would orphan history.
struct UserCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "user",
        abstract: "Work with users.",
        discussion: """
            Creating, deactivating and resetting somebody else's password require \
            the Admin role. Those commands are listed for everyone and rejected at \
            call, so --help works offline and without a token.
            """,
        subcommands: [List.self, Show.self, Me.self, Create.self, Deactivate.self, Password.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List users.")

        @Flag(help: "Include deactivated users.")
        var all = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let data = try await context.client().data(
                for: UserEndpoints.list(page: Pagination(limit: Pagination.maximumLimit)))
            let items = try JSONOutput.items(in: data)
            let users = try JSONCoders.decoder.decode(
                [User].self, from: try JSONSerialization.data(withJSONObject: items))
            let visible = all ? users : users.filter(\.active)

            switch output.format {
            case .json:
                context.terminal.print(try JSONOutput.render(items))
            case .keys:
                for user in visible { context.terminal.print(user.email) }
            case .table:
                var table = Table(headers: ["EMAIL", "NAME", "ROLE", "STATE"])
                for user in visible {
                    table.append([
                        user.email, user.displayName, user.role.wireValue,
                        user.active ? "active" : "deactivated",
                    ])
                }
                context.terminal.print(table.rendered())
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one user.")

        @Argument(help: "An email address, a display name, or a user id.")
        var user: String

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let id = try await UserLookup.resolve(user, client: client)
            let data = try await client.data(for: UserEndpoints.get(id))
            try UserCommand.render(data, output: output, context: context)
        }
    }

    struct Me: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the authenticated user.",
            discussion: "Saves resolving your own id first, which every client would otherwise have to do.")

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let data = try await context.client().data(for: UserEndpoints.me())
            try UserCommand.render(data, output: output, context: context)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a user. Admin only.",
            discussion: """
                A new account has no password and cannot log in until one is set. \
                Pass --password to set it here, or use `issues user password` later. \
                The password is prompted for at a terminal rather than taken as a \
                flag, because a flag lands in shell history and in `ps` output.
                """)

        @Argument(help: "The user's email address.")
        var email: String

        @Option(name: [.short, .long], help: "Display name. Defaults to the email address.")
        var name: String?

        @Option(help: "Role: member or admin.")
        var role: String = "member"

        @Flag(help: "Prompt for an initial password.")
        var password = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()

            let failures = Validation.email(email)
            guard failures.isEmpty else {
                throw ValidationError(failures.map(\.message).joined(separator: " "))
            }
            let parsedRole = Role(wireValue: role)
            if case .unknown = parsedRole {
                throw ValidationError("Unknown role '\(role)'. Known roles: member, admin.")
            }

            // Read the password before creating, so a cancelled prompt does not
            // leave a half-made account behind.
            let secret = password ? try UserCommand.readNewPassword(context) : nil

            let id = User.ID(UUIDv7.generate())
            let data = try await client.data(
                for: try UserEndpoints.create(
                    id: id, UserCreate(email: email, displayName: name ?? email, role: parsedRole)))

            if let secret {
                try await client.send(
                    try UserEndpoints.setPassword(id: id, PasswordChange(password: secret)))
            }

            switch output.format {
            case .json: context.terminal.print(try JSONOutput.render(data))
            case .keys: context.terminal.print(email)
            case .table:
                context.terminal.print("Created \(email) as \(parsedRole.wireValue).")
                if secret == nil {
                    // Otherwise the account looks ready and silently is not.
                    context.terminal.print(
                        "No password is set, so they cannot log in yet. "
                            + "Set one with `issues user password \(email)`.")
                }
            }
        }
    }

    struct Deactivate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Deactivate or reactivate a user. Admin only.",
            discussion: """
                Deactivating ends every session the user holds immediately. Their \
                issues and comments are untouched — a user is never deleted, because \
                they are referenced as reporter and author permanently.
                """)

        @Argument(help: "An email address, a display name, or a user id.")
        var user: String

        @Flag(help: "Reactivate instead.")
        var undo = false

        @Flag(name: [.customLong("yes"), .customShort("y")], help: "Skip the confirmation.")
        var assumeYes = false

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()
            let id = try await UserLookup.resolve(user, client: client)
            let target = try await client.send(UserEndpoints.get(id), expecting: User.self)

            if !undo {
                try context.confirm(
                    "Deactivate \(target.displayName) <\(target.email)>? "
                        + "They will be logged out everywhere immediately.",
                    assumeYes: assumeYes)
            }

            var patch = UserPatch()
            patch.active = .set(undo)
            _ = try await client.data(for: try UserEndpoints.patch(id: id, patch))
            context.terminal.print(
                "\(undo ? "Reactivated" : "Deactivated") \(target.email).")
        }
    }

    struct Password: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a password.",
            discussion: """
                Setting your own requires the current one. An Admin may set anybody \
                else's without it, which is how a forgotten password is recovered. \
                Either way, every session that user holds is ended.

                There is no --password flag: a password passed as an argument is \
                visible in `ps` output and lands in shell history.
                """)

        @Argument(help: "An email address, a display name, or a user id. Defaults to you.")
        var user: String?

        func run() async throws {
            let context = Runtime.require()
            let client = try context.client()

            let me = try await client.send(UserEndpoints.me(), expecting: User.self)
            let id: User.ID
            if let user {
                id = try await UserLookup.resolve(user, client: client)
            } else {
                id = me.id
            }

            // Only your own change needs the current password, and asking for one
            // you are not going to send would be theatre.
            var current: String?
            if id == me.id {
                current = try UserCommand.readSecret(context, prompt: "Current password: ")
            }
            let replacement = try UserCommand.readNewPassword(context)

            try await client.send(
                try UserEndpoints.setPassword(
                    id: id, PasswordChange(password: replacement, currentPassword: current)))

            context.terminal.print(
                id == me.id
                    ? "Password changed. Every other session has been ended; log in again elsewhere."
                    : "Password set. That user has been logged out everywhere.")

            if id == me.id {
                // Our own token was just revoked, so leaving it stored would make the
                // next command fail with a confusing 401.
                let server = try context.serverURL()
                try? context.credentials.remove(forServer: CommandContext.credentialKey(for: server))
                context.terminal.print("Run `issues auth login` to continue.")
            }
        }
    }

    static func render(_ data: Data, output: OutputOptions, context: CommandContext) throws {
        switch output.format {
        case .json:
            context.terminal.print(try JSONOutput.render(data))
        case .keys:
            context.terminal.print(try JSONCoders.decoder.decode(User.self, from: data).email)
        case .table:
            let user = try JSONCoders.decoder.decode(User.self, from: data)
            context.terminal.print("\(user.displayName) <\(user.email)>")
            context.terminal.print("")
            context.terminal.print("Role:      \(user.role.wireValue)")
            context.terminal.print("State:     \(user.active ? "active" : "deactivated")")
        }
    }

    /// Reads a new password twice, because a mistyped one that nobody can see is
    /// an account locked out by a typo.
    static func readNewPassword(_ context: CommandContext) throws -> String {
        let first = try readSecret(context, prompt: "New password: ")
        let second = try readSecret(context, prompt: "Repeat password: ")
        guard first == second else {
            throw CLIError.malformedConfiguration("The passwords did not match; nothing was changed.")
        }
        let failures = Validation.password(first)
        guard failures.isEmpty else {
            throw CLIError.malformedConfiguration(failures.map(\.message).joined(separator: " "))
        }
        return first
    }

    static func readSecret(_ context: CommandContext, prompt: String) throws -> String {
        guard context.terminal.isInputTerminal else {
            throw CLIError.missingInput(
                flag: "a terminal (there is no password flag, by design: it would land in shell history)")
        }
        context.terminal.output.write(prompt)
        guard let entered = context.terminal.readSecret(), !entered.isEmpty else {
            throw CLIError.missingInput(flag: "a password")
        }
        context.terminal.print()
        return entered
    }
}
