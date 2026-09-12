import ArgumentParser
import Core
import Foundation

/// Obtaining, inspecting and discarding a session.
///
/// `login` is the only place in the whole CLI where a password is handled, which
/// is why it is its own command rather than an implicit prompt on a 401.
struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Log in, log out, and check the current session.",
        subcommands: [Login.self, Logout.self, Status.self, Token.self]
    )

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Exchange an email and password for a stored token.",
            discussion: """
                This is the only command that handles a password. It is sent once, \
                over the configured server URL, and never stored; what is stored is \
                the token the server returns.
                """)

        @Option(help: "The server to log in to. Defaults to the configured URL.")
        var server: String?

        @Option(help: "Email address. Prompted for if a terminal is available.")
        var email: String?

        @Flag(help: "Replace an existing session instead of leaving it alone.")
        var force = false

        func run() async throws {
            let context = Runtime.require()

            let url: URL
            if let server {
                guard let parsed = URL(string: server), parsed.scheme != nil else {
                    throw ValidationError("'\(server)' is not a valid URL.")
                }
                url = parsed
            } else {
                url = try context.serverURL()
            }
            let key = CommandContext.credentialKey(for: url)

            // Minting a token per invocation is what produces the sprawl that makes
            // an Admin's revocation list useless, so an existing session stops this
            // rather than being silently replaced.
            if !force, let existing = try context.credentials.token(forServer: key) {
                let client = APIClient(transport: context.transport(url), token: { existing })
                if let user = try? await client.send(UserEndpoints.me(), expecting: User.self) {
                    context.terminal.print(
                        "Already logged in to \(key) as \(user.displayName) <\(user.email)>.")
                    context.terminal.print("Use --force to replace this session.")
                    return
                }
                // A token that no longer works is not a session worth protecting.
            }

            let address = try resolveEmail(context)
            let password = try readPassword(context)

            let response = try await context.unauthenticatedClient(server: url)
                .send(AuthEndpoints.login(email: address, password: password), expecting: LoginResponse.self)

            try context.credentials.store(response.token, forServer: key)
            context.terminal.print(
                "Logged in to \(key) as \(response.user.displayName) <\(response.user.email)>.")

            await VersionCheck.warnIfSkewed(
                client: APIClient(transport: context.transport(url), token: { response.token }),
                terminal: context.terminal)
        }

        private func resolveEmail(_ context: CommandContext) throws -> String {
            if let email { return email }
            // Failing by name beats hanging on a prompt nobody can see, which is
            // what a CI job would otherwise do until its timeout.
            guard context.terminal.isInputTerminal else { throw CLIError.missingInput(flag: "--email") }
            context.terminal.error.write("Email: ")
            guard let entered = context.terminal.readLine(), !entered.isEmpty else {
                throw CLIError.missingInput(flag: "--email")
            }
            return entered
        }

        /// Deliberately has no flag. A password in argv is visible in `ps` output
        /// and lands in shell history; `ISSUES_TOKEN` is the scripted path.
        private func readPassword(_ context: CommandContext) throws -> String {
            guard context.terminal.isInputTerminal else {
                throw CLIError.missingInput(flag: "ISSUES_TOKEN (there is no password flag, by design)")
            }
            context.terminal.error.write("Password: ")
            guard let entered = context.terminal.readSecret(), !entered.isEmpty else {
                throw CLIError.missingInput(flag: "a password")
            }
            context.terminal.error.write("\n")
            return entered
        }
    }

    struct Logout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Discard the stored token for a server.")

        @Option(help: "The server to log out of. Defaults to the configured URL.")
        var server: String?

        func run() async throws {
            let context = Runtime.require()
            let url: URL
            if let server {
                guard let parsed = URL(string: server), parsed.scheme != nil else {
                    throw ValidationError("'\(server)' is not a valid URL.")
                }
                url = parsed
            } else {
                url = try context.serverURL()
            }
            let key = CommandContext.credentialKey(for: url)

            guard try context.credentials.token(forServer: key) != nil else {
                context.terminal.print("Not logged in to \(key).")
                return
            }
            try context.credentials.remove(forServer: key)
            // The server-side session is not revoked: the token is opaque and the
            // local copy is gone, and revoking needs an endpoint ticket 11 puts
            // under `auth token revoke`.
            context.terminal.print("Logged out of \(key). The token is no longer stored on this machine.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show who you are, where, and whether it still works.",
            discussion: "The first thing to run when something is not behaving.")

        func run() async throws {
            let context = Runtime.require()
            let url = try context.serverURL()
            let key = CommandContext.credentialKey(for: url)

            context.terminal.print("Server:      \(key)")

            guard let token = try context.storedToken(forServer: url) else {
                context.terminal.print("Session:     none stored")
                throw CLIError.notAuthenticated(server: key)
            }

            let source =
                context.environment["ISSUES_TOKEN"].map { _ in "ISSUES_TOKEN" } ?? "stored credential"
            context.terminal.print("Credential:  \(source)")

            let client = APIClient(transport: context.transport(url), token: { token })
            let user = try await client.send(UserEndpoints.me(), expecting: User.self)
            context.terminal.print("User:        \(user.displayName) <\(user.email)>")
            context.terminal.print("Role:        \(user.role.wireValue)")

            await VersionCheck.warnIfSkewed(client: client, terminal: context.terminal)
        }
    }
}

/// The opportunistic API-version check.
///
/// Ticket 11 runs this on `auth login` and `auth status` only. Checking on every
/// invocation would double the latency of a tool whose whole appeal is being
/// fast, to catch something that changes maybe twice a year.
enum VersionCheck {
    /// What this build knows how to speak.
    static let supportedAPIVersions: Set<String> = ["v1"]

    static func warnIfSkewed(client: APIClient, terminal: Terminal) async {
        // Never blocks and never fails the command: a warning that can break a
        // working login is worse than the skew it reports.
        guard let meta = try? await client.send(InstanceEndpoints.meta(), expecting: ServerMeta.self)
        else { return }

        terminal.print("Instance:    \(meta.instanceName) (server \(meta.serverVersion))")

        let unknown = Set(meta.apiVersions).subtracting(supportedAPIVersions)
        guard !unknown.isEmpty else { return }
        // stderr, so --json output on stdout stays machine-readable.
        terminal.printError(
            "Warning: the server offers API \(unknown.sorted().joined(separator: ", ")), which this CLI does not understand. Some commands may be unavailable until you upgrade."
        )
    }
}
