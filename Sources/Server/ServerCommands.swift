import ArgumentParser
import Core
import Foundation

/// `issues-server`'s command surface (ticket 09).
///
/// Structured like the CLI's: the exit code is *returned* rather than passed to
/// `exit()`, so dispatch, rendering and every refusal is reachable from a test.
/// Only `main.swift` exits.
public enum ServerCLI {

    public static let version = "0.1.0"

    /// The production entry point.
    public static func run() async -> Int32 {
        await run(arguments: Array(CommandLine.arguments.dropFirst()), context: .standard())
    }

    /// The testable entry point.
    static func run(arguments: [String], context: ServerContext) async -> Int32 {
        do {
            var command = try Root.parseAsRoot(arguments)
            return try await ServerRuntime.$context.withValue(context) {
                if var asynchronous = command as? any AsyncParsableCommand {
                    try await asynchronous.run()
                } else {
                    try command.run()
                }
                return ServerExit.success
            }
        } catch {
            return report(error, context: context)
        }
    }

    /// Renders a failure and picks its exit code.
    ///
    /// Help and `--version` arrive here as errors too; they go to stdout at exit 0,
    /// because somebody who asked for help did not fail.
    private static func report(_ error: any Error, context: ServerContext) -> Int32 {
        if Root.exitCode(for: error) == ArgumentParser.ExitCode.success {
            context.print(Root.fullMessage(for: error))
            return ServerExit.success
        }
        if Root.exitCode(for: error) == ArgumentParser.ExitCode.validationFailure {
            context.printError(Root.fullMessage(for: error))
            return ServerExit.usage
        }
        context.printError("Error: \(message(for: error))")
        return ServerExit.failure
    }

    /// Maintenance failures already read as sentences aimed at an operator, so they
    /// are printed as written rather than wrapped in a type name.
    static func message(for error: any Error) -> String {
        switch error {
        case let failure as Maintenance.Failure: failure.description
        case let failure as AdminOperations.Failure: failure.description
        case let failure as CustomStringConvertible & Error: failure.description
        default: String(describing: error)
        }
    }
}

/// The server CLI's exit codes. Narrower than the client CLI's published table:
/// nothing scripts against these beyond "did it work".
enum ServerExit {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
}

// MARK: - Context

/// Everything a command touches that a test needs to replace.
public struct ServerContext: Sendable {
    public var environment: [String: String]
    public var print: @Sendable (String) -> Void
    public var printError: @Sendable (String) -> Void
    /// Reads a secret without echoing it. The prompt goes to **stderr**: a prompt on
    /// stdout corrupts `$(issues-server ...)`, which cost a session's debugging once
    /// already on the client side.
    public var readSecret: @Sendable (String) throws -> String
    /// Running the server, injected so `serve` can be dispatched without binding a
    /// port in a unit test.
    public var serve: @Sendable () async throws -> Void
    /// Runs an external tool, for the launchd calls `uninstall` makes.
    public var runProcess: @Sendable ([String]) throws -> Int32
    /// Injected so the tests are not paying production scrypt rounds per case.
    var hasher: PasswordHasher = .production

    /// The home directory this invocation works in.
    ///
    /// `$HOME` first, for the same reason everywhere else in this project does it:
    /// `NSHomeDirectory()` reads the password database, and a test that exercised
    /// that fallback would write into the real home.
    public func home() -> URL {
        URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
    }

    public static func standard() -> ServerContext {
        ServerContext(
            environment: ProcessInfo.processInfo.environment,
            print: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            printError: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            readSecret: { prompt in
                FileHandle.standardError.write(Data(prompt.utf8))
                defer { FileHandle.standardError.write(Data("\n".utf8)) }
                guard let secret = Self.readWithoutEcho(), !secret.isEmpty else {
                    throw ValidationError("No password was entered.")
                }
                return secret
            },
            serve: { try await ServerEntryPoint.main() },
            runProcess: { arguments in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            })
    }

    /// Turns off terminal echo around a single read, restoring it on every path:
    /// leaving a shell with echo disabled looks like a hung terminal.
    static func readWithoutEcho() -> String? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return Swift.readLine(strippingNewline: true)
        }
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet) == 0 else {
            return Swift.readLine(strippingNewline: true)
        }
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        return Swift.readLine(strippingNewline: true)
    }
}

enum ServerRuntime {
    @TaskLocal static var context: ServerContext = .standard()
}

// MARK: - Commands

struct Root: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "issues-server",
        abstract: "The Issues server and its operator commands.",
        version: ServerCLI.version,
        subcommands: [
            Serve.self, BackupCommand.self, RestoreCommand.self, InspectCommand.self,
            AdminCommand.self, ConfigCommand.self, VersionCommand.self,
            InstallAgentCommand.self, UninstallCommand.self,
        ],
        // Running the binary with no arguments serves, because that is what launchd
        // does: a plist naming a subcommand is one more thing to get wrong.
        defaultSubcommand: Serve.self)
}

