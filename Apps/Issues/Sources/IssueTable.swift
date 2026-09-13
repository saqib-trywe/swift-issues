import AppCore
import AppViews
import Core
import SwiftUI

/// The Mac's sortable table.
///
/// Ticket 10 gives macOS a `Table` rather than the card list the phone gets: a
/// desktop window affords columns, sorting and keyboard navigation, and not using
/// them is what made the unified variant read as an iPad app on a Mac.
struct IssueTable: View {
    let rows: [IssueRow]
    @Binding var sortOrder: [KeyPathComparator<IssueRow>]
    @Binding var selection: Issue.ID?

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in
                DirtyIndicator(isDirty: row.overlaid.hasUnsentChanges)
            }
            .width(12)

            TableColumn("Key", value: \.key) { row in
                IssueKeyLabel(key: row.overlaid.record.key)
            }
            .width(min: 70, ideal: 84, max: 110)

            // Given the lion's share deliberately: the title is what people scan,
            // and Table otherwise splits leftover width evenly and truncates it.
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 6) {
                    Text(row.title)
                        .strikethrough(row.overlaid.isUnsentDelete)
                    ViaBadge(row.overlaid.record.via)
                }
            }
            .width(min: 240, ideal: 460)

            TableColumn("Status", value: \.status) { row in
                StatusPill(row.overlaid.record.status)
            }
            .width(min: 80, ideal: 96, max: 120)

            TableColumn("Priority", value: \.priority) { row in
                PriorityLabel(row.overlaid.record.priority)
            }
            .width(min: 70, ideal: 80, max: 100)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No issues", systemImage: "tray",
                    description: Text("Nothing here yet."))
            }
        }
    }
}
