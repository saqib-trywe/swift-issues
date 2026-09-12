import AppCore
import ClientStore
import Core
import SwiftUI

/// One issue, as a row.
///
/// Shared across all three platforms: macOS places it in a sortable `Table`, iPhone
/// in a card, iPad in a split view. Ticket 10's variant C means the *content* is
/// written once and only the container differs.
public struct IssueRowContent: View {
    let issue: Overlaid<Issue>
    let labels: [Core.Label]
    let assignee: User?
    let projectKey: ProjectKey?
    let dateFormat: CalendarDateFormat

    public init(
        issue: Overlaid<Issue>,
        labels: [Core.Label] = [],
        assignee: User? = nil,
        projectKey: ProjectKey? = nil,
        dateFormat: CalendarDateFormat = CalendarDateFormat()
    ) {
        self.issue = issue
        self.labels = labels
        self.assignee = assignee
        self.projectKey = projectKey
        self.dateFormat = dateFormat
    }

    /// Whether this row should read as going away.
    ///
    /// A locally deleted issue is still in the replica until the server agrees, so
    /// a list may show it mid-flight rather than having it vanish and possibly
    /// reappear.
    var isLeaving: Bool { issue.isUnsentDelete }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            DirtyIndicator(isDirty: issue.hasUnsentChanges)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    IssueKeyLabel(key: issue.record.key, projectKey: projectKey)
                    Text(issue.record.title)
                        .lineLimit(2)
                        .strikethrough(isLeaving)
                    ViaBadge(issue.record.via)
                }

                HStack(spacing: 6) {
                    StatusPill(issue.record.status)
                    PriorityLabel(issue.record.priority)

                    if let assignee {
                        Text(assignee.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let due = issue.record.dueDate {
                        // Through the calendar formatter, never a timezone-converting
                        // one: a due date is a day, not an instant.
                        Text(dateFormat.short(for: due))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(labels, id: \.id) { LabelChip($0) }
                }
            }

            Spacer(minLength: 0)

            // Reserved the same way, so a trailing column does not appear and
            // disappear as rows change state.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(issue.isQuarantined ? Color.orange : .clear)
                .accessibilityLabel("This change was refused")
                .accessibilityHidden(!issue.isQuarantined)
        }
        .opacity(isLeaving ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}