/// Which database a command works on.
struct DataOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "The database to work on. Defaults to the installed one.")
    var database: String?

    func databaseURL() -> URL {
        if let database { return URL(fileURLWithPath: database) }
        let support = ServerEntryPoint.applicationSupport(
            environment: ServerRuntime.context.environment)
        return ServerEntryPoint.databaseURL(applicationSupport: support)
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve", abstract: "Serve the API. The default.")

    func run() async throws {
        try await ServerRuntime.context.serve()
    }
}

struct BackupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Write a consistent copy of the database to a single file.",
        discussion: """
            Safe to run while the server is serving. Copying the data directory with \
            cp is not equivalent and is not supported: a live database keeps recent \
            commits in its -wal file, so a copied issues.sqlite can be stale or \
            corrupt, and looks fine until the day you need it.
            """)

    @OptionGroup var data: DataOptions
    @Argument(help: "Where to write the backup.") var path: String

    func run() throws {
        let context = ServerRuntime.context
        let report = try Maintenance.backup(
            databaseAt: data.databaseURL(), to: URL(fileURLWithPath: path))
        context.print("Backed up to \(report.url.path) (\(ByteSize.describe(report.byteCount))).")
    }
}

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Say what is in a backup file, without restoring it.")

    @Argument(help: "The backup to look at.") var path: String

    func run() throws {
        let context = ServerRuntime.context
        let url = URL(fileURLWithPath: path)
        let summary = try Maintenance.inspect(url)
        for line in Self.describe(summary, at: url) { context.print(line) }
    }

    static func describe(_ summary: Maintenance.DatabaseSummary, at url: URL) -> [String] {
        var lines = [
            "\(url.path)",
            "  epoch     \(summary.epoch)",
            "  users     \(summary.userCount)",
            "  projects  \(summary.projectCount)",
            "  issues    \(summary.issueCount)",
        ]
        if !summary.isCurrentSchema {
            // Said before a restore rather than discovered during one.
            lines.append("  schema    older than this binary; restoring will migrate it")
        }
        return lines
    }
}

struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Replace the database with a backup.",
        discussion: """
            Stop the server first. Every client will be told to resync on its next \
            pull, because a restore rewinds the change sequence and the watermark \
            they hold no longer means what it did.
            """)

    @OptionGroup var data: DataOptions
    @Argument(help: "The backup to restore.") var path: String

    @Flag(
        name: .long,
        help: "Replace an existing database. The data it holds is moved aside, not deleted.")
    var force = false

    func run() throws {
        let context = ServerRuntime.context
        let report = try Maintenance.restore(
            from: URL(fileURLWithPath: path), to: data.databaseURL(), force: force)
        for line in Self.describe(report, at: data.databaseURL()) { context.print(line) }
    }

    static func describe(_ report: Maintenance.RestoreReport, at target: URL) -> [String] {
        var lines = [
            "Restored \(target.path): "
                + "\(report.summary.userCount) users, "
                + "\(report.summary.projectCount) projects, "
                + "\(report.summary.issueCount) issues."
        ]
        if let aside = report.movedAside {
            lines.append("The database that was there is at \(aside.path).")
        }
        // The consequence an operator has to know about, stated every time: silence
        // here is how a fleet of clients ends up diverging without an error.
        lines.append(
            "New instance epoch \(report.epoch). Every client will full-resync on its next pull; "
                + "queued offline changes are kept.")
        return lines
    }
}

