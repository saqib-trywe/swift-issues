import Core
import Foundation

/// Everything the CLI needs to know before it can make a call.
///
/// Ticket 11: `~/.config/issues/config.toml` for the server and a default
/// project, `ISSUES_URL` overriding it for CI, and an optional per-directory
/// `.issues.toml` so a checkout maps to its Project.
struct CLIConfiguration: Sendable, Equatable {
    var serverURL: URL?
    var defaultProject: ProjectKey?

    /// Where the user-level config lives, honouring `XDG_CONFIG_HOME`.
    static func defaultFile(environment: [String: String], home: URL) -> URL {
        let base =
            environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".config")
        return base.appending(path: "issues").appending(path: "config.toml")
    }

    /// The per-directory override file. Named without a leading path so the walk
    /// below can look for it in each ancestor.
    static let projectFileName = ".issues.toml"

    /// Resolves configuration from all three sources, most specific winning.
    ///
    /// Environment beats the user file because that is the CI path; the
    /// per-directory file beats the user file for the project only.
    static func load(
        file: URL?,
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> CLIConfiguration {
        var configuration = CLIConfiguration(serverURL: nil, defaultProject: nil)

        if let file, FileManager.default.fileExists(atPath: file.path) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (key, value) in try FlatTOML.parse(contents) {
                try apply(
                    key: key, value: value, to: &configuration, source: "config file", allowingServer: true)
            }
        }

        if let projectFile = findProjectFile(from: workingDirectory) {
            let contents = try String(contentsOf: projectFile, encoding: .utf8)
            for (key, value) in try FlatTOML.parse(contents) {
                try apply(
                    key: key, value: value, to: &configuration,
                    source: projectFile.lastPathComponent, allowingServer: false)
            }
        }

        if let url = environment["ISSUES_URL"], !url.isEmpty {
            guard let parsed = URL(string: url), parsed.scheme != nil else {
                throw CLIError.malformedConfiguration("ISSUES_URL is not a valid URL: '\(url)'.")
            }
            configuration.serverURL = parsed
        }

        return configuration
    }

    private static func apply(
        key: String,
        value: FlatTOML.Value,
        to configuration: inout CLIConfiguration,
        source: String,
        allowingServer: Bool
    ) throws {
        switch key {
        case "url":
            // A `.issues.toml` is repo-controlled content. Letting a checkout
            // retarget the CLI at another host would make `git clone` enough to
            // redirect someone's traffic, so the project file may not set it.
            guard allowingServer else {
                throw CLIError.malformedConfiguration(
                    "'url' is not allowed in \(source): a per-directory file may set only 'project'.")
            }
            let raw = try value.string(key, source)
            guard let parsed = URL(string: raw), parsed.scheme != nil else {
                throw CLIError.malformedConfiguration("'url' in \(source) is not a valid URL: '\(raw)'.")
            }
            configuration.serverURL = parsed
        case "project":
            let raw = try value.string(key, source)
            guard let parsed = ProjectKey(raw) else {
                throw CLIError.malformedConfiguration(
                    "'project' in \(source) is not a valid project key: '\(raw)'.")
            }
            configuration.defaultProject = parsed
        default:
            throw ConfigurationError.unknownKey(key, source: source)
        }
    }

    /// Walks up from the working directory looking for `.issues.toml`.
    ///
    /// Nearest wins, so a nested package can override its repository's default.
    static func findProjectFile(from directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        while true {
            let candidate = current.appending(path: projectFileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { return nil }
            current = parent
        }
    }
}
