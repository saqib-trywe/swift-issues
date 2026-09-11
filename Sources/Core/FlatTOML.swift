import Foundation

// Shared by the server's `config.toml` and the CLI's, so the two cannot drift
// into accepting different dialects of the same file format.

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
public enum FlatTOML {

    public struct Value {
        public let raw: String

        public init(raw: String) { self.raw = raw }

        public func string(_ key: String, _ source: String) throws -> String {
            if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
                return String(raw.dropFirst().dropLast())
            }
            // An environment variable arrives unquoted, which is expected.
            guard !source.hasPrefix("ISSUES_") else { return raw }
            throw ConfigurationError.wrongType(
                key: key, expected: "a quoted string", source: source)
        }

        public func integer(_ key: String, _ source: String) throws -> Int {
            guard let value = Int(raw) else {
                throw ConfigurationError.wrongType(
                    key: key, expected: "an integer", source: source)
            }
            return value
        }

        public func boolean(_ key: String, _ source: String) throws -> Bool {
            switch raw {
            case "true": true
            case "false": false
            default:
                throw ConfigurationError.wrongType(
                    key: key, expected: "true or false", source: source)
            }
        }
    }

    public static func parse(_ contents: String) throws -> [(key: String, value: Value)] {
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
