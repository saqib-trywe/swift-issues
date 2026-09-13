import AppCore
import ClientStore
import Core
import SwiftUI

/// One issue in full: its fields and its comment thread.
///
/// Shared across platforms — macOS puts it in an inspector, iPhone pushes it full
/// screen, iPad shows it beside the list. Only the container differs.
public struct IssueDetailContent: View {
    let issue: Overlaid<Issue>
    let comments: [Core.Comment]
    let labels: [Core.Label]
    let assignee: User?
    let reporter: User?
    let projectKey: ProjectKey?
    /// Which fields cannot be edited because this build does not recognise their
    /// current value.
    let readOnly: (IssueField) -> Bool
    let authorName: (User.ID) -> String?
    let dateFormat: CalendarDateFormat

    public init(
        issue: Overlaid<Issue>,
        comments: [Core.Comment] = [],
        labels: [Core.Label] = [],
        assignee: User? = nil,
        reporter: User? = nil,
        projectKey: ProjectKey? = nil,
        readOnly: @escaping (IssueField) -> Bool = { _ in false },
        authorName: @escaping (User.ID) -> String? = { _ in nil },
        dateFormat: CalendarDateFormat = CalendarDateFormat()
    ) {
        self.issue = issue
        self.comments = comments
        self.labels = labels
        self.assignee = assignee
        self.reporter = reporter
        self.projectKey = projectKey
        self.readOnly = readOnly
        self.authorName = authorName
        self.dateFormat = dateFormat
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            fields
            if !issue.record.description.isEmpty { description }
            thread
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IssueKeyLabel(key: issue.record.key, projectKey: projectKey)
                ViaBadge(issue.record.via)
                Spacer(minLength: 0)
                DirtyIndicator(isDirty: issue.hasUnsentChanges)
            }
            Text(issue.record.title)
                .font(.title2)
                .fontWeight(.semibold)
                .strikethrough(issue.isUnsentDelete)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(.status, "Status") { StatusPill(issue.record.status) }
            field(.priority, "Priority") { PriorityLabel(issue.record.priority) }
            field(.assignee, "Assignee") {
                Text(assignee?.displayName ?? "Unassigned")
                    .foregroundStyle(assignee == nil ? .secondary : .primary)
            }
            field(.dueDate, "Due") {
                // Through the calendar formatter: a due date is a day, not an
                // instant, and a converting formatter shifts it.
                Text(issue.record.dueDate.map(dateFormat.string(for:)) ?? "None")
                    .foregroundStyle(issue.record.dueDate == nil ? .secondary : .primary)
            }

            if let reporter {
                labelled("Reporter") { Text(reporter.displayName) }
            }
            if !labels.isEmpty {
                labelled("Labels") {
                    HStack(spacing: 4) { ForEach(labels, id: \.id) { LabelChip($0) } }
                }
            }
        }
        .font(.callout)
    }

    /// A row that knows whether its value is dirty or locked.
    private func field(
        _ field: IssueField, _ name: String, @ViewBuilder value: () -> some View
    ) -> some View {
        let isLocked = readOnly(field)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            value()
            if issue.dirty.contains(field) {
                DirtyIndicator(isDirty: true)
            }
            if isLocked {
                // A value this build cannot represent renders read-only rather than
                // as a control that would clobber it (ticket 10).
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("This value cannot be changed in this version")
            }
            Spacer(minLength: 0)
        }
    }

    private func labelled(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description").font(.callout).foregroundStyle(.secondary)
            MarkdownText(issue.record.description)
        }
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(comments.isEmpty ? "No comments" : "Comments")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(comments, id: \.id) { comment in
                CommentRow(comment: comment, authorName: authorName(comment.authorId))
            }
        }
    }
}

/// One comment.
struct CommentRow: View {
    let comment: Core.Comment
    let authorName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(authorName ?? "Unknown")
                    .font(.caption)
                    .fontWeight(.medium)
                ViaBadge(comment.via)
                Spacer(minLength: 0)
            }

            if CommentPresentation.isPlaceholder(comment) {
                // The entry stays in place: a thread that closes its gaps reads as
                // if the exchange never happened, and the reply below stops making
                // sense.
                Text(CommentPresentation.deletedPlaceholder)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                MarkdownText(CommentPresentation.body(comment))
            }
        }
    }
}
