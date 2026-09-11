import Core
import Foundation

/// Everything a command needs from the outside world, as one injectable value.
///
/// Commands are instantiated by ArgumentParser, so they cannot be given
/// dependencies through an initialiser; this is bound as a task local by the
/// runner instead. That keeps every command testable without a process, a
/// network, or the user's real Keychain.
struct CommandContext: Sendable {
    var terminal: Terminal
    var environment: [String: String]
    var workingDirectory: URL
    var configurationFile: URL
    var credentials: any CredentialStore
    /// Builds a transport for a resolved server. A closure so tests can dispatch
    /// straight into the real router instead of opening a socket.
    var transport: @Sendable (URL) -> any HTTPTransport

    func configuration() throws -> CLIConfiguration {
        try CLIConfiguration.load(
            file: configurationFile,
            workingDirectory: workingDirectory,
            environment: environment)
    }

    func serverURL() throws -> URL {
        guard let url = try configuration().serverURL else { throw CLIError.noServerConfigured }
        return url
    }

    /// `ISSUES_TOKEN` wins and is never written to disk, which is what makes the
    /// CI path leave no trace on the machine.
    func storedToken(forServer server: URL) throws -> String? {
        if let token = environment["ISSUES_TOKEN"], !token.isEmpty { return token }
        return try credentials.token(forServer: Self.credentialKey(for: server))
    }

    /// Credentials are keyed by the server's origin rather than the full URL, so a
    /// trailing slash or a path does not produce a second, invisible credential.
    static func credentialKey(for server: URL) -> String {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? server.absoluteString
    }

    /// A client that must be authenticated. Fails before the call rather than
    /// letting the server return a 401 we would have to translate anyway.
    func client() throws -> APIClient {
        let server = try serverURL()
        guard let token = try storedToken(forServer: server) else {
            throw CLIError.notAuthenticated(server: Self.credentialKey(for: server))
        }
        return APIClient(transport: transport(server), token: { token })
    }

    /// A client for the calls that happen before a token exists: login, health.
    func unauthenticatedClient(server: URL) -> APIClient {
        APIClient(transport: transport(server), token: { nil })
    }
}

/// The binding point for the context.
///
/// A task local because ArgumentParser owns command construction. `require()`
/// traps rather than throwing: an unbound context is a wiring mistake in this
/// module, not a condition any user can reach or act on.
enum Runtime {
    @TaskLocal static var context: CommandContext?

    static func require() -> CommandContext {
        guard let context else {
            fatalError("No CommandContext bound. Commands must be run through IssuesCLI.run.")
        }
        return context
    }
}
