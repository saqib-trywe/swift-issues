import ArgumentParser
import Core
import Foundation

/// Reads and writes the user-level config file.
///
/// Exists so nobody's first experience of the CLI is being told to hand-write a
/// TOML file whose location they have to look up.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and write CLI settings.",
        subcommands: [Get.self, Set.self, Path.self]
    )

    /// The settings a user may set, named as they appear in the file.
    static let settableKeys = ["url", "project"]

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a setting's resolved value.",
            discussion:
                "Resolved, so this shows what a command would actually use, including any environment override."
        )

        @Argument(help: "One of: \(ConfigCommand.settableKeys.joined(separator: ", ")).")
        var key: String

        func run() async throws {
            let context = Runtime.require()
            let configuration = try context.configuration()

            switch key {
            case "url":
                guard let url = configuration.serverURL else { throw CLIError.noServerConfigured }
                context.terminal.print(url.absoluteString)
            case "project":
                guard let project = configuration.defaultProject else {
                    throw CLIError.malformedConfiguration("No default project is set.")
                }
                context.terminal.print(project.wireValue)
            default:
                throw ValidationError(
                    "Unknown setting '\(key)'. Known settings: \(ConfigCommand.settableKeys.joined(separator: ", "))."
                )
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a setting to the config file.")

        @Argument(help: "One of: \(ConfigCommand.settableKeys.joined(separator: ", ")).")
        var key: String

        @Argument(help: "The value to store.")
        var value: String

        func run() async throws {
            let context = Runtime.require()

            // Validated before writing, so a typo fails here rather than on every
            // later command with a message about the file.
            switch key {
            case "url":
                guard let url = URL(string: value), url.scheme != nil else {
                    throw ValidationError("'\(value)' is not a valid URL.")
                }
            case "project":
                guard ProjectKey(value) != nil else {
                    throw ValidationError(
                        "'\(value)' is not a valid project key: two to ten characters, A-Z and 0-9.")
                }
            default:
                throw ValidationError(
                    "Unknown setting '\(key)'. Known settings: \(ConfigCommand.settableKeys.joined(separator: ", "))."
                )
            }

            try ConfigurationWriter.write(key: key, value: value, to: context.configurationFile)
            context.terminal.print("Set \(key) to \(value) in \(context.configurationFile.path).")

            if context.environment["ISSUES_URL"] != nil && key == "url" {
                // Otherwise the next command appears to ignore what was just set.
                context.terminal.printError(
                    "Note: ISSUES_URL is set and overrides this file.")
            }
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the config file's location.")

        func run() async throws {
            let context = Runtime.require()
            context.terminal.print(context.configurationFile.path)
            if let projectFile = CLIConfiguration.findProjectFile(from: context.workingDirectory) {
                context.terminal.print(projectFile.path)
            }
        }
    }
}

/// Rewrites one `key = value` line, leaving the rest of the file alone.
///
/// A read-modify-write of the parsed settings would discard comments, which is a
/// hostile thing to do to a file a person is expected to edit by hand.
enum ConfigurationWriter {

    static func write(key: String, value: String, to file: URL) throws {
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let line = "\(key) = \"\(value)\""

        var lines =
            existing.isEmpty
            ? [] : existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var replaced = false
        for (index, text) in lines.enumerated() {
            let name = text.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            if name == key {
                lines[index] = line
                replaced = true
                break
            }
        }
        if !replaced { lines.append(line) }

        // Trailing blanks accumulate otherwise, one per write.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }

        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: [.atomic])
    }
}
