import Foundation
import Testing

@testable import AppCore

/// Descriptions and comments are Markdown source and the client renders them
/// (ticket 01). SwiftUI honours inline styling but ignores block structure, so
/// without this a list renders as run-together text with stray hyphens.
@Suite("Markdown blocks")
struct MarkdownBlockTests {

    private func text(of block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let value), .quote(let value): String(value.characters)
        case .heading(_, let value): String(value.characters)
        case .listItem(_, _, let value): String(value.characters)
        case .codeBlock(let value): value
        }
    }

    @Test("empty source produces nothing")
    func emptySourceProducesNothing() {
        #expect(MarkdownBlocks.parse("").isEmpty)
        #expect(MarkdownBlocks.parse("   \n\n  ").isEmpty)
    }

    @Test("plain text is one paragraph")
    func plainTextIsOneParagraph() {
        let blocks = MarkdownBlocks.parse("Just a sentence.")
        #expect(blocks.count == 1)
        #expect(text(of: blocks[0]) == "Just a sentence.")
    }

    /// A blank line is a paragraph break, and collapsing it would run two thoughts
    /// together.
    @Test("a blank line separates paragraphs")
    func blankLineSeparatesParagraphs() {
        let blocks = MarkdownBlocks.parse("First thought.\n\nSecond thought.")
        #expect(blocks.count == 2)
        #expect(text(of: blocks[0]) == "First thought.")
        #expect(text(of: blocks[1]) == "Second thought.")
    }

    @Test("a heading keeps its level and loses its hashes")
    func headingKeepsItsLevel() {
        let blocks = MarkdownBlocks.parse("## Steps to reproduce")
        guard case .heading(let level, _) = blocks.first else {
            Issue.record("expected a heading, got \(String(describing: blocks.first))")
            return
        }
        #expect(level == 2)
        #expect(text(of: blocks[0]) == "Steps to reproduce")
        #expect(!text(of: blocks[0]).contains("#"))
    }

    /// The failure this exists to prevent: a bulleted list rendering as one blob
    /// with hyphens in it.
    @Test("a bulleted list becomes separate items without its hyphens")
    func bulletedListBecomesSeparateItems() {
        let blocks = MarkdownBlocks.parse("- first\n- second\n- third")

        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { if case .listItem = $0 { return true } else { return false } })
        #expect(blocks.map(text(of:)) == ["first", "second", "third"])
        #expect(blocks.allSatisfy { !text(of: $0).contains("-") })
    }

    @Test("a bulleted item has no ordinal")
    func bulletedItemHasNoOrdinal() {
        guard case .listItem(let ordinal, _, _) = MarkdownBlocks.parse("- only").first else {
            Issue.record("expected a list item")
            return
        }
        #expect(ordinal == nil)
    }

    /// A numbered list has to keep its numbers, or "step 3" stops meaning anything.
    @Test("a numbered list keeps its numbers")
    func numberedListKeepsItsNumbers() {
        let blocks = MarkdownBlocks.parse("1. open it\n2. press the button\n3. watch it fail")
        let ordinals = blocks.compactMap { block -> Int? in
            guard case .listItem(let ordinal, _, _) = block else { return nil }
            return ordinal
        }
        #expect(ordinals == [1, 2, 3])
    }

    /// The field people paste stack traces into.
    @Test("a fenced code block is preserved verbatim")
    func fencedCodeBlockIsPreservedVerbatim() {
        let source = """
            Here is the error:

            ```
            Fatal error: Unexpectedly found nil
                at IssueRepository.swift:42
            ```
            """
        let blocks = MarkdownBlocks.parse(source)
        let code = blocks.compactMap { block -> String? in
            guard case .codeBlock(let value) = block else { return nil }
            return value
        }

        #expect(code.count == 1)
        let body = try! #require(code.first)
        #expect(body.contains("Fatal error"))
        // Indentation carries meaning in a stack trace and must survive.
        #expect(body.contains("    at IssueRepository.swift:42"))
        #expect(!body.contains("```"))
    }

    @Test("a quote is its own block")
    func quoteIsItsOwnBlock() {
        let blocks = MarkdownBlocks.parse("> as discussed yesterday")
        guard case .quote = blocks.first else {
            Issue.record("expected a quote, got \(String(describing: blocks.first))")
            return
        }
        #expect(text(of: blocks[0]) == "as discussed yesterday")
    }

    /// Inline styling is what SwiftUI does handle, and it must survive the split.
    @Test("inline styling survives")
    func inlineStylingSurvives() {
        let blocks = MarkdownBlocks.parse("This is **important** and `code`.")
        guard case .paragraph(let value) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }

        let plain = String(value.characters)
        #expect(plain == "This is important and code.")
        // The markers are gone because they became attributes, not because they
        // were stripped as text.
        #expect(value.runs.count > 1)
    }

    @Test("a link keeps its destination")
    func linkKeepsItsDestination() {
        let blocks = MarkdownBlocks.parse("See [the spec](https://example.com/spec).")
        guard case .paragraph(let value) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(value.runs.contains { $0.link?.absoluteString == "https://example.com/spec" })
    }

    /// Nesting has to be reported, or a sub-list renders flat and the structure the
    /// author wrote is lost.
    @Test("a nested list reports its depth")
    func nestedListReportsItsDepth() {
        let blocks = MarkdownBlocks.parse("- outer\n    - inner")
        let depths = blocks.compactMap { block -> Int? in
            guard case .listItem(_, let depth, _) = block else { return nil }
            return depth
        }

        #expect(depths.count == 2)
        #expect(depths[1] > depths[0], "the nested item did not report greater depth")
    }

    /// A description that cannot be parsed is still the user's text, and showing it
    /// verbatim beats showing nothing.
    @Test(
        "unparseable source is still shown",
        arguments: [
            "[unclosed", "```\nunterminated fence", "| broken | table",
        ])
    func unparseableSourceIsStillShown(_ source: String) {
        let blocks = MarkdownBlocks.parse(source)
        #expect(!blocks.isEmpty, "'\(source)' rendered as nothing")
    }

    @Test("a realistic description keeps all of its parts")
    func realisticDescriptionKeepsAllOfItsParts() {
        let source = """
            The sync queue stalls when an operation is quarantined.

            ## Steps

            1. Queue a bad write
            2. Push

            ```
            SQLite error 1
            ```

            > Reported by Mel.
            """
        let blocks = MarkdownBlocks.parse(source)

        #expect(blocks.contains { if case .heading = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .listItem = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .codeBlock = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .quote = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .paragraph = $0 { return true } else { return false } })
    }
}
