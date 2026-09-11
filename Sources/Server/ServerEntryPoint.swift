import Foundation
import Hummingbird
import ServiceLifecycle

/// The executable's shell.
///
/// Deliberately thin, like `URLSessionTransport` on the client side: every piece it
/// composes is tested on its own, and only the composition is not.
public enum ServerEntryPoint {

    public static let defaultHost = ServerConfiguration.default.host
    public static let defaultPort = ServerConfiguration.default.port

    /// Ticket 09: everything under the user's home, so the install is rootless.
    ///
    /// Pure, so it is testable without creating anything.
    public static func databaseURL(applicationSupport: URL) -> URL {
        directory(applicationSupport: applicationSupport).appending(path: "issues.sqlite")
    }

    public static func configurationURL(applicationSupport: URL) -> URL {
        directory(applicationSupport: applicationSupport).appending(path: "config.toml")
    }

    /// The token file an admin `cat`s once. Self-deleting on use.
    public static func bootstrapTokenURL(applicationSupport: URL) -> URL {
        directory(applicationSupport: applicationSupport).appending(path: "bootstrap-token")
    }

    static func directory(applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "Issues")
    }

    /// `0700`: the directory holds every issue and every session hash.
    static func prepareDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Decides how a fresh instance gets its first Admin, returning a token if one
    /// was minted and published.
    ///
    /// Env seeding takes precedence: a one-time token printed to a log is hostile to
    /// automation, so a scripted deploy should never have to read one. Extracted from
    /// `main` because the precedence is real logic rather than composition.
    static func prepareFirstRun(
        database: AppDatabase,
        environment: [String: String],
        tokenURL: URL
    ) throws -> String? {
        let bootstrap = BootstrapService(database: database)
        if try bootstrap.seedFromEnvironment(environment) { return nil }
        guard let token = try bootstrap.beginIfNeeded() else { return nil }
        try BootstrapService.publish(token: token, to: tokenURL)
        return token
    }

    public static func main() async throws {
        let support: URL = .applicationSupportDirectory
        let url = databaseURL(applicationSupport: support)
        try prepareDirectory(at: url)

        let configuration = try ServerConfiguration.load(
            file: configurationURL(applicationSupport: support),
            environment: ProcessInfo.processInfo.environment)
        let database = try AppDatabase.open(at: url)

        let tokenURL = bootstrapTokenURL(applicationSupport: support)
        if let token = try prepareFirstRun(
            database: database, environment: ProcessInfo.processInfo.environment,
            tokenURL: tokenURL)
        {
            print("Setup token (valid 60 minutes): \(token)")
            print("Also written to \(tokenURL.path)")
        }

        let application = Application(
            router: IssuesRouter.build(database: database),
            configuration: .init(
                address: .hostname(configuration.host, port: configuration.port))
        )

        // Graceful shutdown drains in-flight requests and stops the reaper promptly.
        let group = ServiceGroup(
            services: [application, SessionReaper(sessions: SessionRepository(database: database))],
            logger: application.logger)
        try await group.run()
    }
}
