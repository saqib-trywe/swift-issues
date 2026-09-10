import Foundation
import Hummingbird

/// The executable's shell.
///
/// Deliberately thin, like `URLSessionTransport` on the client side: anything worth
/// testing lives elsewhere in this library. Configuration loading (the TOML file
/// and `ISSUES_*` overrides from ticket 09) is a later slice; the defaults below
/// are the ones that ticket specifies.
public enum ServerEntryPoint {

    /// Ticket 09: bind to loopback by default, so the server cannot be exposed to a
    /// network in cleartext by an admin who has not set up a reverse proxy yet. The
    /// failure mode should be "I can't reach it from my laptop", not "I have been
    /// serving bearer tokens over the LAN for a month".
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 8080

    /// Ticket 09: everything under the user's home, so the install is rootless.
    ///
    /// Pure, so it is testable without creating anything. Creating the directory is
    /// `prepareDirectory(at:)` below, deliberately separate — a test asserting the
    /// path should not leave a folder in the developer's home.
    public static func databaseURL(applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "Issues").appending(path: "issues.sqlite")
    }

    /// `0700`: the database holds every issue and every session hash.
    static func prepareDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    public static func main() async throws {
        let url = databaseURL(applicationSupport: .applicationSupportDirectory)
        try prepareDirectory(at: url)
        let database = try AppDatabase.open(at: url)
        let application = Application(
            router: IssuesRouter.build(database: database),
            configuration: .init(address: .hostname(defaultHost, port: defaultPort))
        )
        try await application.runService()
    }
}
