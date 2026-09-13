import AppCore
import AppViews
import ClientStore
import Core
import SwiftUI

/// The iPad composition: the Mac's two columns at touch sizes.
///
/// Ticket 10 is explicit that the iPad gets the *macOS* shape rather than the
/// iPhone's — the screen affords a split view, and a phone layout on an iPad wastes
/// it. It does not get the Mac's token and session administration.
struct PadLayout: View {
    @Bindable var session: MobileSession
    @State private var selected: Issue.ID?
    @State private var composing = false

    private var projectName: String {
        session.projects.first { $0.id == session.selectedProject }?.name ?? "Issues"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $session.selectedProject) {
                Section("Projects") {
                    ForEach(session.projects, id: \.id) { project in
                        Label(project.name, systemImage: "folder").tag(project.id)
                    }
                }
            }
            .navigationTitle("Issues")
        } content: {
            List(selection: $selected) {
                if let status = session.list?.status, !status.surfaces.isEmpty {
                    SyncStatusView(status: status).listRowInsets(EdgeInsets())
                }
                ForEach(session.list?.issues ?? [], id: \.record.id) { issue in
                    IssueRowContent(
                        issue: issue,
                        projectKey: session.projects
                            .first { $0.id == issue.record.projectId }?.key
                    )
                    .tag(issue.record.id)
                }

                Section {
                } footer: {
                    // The iPad needs this as much as the phone: sync state has to be
                    // visible somewhere, and it says state rather than freshness.
                    Text(session.list?.status.progressDescription ?? "")
                }
            }
            .navigationTitle(projectName)
            .refreshable { await session.sync() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { composing = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(session.selectedProject == nil)
                }
            }
        } detail: {
            if let selected {
                MobileIssueDetail(session: session, id: selected)
            } else {
                ContentUnavailableView("No issue selected", systemImage: "sidebar.right")
            }
        }
        .sheet(isPresented: $composing) {
            if let project = session.selectedProject, let writer = session.writer {
                NavigationStack {
                    MobileIssueEditor(
                        projectId: project, existing: nil, writer: writer,
                        onFinish: session.afterLocalWrite)
                }
            }
        }
    }
}
