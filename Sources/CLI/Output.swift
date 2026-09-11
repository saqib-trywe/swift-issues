import ArgumentParser
import Core
import Foundation

/// The output flags every read command shares.
struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit the API payload as JSON, unreshaped.")
    var json = false

    @Flag(name: [.short, .long], help: "Print bare keys, one per line, for xargs.")
    var quiet = false

    /// `--quiet` wins: it exists to be piped, and a caller passing both wants the
    /// narrowest output, not an argument about it.
    var format: OutputFormat { quiet ? .keys : (json ? .json : .table) }
}

enum OutputFormat {
    case table
    case json
    case keys
}

/// Renders JSON for `--json`.
///
/// Ticket 11 requires the API payload rather than a CLI schema, so this
/// re-serialises what the server actually sent instead of re-encoding a decoded
/// model — a field this build has never heard of survives, which is what makes
/// the lenient decoding elsewhere worth anything to a script.
enum JSONOutput {

    static func render(_ data: Data) throws -> String {
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try render(value)
    }

    static func render(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// Pulls `items` out of a paginated payload, keeping each element exactly as
    /// the server sent it, so pages can be concatenated without reshaping.
    static func items(in data: Data) throws -> [Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any], let items = object["items"] as? [Any] else {
            throw CLIError.malformedConfiguration("The server returned an unexpected list payload.")
        }
        return items
    }
}

/// A left-aligned column table.
///
/// Deliberately plain: ticket 11 states the human format is not a stable
/// interface, and anything a script should depend on belongs in `--json`.
struct Table {
    var headers: [String]
    var rows: [[String]] = []

    mutating func append(_ row: [String]) { rows.append(row) }

    func rendered() -> String {
        guard !rows.isEmpty else { return "" }

        // Widths from display width, not `count`: an emoji in a title would
        // otherwise push every following column out of alignment.
        var widths = headers.map { $0.displayWidth }
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.displayWidth)
            }
        }

        func line(_ cells: [String]) -> String {
            cells.enumerated()
                .map { index, cell in
                    // The last column is never padded, so there is no invisible
                    // trailing whitespace to confuse a diff or a copy-paste.
                    index == cells.count - 1
                        ? cell
                        : cell + String(repeating: " ", count: widths[index] - cell.displayWidth + 2)
                }
                .joined()
        }

        return ([line(headers)] + rows.map(line)).joined(separator: "\n")
    }
}

extension String {
    /// An approximation of terminal cells: wide scalars count double.
    var displayWidth: Int {
        unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.properties.isEmojiPresentation ? 2 : 1)
        }
    }

    /// Shortens for a table cell, keeping the ellipsis inside the budget.
    func truncated(to limit: Int) -> String {
        guard count > limit, limit > 1 else { return self }
        return String(prefix(limit - 1)) + "…"
    }
}