struct AdminCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "admin",
        abstract: "Recovery actions that run on the host.",
        subcommands: [ResetPassword.self])

    struct ResetPassword: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset-password",
            abstract: "Set a user's password from the host.",
            discussion: """
                The only way back in when nobody can log in. Their existing sessions \
                are ended and any login lockout is cleared.
                """)

        @OptionGroup var data: DataOptions
        @Argument(help: "Whose password to set.") var email: String

        func run() throws {
            let context = ServerRuntime.context
            let database = try AppDatabase.open(at: data.databaseURL())

            let first = try context.readSecret("New password for \(email): ")
            let second = try context.readSecret("Repeat password: ")
            guard first == second else {
                throw ValidationError("The passwords do not match. Nothing was changed.")
            }

            let user = try AdminOperations.resetPassword(
                first, forEmail: email, in: database, hasher: context.hasher)
            context.print(
                "Password set for \(user.displayName) <\(user.email)>. "
                    + "Their existing sessions have been ended.")
        }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Check the configuration file.",
        subcommands: [Validate.self])

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate",
            abstract: "Parse the configuration and report what it means.",
            discussion: """
                Earns its place because a typo that surfaces only as an agent which \
                will not start is miserable to diagnose through launchd.
                """)

        @Option(name: .long, help: "The file to check. Defaults to the installed one.")
        var file: String?

        func run() throws {
            let context = ServerRuntime.context
            let url =
                file.map { URL(fileURLWithPath: $0) }
                ?? ServerEntryPoint.configurationURL(
                    applicationSupport: ServerEntryPoint.applicationSupport(
                        environment: context.environment))

            // Loaded with the real environment, because an override that only
            // applies in production is exactly the kind of surprise this command
            // exists to prevent.
            let configuration = try ServerConfiguration.load(
                file: url, environment: context.environment)
            context.print("\(url.path) is valid.")
            context.print("Listening on \(configuration.host):\(configuration.port).")
            if configuration.allowInsecure {
                // Not an error — it is a supported setting — but never silent.
                context.print(
                    "Warning: allowInsecure is on, so tokens may travel in cleartext.")
            }
        }
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version", abstract: "Print the version.")

    func run() throws {
        ServerRuntime.context.print(ServerCLI.version)
    }
}

struct InstallAgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-agent",
        abstract: "Write the LaunchAgent and start the server.",
        discussion: """
            Run by the installer package, and safe to re-run: an existing agent is \
            unloaded first, so an upgrade replaces the job rather than stacking a \
            second one beside it.
            """)

    func run() throws {
        let context = ServerRuntime.context
        let home = context.home()
        let manager = FileManager.default

        // The log directory has to exist first. launchd does not create the parent
        // of StandardOutPath, and a job whose log path is unwritable fails to spawn
        // with nowhere to say so.
        for directory in [
            LaunchAgent.plistURL(home: home).deletingLastPathComponent(),
            LaunchAgent.logURL(home: home).deletingLastPathComponent(),
        ] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try LaunchAgent.plistData(home: home).write(to: LaunchAgent.plistURL(home: home))

        // Idempotent: unload whatever is there before loading this. Bootstrapping
        // over a job that is already loaded fails, which on an upgrade would leave
        // the old binary running and the installer reporting success.
        _ = try? context.runProcess([
            "launchctl", "bootout", LaunchAgent.serviceTarget(uid: getuid()),
        ])
        let status = try context.runProcess([
            "launchctl", "bootstrap", LaunchAgent.domainTarget(uid: getuid()),
            LaunchAgent.plistURL(home: home).path,
        ])
        guard status == 0 else {
            throw ValidationError(
                "launchctl refused to load the agent (status \(status)). "
                    + "The plist is at \(LaunchAgent.plistURL(home: home).path).")
        }

        context.print("Installed \(LaunchAgent.label).")
        context.print(
            "Logs, including the first-run setup token, go to "
                + LaunchAgent.logURL(home: home).path + ".")
    }
}

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stop the agent and remove it, leaving the data behind.",
        discussion: """
            The data directory is kept and its path reported. Deleting somebody's \
            issue tracker as a side effect of removing software is hostile; --purge \
            exists for people who mean it.
            """)

    @Flag(name: .long, help: "Also delete the database and everything beside it.")
    var purge = false

    func run() throws {
        let context = ServerRuntime.context
        let support = ServerEntryPoint.applicationSupport(environment: context.environment)
        let home = context.home()
        let manager = FileManager.default

        // Unloading first: removing the plist under a loaded agent leaves launchd
        // supervising a binary that is no longer there.
        _ = try? context.runProcess([
            "launchctl", "bootout", LaunchAgent.serviceTarget(uid: getuid()),
        ])

        let plist = LaunchAgent.plistURL(home: home)
        let binary = LaunchAgent.binaryURL(home: home)
        for url in [plist, binary] where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
            context.print("Removed \(url.path).")
        }

        let directory = ServerEntryPoint.databaseURL(applicationSupport: support)
            .deletingLastPathComponent()
        guard purge else {
            context.print("Your data is still at \(directory.path).")
            return
        }
        if manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
            context.print("Purged \(directory.path).")
        }
    }
}

/// Byte counts for humans, with fixed units.
///
/// Not `ByteCountFormatter`: its output is locale-dependent, which would make the
/// tests pass or fail depending on the machine's region.
enum ByteSize {
    static func describe(_ bytes: Int) -> String {
        let units: [(threshold: Int, suffix: String)] = [
            (1_073_741_824, "GB"), (1_048_576, "MB"), (1024, "KB"),
        ]
        for unit in units where bytes >= unit.threshold {
            let value = (Double(bytes) / Double(unit.threshold) * 10).rounded() / 10
            return "\(value) \(unit.suffix)"
        }
        return "\(bytes) bytes"
    }
}
