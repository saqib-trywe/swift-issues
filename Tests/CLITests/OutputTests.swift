import Core
import Foundation
import Testing

@testable import CLI

@Suite("Output rendering")
struct OutputTests {

    @Test("columns line up regardless of cell width")
    func columnsLineUp() {
        var table = Table(headers: ["KEY", "TITLE"])
        table.append(["PROJ-1", "Short"])
        table.append(["PROJ-1000", "Longer title"])

        let lines = table.rendered().split(separator: "\n").map(String.init)
        // Where each row's second cell actually begins. Every row must agree, or
        // the column is ragged.
        let starts = zip(lines, ["TITLE", "Short", "Longer title"]).map { line, cell in
            line.range(of: cell).map { line.distance(from: line.startIndex, to: $0.lowerBound) }
        }
        #expect(Set(starts).count == 1, "the second column starts at a different offset per row")
        #expect(starts.first! != nil)
    }

    /// Trailing spaces are invisible and survive a copy-paste into a commit
    /// message or a diff.
    @Test("no row has trailing whitespace")
    func noTrailingWhitespace() {
        var table = Table(headers: ["KEY", "TITLE"])
        table.append(["PROJ-1", "Short"])
        table.append(["PROJ-1000", "A"])

        for line in table.rendered().split(separator: "\n") {
            #expect(line == line.reversed().drop { $0 == " " }.reversed().map(String.init).joined())
        }
    }

    @Test("an empty table renders as nothing")
    func emptyTableRendersAsNothing() {
        #expect(Table(headers: ["KEY"]).rendered().isEmpty)
    }

    @Test("a long title is truncated with an ellipsis inside the budget")
    func longTitleIsTruncated() {
        let truncated = String(repeating: "a", count: 100).truncated(to: 10)
        #expect(truncated.count == 10)
        #expect(truncated.hasSuffix("…"))
    }

    @Test("a short title is left alone")
    func shortTitleIsLeftAlone() {
        #expect("short".truncated(to: 10) == "short")
    }

    /// A field this build has never heard of has to survive to stdout, or the
    /// lenient decoding elsewhere buys a script nothing.
    @Test("JSON rendering preserves fields the CLI does not model")
    func jsonPreservesUnknownFields() throws {
        let payload = Data(#"{"title":"x","somethingNew":{"nested":[1,2]}}"#.utf8)
        let rendered = try JSONOutput.render(payload)

        #expect(rendered.contains("somethingNew"))
        #expect(rendered.contains("nested"))
    }

    /// Sorted keys, so output is diffable between runs.
    @Test("JSON rendering is deterministic")
    func jsonRenderingIsDeterministic() throws {
        let payload = Data(#"{"b":1,"a":2}"#.utf8)
        let first = try JSONOutput.render(payload)
        let second = try JSONOutput.render(payload)

        #expect(first == second)
        #expect(first.range(of: "\"a\"")!.lowerBound < first.range(of: "\"b\"")!.lowerBound)
    }

    /// Escaped slashes in a URL are legal JSON but unreadable in a terminal.
    @Test("slashes are not escaped")
    func slashesAreNotEscaped() throws {
        let rendered = try JSONOutput.render(Data(#"{"url":"https://x.test/a"}"#.utf8))
        #expect(rendered.contains("https://x.test/a"))
    }

    @Test("a payload without items is refused rather than silently empty")
    func payloadWithoutItemsIsRefused() {
        #expect(throws: CLIError.self) {
            try JSONOutput.items(in: Data(#"{"unexpected":true}"#.utf8))
        }
    }

    @Test("--quiet wins over --json")
    func quietWinsOverJSON() throws {
        var options = try OutputOptions.parse(["--json", "--quiet"])
        #expect(options.format == .keys)

        options = try OutputOptions.parse(["--json"])
        #expect(options.format == .json)

        options = try OutputOptions.parse([])
        #expect(options.format == .table)
    }

    /// NO_COLOR is honoured at any value, and a redirected stdout is never
    /// coloured regardless.
    @Test(
        "colour is off unless stdout is a terminal and NO_COLOR is unset",
        arguments: [
            (true, [String: String](), true),
            (true, ["NO_COLOR": "1"], false),
            (true, ["NO_COLOR": ""], false),
            (false, [String: String](), false),
        ])
    func colourRules(isTerminal: Bool, environment: [String: String], expected: Bool) {
        let terminal = Terminal(
            output: RecordingSink(), error: RecordingSink(),
            isOutputTerminal: isTerminal, isInputTerminal: false,
            readLine: { nil }, readSecret: { nil })

        #expect(terminal.usesColour(environment: environment) == expected)
    }
}
