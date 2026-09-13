import AppCore
import AppViews
import ClientStore
import Core
import SwiftUI

/// The Mac composition: sidebar, sortable table, detail inspector.
///
/// `NavigationSplitView` rather than the iPhone's stack because the screen affords
/// it — ticket 10 rejected the unified variant precisely because a card list in a
/// desktop window is an iPad app on a Mac.
struct ContentView: View {
    @Bindable var session: AppSession
    @State private var sortOrder = [KeyPathComparator(\IssueRow.title)]
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let list = session.list {
                issues(list)
            } else {
                ContentUnavailableView(
                    session.startupFailure.map { _ in "Could not open the local database" }
                        ?? "Opening…",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(session.startupFailure ?? ""))
            }
        }
        .searchable(text: $search, prompt: "Filter issues")
    }

    private var sidebar: some View {
        List(selection: $session.selectedProject) {
            Section("Projects") {
                ForEach(session.projects, id: \.id) { project in
                    Label(project.name, systemImage: "folder").tag(project.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .overlay {
            if session.projects.isEmpty {
                ContentUnavailableView(
                    "No projects yet",
                    systemImage: "folder",
                    description: Text(
                        session.isConfigured
                            ? "Sync to bring them down."
                            : "Add a server in Settings to begin."))
            }
        }
    }

    private func issues(_ list: IssueListModel) -> some View {
        VStack(spacing: 0) {
            // The five sync surfaces, from the shared implementation. The Mac
            // decides only that they sit above the table.
            if !list.status.surfaces.isEmpty {
                SyncStatusView(status: list.status) { _ in }
                    .padding(12)
                    .background(.bar)
            }

            IssueTable(
                rows: rows(list), sortOrder: $sortOrder, selection: $session.selectedIssue)

            statusBar(list)
        }
        .inspector(isPresented: .constant(session.selectedIssue != nil)) {
            detail(list)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await session.sync() }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!session.isConfigured)
            }
        }
    }

    private func rows(_ list: IssueListModel) -> [IssueRow] {
        let matching = search.isEmpty
            ? list.issues
            : list.issues.filter {
                $0.record.title.localizedCaseInsensitiveContains(search)
            }
        return matching.map(IssueRow.init).sorted(using: sortOrder)
    }

    private func statusBar(_ list: IssueListModel) -> some View {
        HStack {
            // State, never freshness: a missed background refresh would turn any
            // "updated N minutes ago" into a lie (ticket 10).
            Text(list.status.progressDescription)
            Spacer()
            if let failure = list.failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func detail(_ list: IssueListModel) -> some View {
        if let id = session.selectedIssue,
            let issue = list.issues.first(where: { $0.record.id == id })
        {
            ScrollView {
                IssueDetailContent(
                    issue: issue,
                    projectKey: session.projects.first { $0.id == issue.record.projectId }?.key
                )
                .padding(16)
            }
        } else {
            ContentUnavailableView("No issue selected", systemImage: "sidebar.right")
        }
    }
}

/// A table row. `Table` needs a concrete `Identifiable` value with comparable
/// columns, which `Overlaid<Issue>` is not.
struct IssueRow: Identifiable {
    let id: Issue.ID
    let key: String
    let title: String
    let status: String
    let priority: String
    let overlaid: Overlaid<Issue>

    init(_ overlaid: Overlaid<Issue>) {
        self.id = overlaid.record.id
        self.key = IssueKeyPresentation.text(key: overlaid.record.key, projectKey: nil)
        self.title = overlaid.record.title
        self.status = StatusPresentation.text(overlaid.record.status)
        self.priority = PriorityPresentation.text(overlaid.record.priority)
        self.overlaid = overlaid
    }
}
