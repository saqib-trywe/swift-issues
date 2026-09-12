import ArgumentParser
import Core
import Foundation

/// The CLI's top level.
///
/// The exit code is *returned*, not called into `exit()`, so the whole of
/// dispatch — parsing, the default-noun rewrite, error rendering and every code
/// in ticket 11's table — is reachable from a test. Only `main.swift` exits.
public enum IssuesCLI {

    public static let version = "0.1.0"

    /// The production entry point.
    public static func run() async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let home = CLIConfiguration.home(environment: environment)
        let context = CommandContext(
            terminal: .standard(),
            environment: environment,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configurationFile: CLIConfiguration.defaultFile(environment: environment, home: home),
            credentials: KeychainCredentialStore(),
            transport: { URLSessionTransport(baseURL: $0) },
            openEditor: { try Editor.run(template: $0, environment: environment) },
            readStandardInput: {
                String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
        )
        return await run(arguments: Array(CommandLine.arguments.dropFirst()), context: context)
    }

    /// The testable entry point.
    static func run(arguments: [String], context: CommandContext) async -> Int32 {
        let expanded = CommandGrammar.expandingDefaultNoun(
            arguments, knownCommands: Root.knownCommandNames)

        do {
            var command = try Root.parseAsRoot(expanded)
            return try await Runtime.$context.withValue(context) {
                if var asynchronous = command as? any AsyncParsableCommand {
                    try await asynchronous.run()
                } else {
                    try command.run()
                }
                return ExitStatus.success
            }
        } catch {
            return report(error, context: context)
        }
    }

    /// Renders a failure and picks its exit code.
    ///
    /// Help and `--version` arrive here as errors too; they go to stdout at exit
    /// 0, because a user who asked for help did not fail, and piping help into a
    /// pager should work.
    private static func report(_ error: any Error, context: CommandContext) -> Int32 {
        if Root.exitCode(for: error) == ArgumentParser.ExitCode.success {
            context.terminal.print(Root.fullMessage(for: error))
            return ExitStatus.success
        }

        // A parser failure is a usage error. ArgumentParser would exit 64 (EX_USAGE);
        // ticket 11 publishes 2, and that published number is the contract.
        // `CommandError` is not public, so the parser's own classification is what
        // identifies a parse failure.
        if Root.exitCode(for: error) == ArgumentParser.ExitCode.validationFailure {
            context.terminal.printError(Root.fullMessage(for: error))
            return ExitStatus.usage
        }

        context.terminal.printError("Error: \(message(for: error))")
        return ExitStatus.forError(error)
    }

    /// Turns a failure into something worth reading.
    ///
    /// The server's problem `detail` is preferred when there is one: it is written
    /// for this exact situation, where a status name is not.
    static func message(for error: any Error) -> String {
        switch error {
        case let error as CLIError:
            return error.description
        case let error as APIError:
            return message(forAPI: error)
        default:
            return String(describing: error)
        }
    }

    private static func message(forAPI error: APIError) -> String {
        switch error {
        case .notFound(let problem):
            return problem?.detail ?? "Not found."
        // Distinct copy is the point of the server returning 410 rather than 404:
        // "it was deleted" tells you to stop looking, "no such thing" tells you to
        // check what you typed.
        case .gone(let problem):
            return problem?.detail ?? "That was deleted."
        case .unauthenticated(let problem):
            return problem?.detail ?? "Not authenticated. Run `issues auth login`."
        case .forbidden(let problem):
            return problem?.detail ?? "You do not have permission to do that."
        case .conflict(let problem):
            return problem?.detail ?? "That conflicts with something that already exists."
        case .invalidRequest(let problem):
            guard let failures = problem?.errors, !failures.isEmpty else {
                return problem?.detail ?? "The request was rejected as invalid."
            }
            let detail = failures.map { "  \($0.field): \($0.message)" }.joined(separator: "\n")
            return (problem?.detail ?? "The request was rejected as invalid.") + "\n" + detail
        case .rateLimited(let retryAfter, let problem):
            // Ticket 11 asks for minutes: "try again in 840 seconds" is a number a
            // person has to do arithmetic on while already locked out.
            guard let retryAfter else {
                return problem?.detail ?? "Too many failed attempts — try again shortly."
            }
            return "Too many failed attempts — try again in \(humanDuration(retryAfter))."
        case .server(let status, let problem):
            return problem?.detail ?? "The server failed (HTTP \(status))."
        case .unexpectedStatus(let status):
            return "Unexpected response from the server (HTTP \(status))."
        }
    }

    static func humanDuration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        if whole < 60 { return whole == 1 ? "1 second" : "\(whole) seconds" }
        let minutes = Int((Double(whole) / 60).rounded(.up))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
