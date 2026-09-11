import Foundation

/// Where the server reads its settings.
///
/// Ticket 09: a TOML file with `ISSUES_*` environment overrides. Env exists for
/// secrets and for scripted deploys, which must be able to override a file baked
/// into an image — and env-only would be miserable under launchd, where setting a
/// variable means editing a plist and reloading the agent.
public struct ServerConfiguration: Sendable, Equatable {
    public var host: String
    public var port: Int
    /// Refuses to issue or accept tokens over plaintext unless explicitly set, so a
    /// misconfigured proxy cannot quietly serve bearer tokens in cleartext.
    public var allowInsecure: Bool
    public var instanceName: String?

    public static let `default` = ServerConfiguration(
        // Loopback: the failure mode should be "I can't reach it from my laptop",
        // not "I have been serving bearer tokens over the LAN for a month".
        host: "127.0.0.1", port: 8080, allowInsecure: false, instanceName: nil)

    /// Reads settings, applying environment overrides over file values over defaults.
    ///
    /// A missing file is not an error; an unreadable or malformed one is.
    public static func load(file: URL?, environment: [String: String]) throws
        -> ServerConfiguration
    {
        var config = ServerConfiguration.default

        if let file, FileManager.default.fileExists(atPath: file.path) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (key, value) in try FlatTOML.parse(contents) {
                try apply(key: key, value: value, to: &config, source: "config file")
            }
        }

        for (variable, value) in environment where variable.hasPrefix("ISSUES_") {
            guard let key = Self.keysByEnvironmentVariable[variable] else { continue }
            try apply(key: key, value: .init(raw: value), to: &config, source: variable)
        }

        return config
    }

    /// Human-readable check for `issues-server config validate`.
    ///
    /// Exists because a typo that surfaces only as an agent which will not start is
    /// miserable to diagnose through launchd (ticket 09).
    public static func validate(file: URL?) -> String {
        do {
            let config = try load(file: file, environment: [:])
            return "Configuration is valid. Listening on \(config.host):\(config.port)."
        } catch {
            return "Configuration is invalid: \(error)"
        }
    }

    /// Only the keys a file may set. Env variables map onto the same names, so the
    /// two sources cannot drift apart.
    static let keysByEnvironmentVariable: [String: String] = [
        "ISSUES_HOST": "host",
        "ISSUES_PORT": "port",
        "ISSUES_ALLOW_INSECURE": "allowInsecure",
        "ISSUES_INSTANCE_NAME": "instanceName",
    ]

    private static func apply(
        key: String, value: FlatTOML.Value, to config: inout ServerConfiguration, source: String
    ) throws {
        switch key {
        case "host": config.host = try value.string(key, source)
        case "port": config.port = try value.integer(key, source)
        case "allowInsecure": config.allowInsecure = try value.boolean(key, source)
        case "instanceName": config.instanceName = try value.string(key, source)
        default:
            // An unknown key is refused rather than ignored: a typo would otherwise
            // leave an admin believing a setting applied when it did not.
            throw ConfigurationError.unknownKey(key, source: source)
        }
    }
}

public enum ConfigurationError: Error, CustomStringConvertible, Sendable {
    case unknownKey(String, source: String)
    case unsupportedSyntax(line: Int, text: String)
    case wrongType(key: String, expected: String, source: String)

    public var description: String {
        switch self {
        case .unknownKey(let key, let source):
            "Unknown setting '\(key)' in \(source)."
        case .unsupportedSyntax(let line, let text):
            """
            Line \(line) is not a supported setting: '\(text)'. \
            This reads a flat subset of TOML — one `key = value` per line, with \
            strings, integers and booleans. Tables and arrays are not supported.
            """
        case .wrongType(let key, let expected, let source):
            "Setting '\(key)' in \(source) must be \(expected)."
        }
    }
}

/// A deliberately small reader for flat `key = value` TOML.
///
/// It reads what ticket 09's configuration needs and **refuses everything else**.
/// A partial TOML implementation that silently skipped tables or arrays would let an
/// admin believe a setting applied when it had not — and for `allowInsecure` that
/// means serving bearer tokens in cleartext while believing otherwise.
enum FlatTOML {

    struct Value {
        let raw: String

        func string(_ key: String, _ source: String) throws -> String {
            if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
                return String(raw.dropFirst().dropLast())
            }
            // An environment variable arrives unquoted, which is expected.
            guard !source.hasPrefix("ISSUES_") else { return raw }
            throw ConfigurationError.wrongType(
                key: key, expected: "a quoted string", source: source)
        }

        func integer(_ key: String, _ source: String) throws -> Int {
            guard let value = Int(raw) else {
                throw ConfigurationError.wrongType(
                    key: key, expected: "an integer", source: source)
            }
            return value
        }

        func boolean(_ key: String, _ source: String) throws -> Bool {
            switch raw {
            case "true": true
            case "false": false
            default:
                throw ConfigurationError.wrongType(
                    key: key, expected: "true or false", source: source)
            }
        }
    }

    static func parse(_ contents: String) throws -> [(key: String, value: Value)] {
        var settings: [(key: String, value: Value)] = []

        for (offset, rawLine) in contents.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            let number = offset + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            guard let separator = line.firstIndex(of: "="),
                separator != line.startIndex
            else {
                throw ConfigurationError.unsupportedSyntax(line: number, text: line)
            }

            let key = String(line[line.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty, !value.isEmpty,
                // Tables and arrays are out of scope, and must not be skipped.
                !key.hasPrefix("["), !value.hasPrefix("[")
            else {
                throw ConfigurationError.unsupportedSyntax(line: number, text: line)
            }

            settings.append((key, Value(raw: value)))
        }

        return settings
    }

    /// Strips a trailing `#` comment, leaving `#` inside a quoted string alone — a
    /// colour like `"#2D6CDF"` must survive.
    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        for index in line.indices {
            if line[index] == "\"" { inQuotes.toggle() }
            if line[index] == "#" && !inQuotes { return String(line[line.startIndex..<index]) }
        }
        return line
    }
}
