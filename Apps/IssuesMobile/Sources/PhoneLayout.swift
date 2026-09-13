import AppCore
import AppViews
import ClientStore
import Core
import SwiftUI

/// The iPhone composition: a stack of cards, and a tab bar with a badged Inbox.
///
/// Ticket 10 gives the phone a tab bar specifically so the needs-attention count
/// has somewhere to live. Without it the sync surfaces would be buried behind a
/// scroll, and a guarantee nobody can see is not a guarantee.
struct PhoneLayout: View {
    @Bindable var session: MobileSession
    @State private var composing = false

    var body: some View {
        TabView {
            Tab("Issues", systemImage: "list.bullet") {
                NavigationStack {
                    IssueCardList(session: session)
                        .navigationTitle(projectName)
                        .toolbar { newIssueButton }
                }
            }

            Tab("Inbox", systemImage: "tray") {
                NavigationStack {
                    InboxView(session: session).navigationTitle("Inbox")
                }
            }
            // The count of things a person must act on. Queued work is not in it —
            // that is going out on its own, and a badge that is always lit is a
            // badge nobody reads.
            .badge(session.list?.status.attentionCount ?? 0)
        }
        .sheet(isPresented: $composing) { composer }
    }

    private var projectName: String {
        session.projects.first { $0.id == session.selectedProject }?.name ?? "Issues"
    }

    @ToolbarContentBuilder
    private var newIssueButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                .disabled(session.selectedProject == nil)
        }
    }

    @ViewBuilder
    private var composer: some View {
        if let project = session.selectedProject, let writer = session.writer {
            NavigationStack {
                MobileIssueEditor(
                    projectId: project, existing: nil, writer: writer,
                    onFinish: session.afterLocalWrite)
            }
        }
    }
}

/// The phone's list: cards rather than a table, since there is no width for
/// columns and nothing to sort with a pointer.
struct IssueCardList: View {
    @Bindable var session: MobileSession

    var body: some View {
        List {
            if let status = session.list?.status, !status.surfaces.isEmpty {
                Section {
                    // The same five surfaces as everywhere else. The phone decides
                    // only that they sit above the list.
                    SyncStatusView(status: status)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section {
                ForEach(session.list?.issues ?? [], id: \.record.id) { issue in
                    NavigationLink {
                        MobileIssueDetail(session: session, id: issue.record.id)
                    } label: {
                        IssueRowContent(
                            issue: issue,
                            projectKey: session.projects
                                .first { $0.id == issue.record.projectId }?.key)
                    }
                }
            } footer: {
                // State, never freshness: a missed background refresh would make any
                // "updated N minutes ago" a lie.
                Text(session.list?.status.progressDescription ?? "")
            }
        }
        .listStyle(.plain)
        .refreshable { await session.sync() }
        .overlay {
            if session.list?.issues.isEmpty == true {
                ContentUnavailableView(
                    "No issues", systemImage: "tray",
                    description: Text(
                        session.isConfigured
                            ? "Pull to sync." : "Add a server in Settings to begin."))
            }
        }
    }
}

/// Everything a person has to act on, in one place.
struct InboxView: View {
    @Bindable var session: MobileSession

    var body: some View {
        List {
            if let status = session.list?.status {
                if status.surfaces.isEmpty {
                    ContentUnavailableView(
                        "Nothing needs attention", systemImage: "checkmark.circle",
                        description: Text(status.progressDescription))
                } else {
                    SyncStatusView(status: status)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await session.sync() }
    }
}
