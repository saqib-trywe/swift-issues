import Foundation

/// One block of rendered Markdown.
///
/// Text is Markdown source and clients render it (ticket 01) — the server never
/// does, so there is no HTML pipeline and no sanitiser to keep patched. Foundation
/// parses the whole syntax, but SwiftUI's `Text` honours only inline styling and
/// silently ignores block structure, so headings, lists and fenced code would come
/// out as run-together text with stray hyphens and backticks. Splitting the parsed
/// runs into blocks is what makes them render.
public enum MarkdownBlock: Sendable, Hashable {
    case paragraph(AttributedString)
    /// `level` is 1–6 as written.
    case heading(level: Int, AttributedString)
    /// `ordinal` is nil for a bulleted item.
    case listItem(ordinal: Int?, depth: Int, AttributedString)
    /// Preformatted, rendered monospaced and never re-wrapped.
    case codeBlock(String)
    case quote(AttributedString)
}

/// Turns Markdown source into blocks a view can stack.
public enum MarkdownBlocks {

    /// Parses and splits. Never throws: a description that cannot be parsed is
    /// still the user's text, and showing it verbatim beats showing nothing.
    public static func parse(_ source: String) -> [MarkdownBlock] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let options = AttributedString.MarkdownParsingOptions(
            // Keeps blank lines meaningful rather than collapsing everything into
            // one paragraph.
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)

        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return [.paragraph(AttributedString(source))]
        }
        return blocks(from: parsed)
    }

    static func blocks(from parsed: AttributedString) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []

        // One run per contiguous span sharing a presentation intent, which is how
        // Foundation reports block structure.
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var slice = AttributedString(parsed[range])
            // Leading and trailing newlines belong to the split, not the content.
            slice = trimmed(slice)
            guard let intent else {
                if !slice.characters.isEmpty { blocks.append(.paragraph(slice)) }
                continue
            }
            blocks.append(contentsOf: block(for: intent, content: slice))
        }
        return blocks
    }

    private static func block(
        for intent: PresentationIntent, content: AttributedString
    ) -> [MarkdownBlock] {
        var ordinal: Int?
        var depth = 0
        var isListItem = false

        // Components run innermost-first, so a list item inside a list inside a
        // list reports its own ordinal before its parents' nesting.
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                return [.heading(level: level, content)]
            case .codeBlock:
                return [.codeBlock(String(content.characters))]
            case .blockQuote:
                return [.quote(content)]
            case .listItem(let number):
                isListItem = true
                ordinal = number
            case .unorderedList:
                depth += 1
                // A bullet has no number, whatever the item component said.
                ordinal = nil
            case .orderedList:
                depth += 1
            default:
                break
            }
        }

        if isListItem {
            return [.listItem(ordinal: ordinal, depth: max(depth - 1, 0), content)]
        }
        guard !content.characters.isEmpty else { return [] }
        return [.paragraph(content)]
    }

    private static func trimmed(_ value: AttributedString) -> AttributedString {
        var value = value
        while let first = value.characters.first, first.isNewline {
            value.removeSubrange(value.startIndex..<value.index(afterCharacter: value.startIndex))
        }
        while let last = value.characters.last, last.isNewline {
            value.removeSubrange(value.index(beforeCharacter: value.endIndex)..<value.endIndex)
        }
        return value
    }
}
