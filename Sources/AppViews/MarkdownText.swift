import AppCore
import SwiftUI

/// Renders Markdown source with its block structure intact.
///
/// SwiftUI's `Text` handles inline styling and silently ignores headings, lists and
/// fenced code, so those are stacked here instead. The parsing and splitting live
/// in `AppCore` where they are tested; this only lays the blocks out.
public struct MarkdownText: View {
    let source: String

    public init(_ source: String) {
        self.source = source
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlocks.parse(source).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let value):
            Text(value)

        case .heading(let level, let value):
            Text(value)
                .font(level <= 2 ? .headline : .subheadline)
                .fontWeight(.semibold)

        case .listItem(let ordinal, let depth, let value):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal.map { "\($0)." } ?? "•")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(value)
            }
            // Indented by depth, so a nested list still reads as nested.
            .padding(.leading, CGFloat(depth) * 16)

        case .codeBlock(let value):
            // Never re-wrapped: indentation carries meaning in a stack trace, which
            // is what this field mostly holds.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

        case .quote(let value):
            HStack(spacing: 8) {
                Rectangle().frame(width: 3).foregroundStyle(.tertiary)
                Text(value).italic()
            }
        }
    }
}
