import AppCore
import AppViews
import ClientStore
import Core
import SwiftUI
import TestSupport

/// A gallery of the shared components, with every sync surface visible at once.
///
/// The successor to ticket 10's HTML prototype: the views themselves cannot be
/// unit-tested, so this exists to be looked at. Throwaway — it ships with nothing.
@main
struct PreviewApp: App {
    var body: some Scene {
        WindowGroup("Issues — component gallery") {
            Gallery()
                .frame(minWidth: 900, minHeight: 1150)
        }
    }
}

struct Gallery: View {
    private let project = Project.fixture(key: ProjectKey("PROJ")!, name: "Platform")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("All five sync surfaces") {
                    SyncStatusView(status: Fixtures.everySurface) { _ in }
                }

                section("Rows") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(Fixtures.rows.enumerated()), id: \.offset) { _, row in
                            IssueRowContent(
                                issue: row.issue, labels: row.labels, assignee: row.assignee,
                                projectKey: project.key)
                            Divider()
                        }
                    }
                }

                section("Atoms") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            ForEach(Status.known + [.unknown("triaged")], id: \.wireValue) {
                                StatusPill($0)
                            }
                        }
                        HStack(spacing: 12) {
                            ForEach(Priority.known + [.unknown("blocker")], id: \.wireValue) {
                                PriorityLabel($0)
                            }
                        }
                        HStack(spacing: 6) {
                            ForEach(Fixtures.labels, id: \.id) { LabelChip($0) }
                            LabelChip(
                                Core.Label.fixture(name: "unparseable colour", color: "banana"))
                        }
                        HStack(spacing: 12) {
                            IssueKeyLabel(key: IssueKey("PROJ-142"), projectKey: project.key)
                            IssueKeyLabel(key: nil, projectKey: project.key)
                            IssueKeyLabel(key: nil, projectKey: nil)
                            ViaBadge(.agent)
                            DirtyIndicator(isDirty: true)
                        }
                    }
                }

                section("Progress copy") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Fixtures.progressStates, id: \.0) { name, status in
                            Text("\(name): \(status.progressDescription)").font(.caption)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}
